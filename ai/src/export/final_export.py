"""Export and verify the locked final embedding model with validation data."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from statistics import median
from time import perf_counter

import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch.utils.data import DataLoader

from ai.src.datasets.aligned import AlignedFaceDataset
from ai.src.datasets.manifest import sha256_file
from ai.src.evaluation import generate_verification_pairs, pair_scores
from ai.src.models import load_merlens_checkpoint

from .export_onnx import export_embedding_model_onnx


@dataclass(frozen=True)
class FinalExportResult:
    """Aggregate final-model export and desktop parity evidence."""

    checkpoint_sha256: str
    checkpoint_epoch: int
    onnx_sha256: str
    onnx_size_bytes: int
    onnx_opset: int
    dynamic_batch: bool
    validation_image_count: int
    output_dimension: int
    finite_outputs: bool
    minimum_embedding_norm: float
    maximum_embedding_norm: float
    max_absolute_difference: float
    minimum_row_cosine_similarity: float
    verification_pair_count: int
    locked_threshold: float
    decision_mismatch_count: int
    desktop_provider: str
    desktop_batch1_warmup_runs: int
    desktop_batch1_timed_runs: int
    desktop_batch1_median_ms: float
    desktop_batch1_mean_ms: float
    parameter_count: int


def _run_pytorch(
    model: torch.nn.Module,
    loader: DataLoader,
) -> np.ndarray:
    batches: list[np.ndarray] = []
    with torch.inference_mode():
        for inputs, _ in loader:
            batches.append(model(inputs).cpu().numpy())
    return np.concatenate(batches, axis=0)


def _run_onnx(session: ort.InferenceSession, loader: DataLoader) -> np.ndarray:
    batches: list[np.ndarray] = []
    for inputs, _ in loader:
        batches.append(session.run(["embedding"], {"input": inputs.numpy()})[0])
    return np.concatenate(batches, axis=0)


def export_and_verify_final_model(
    *,
    checkpoint_path: str | Path,
    expected_checkpoint_sha256: str,
    aligned_root: str | Path,
    validation_manifest: str | Path,
    output_path: str | Path,
    report_path: str | Path,
    locked_threshold: float,
    batch_size: int = 64,
    maximum_absolute_difference: float = 2e-5,
    minimum_cosine_similarity: float = 0.99999,
    existing_onnx_sha256: str | None = None,
) -> FinalExportResult:
    """Export once and enforce graph, tensor, parity, and decision gates."""

    checkpoint_hash = sha256_file(checkpoint_path)
    if checkpoint_hash != expected_checkpoint_sha256.lower():
        raise ValueError("checkpoint SHA-256 mismatch")
    output_path = Path(output_path)
    report_path = Path(report_path)
    if report_path.exists():
        raise FileExistsError("final export report already exists")

    model, payload = load_merlens_checkpoint(checkpoint_path, device="cpu")
    validation = AlignedFaceDataset(
        aligned_root,
        validation_manifest,
        partition="validation",
        training=False,
    )
    loader = DataLoader(
        validation,
        batch_size=batch_size,
        shuffle=False,
        num_workers=0,
    )
    example_input, _ = next(iter(loader))
    if existing_onnx_sha256 is None:
        if output_path.exists():
            raise FileExistsError("final export output already exists")
        export_embedding_model_onnx(model, output_path, example_input[:2])
    else:
        if not output_path.is_file():
            raise FileNotFoundError("existing final ONNX artifact is missing")
        if sha256_file(output_path) != existing_onnx_sha256.lower():
            raise ValueError("existing final ONNX SHA-256 mismatch")

    graph = onnx.load(output_path)
    onnx.checker.check_model(graph)
    default_opsets = [item.version for item in graph.opset_import if not item.domain]
    if default_opsets != [18]:
        raise RuntimeError("final ONNX graph does not use default-domain opset 18")
    if (
        graph.graph.input[0].name != "input"
        or graph.graph.output[0].name != "embedding"
    ):
        raise RuntimeError("final ONNX tensor names do not match")
    input_shape = graph.graph.input[0].type.tensor_type.shape.dim
    output_shape = graph.graph.output[0].type.tensor_type.shape.dim
    dynamic_batch = bool(input_shape[0].dim_param and output_shape[0].dim_param)
    if not dynamic_batch or output_shape[1].dim_value != 128:
        raise RuntimeError("final ONNX dynamic/output shape contract failed")

    session = ort.InferenceSession(
        str(output_path),
        providers=["CPUExecutionProvider"],
    )
    expected = _run_pytorch(model, loader)
    actual = _run_onnx(session, loader)
    if actual.shape != (len(validation), 128) or expected.shape != actual.shape:
        raise RuntimeError("final parity output shape mismatch")
    finite = bool(np.isfinite(actual).all())
    if not finite:
        raise RuntimeError("final ONNX output became non-finite")
    norms = np.linalg.norm(actual, axis=1)
    if not np.allclose(norms, 1.0, rtol=1e-5, atol=1e-6):
        raise RuntimeError("final ONNX embeddings are not unit normalized")
    maximum_difference = float(np.max(np.abs(actual - expected)))
    row_cosines = np.sum(actual * expected, axis=1) / (
        np.linalg.norm(actual, axis=1) * np.linalg.norm(expected, axis=1)
    )
    minimum_cosine = float(np.min(row_cosines))
    if maximum_difference > maximum_absolute_difference:
        raise RuntimeError("final ONNX maximum absolute parity gate failed")
    if minimum_cosine < minimum_cosine_similarity:
        raise RuntimeError("final ONNX cosine parity gate failed")

    pairs = generate_verification_pairs(validation.records, seed=20260727)
    pytorch_scores, _ = pair_scores(expected, pairs)
    onnx_scores, _ = pair_scores(actual, pairs)
    decision_mismatches = int(
        np.count_nonzero(
            (pytorch_scores >= locked_threshold) != (onnx_scores >= locked_threshold)
        )
    )
    if decision_mismatches:
        raise RuntimeError("final ONNX verification decisions do not match")

    batch_one = example_input[:1].numpy()
    warmup_runs = 10
    timed_runs = 50
    for _ in range(warmup_runs):
        session.run(["embedding"], {"input": batch_one})
    durations_ms: list[float] = []
    for _ in range(timed_runs):
        started = perf_counter()
        session.run(["embedding"], {"input": batch_one})
        durations_ms.append((perf_counter() - started) * 1000.0)

    result = FinalExportResult(
        checkpoint_sha256=checkpoint_hash,
        checkpoint_epoch=int(payload.get("epoch", payload["completed_epoch"])),
        onnx_sha256=sha256_file(output_path),
        onnx_size_bytes=output_path.stat().st_size,
        onnx_opset=default_opsets[0],
        dynamic_batch=dynamic_batch,
        validation_image_count=len(validation),
        output_dimension=actual.shape[1],
        finite_outputs=finite,
        minimum_embedding_norm=float(norms.min()),
        maximum_embedding_norm=float(norms.max()),
        max_absolute_difference=maximum_difference,
        minimum_row_cosine_similarity=minimum_cosine,
        verification_pair_count=len(pairs),
        locked_threshold=float(locked_threshold),
        decision_mismatch_count=decision_mismatches,
        desktop_provider=session.get_providers()[0],
        desktop_batch1_warmup_runs=warmup_runs,
        desktop_batch1_timed_runs=timed_runs,
        desktop_batch1_median_ms=float(median(durations_ms)),
        desktop_batch1_mean_ms=float(np.mean(durations_ms)),
        parameter_count=sum(parameter.numel() for parameter in model.parameters()),
    )
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(asdict(result), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--checkpoint-sha256", required=True)
    parser.add_argument("--aligned-root", type=Path, required=True)
    parser.add_argument("--validation-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--locked-threshold", type=float, required=True)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--existing-onnx-sha256")
    return parser.parse_args()


def main() -> int:
    """Run final export and print only aggregate evidence."""

    args = _parse_args()
    result = export_and_verify_final_model(
        checkpoint_path=args.checkpoint,
        expected_checkpoint_sha256=args.checkpoint_sha256,
        aligned_root=args.aligned_root,
        validation_manifest=args.validation_manifest,
        output_path=args.output,
        report_path=args.report,
        locked_threshold=args.locked_threshold,
        batch_size=args.batch_size,
        existing_onnx_sha256=args.existing_onnx_sha256,
    )
    print(json.dumps(asdict(result), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
