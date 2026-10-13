"""Validation calibration and one locked held-out verification command."""

from __future__ import annotations

import argparse
import csv
from dataclasses import asdict, dataclass
import json
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

from ai.src.datasets.aligned import AlignedFaceDataset
from ai.src.datasets.manifest import sha256_file
from ai.src.models import load_merlens_checkpoint

from .verification import (
    VerificationMetrics,
    VerificationPair,
    calibrate_threshold,
    generate_verification_pairs,
    metrics_at_threshold,
    pair_scores,
)


@dataclass(frozen=True)
class EvaluationResult:
    """Aggregate evidence for validation calibration or locked evaluation."""

    mode: str
    partition: str
    checkpoint_sha256: str
    checkpoint_epoch: int
    identity_count: int
    image_count: int
    pair_manifest_sha256: str
    metrics: VerificationMetrics


@torch.inference_mode()
def _embeddings(
    model: torch.nn.Module,
    dataset: AlignedFaceDataset,
    *,
    device: torch.device,
    batch_size: int,
) -> np.ndarray:
    loader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=0,
        pin_memory=device.type == "cuda",
    )
    batches: list[np.ndarray] = []
    for inputs, _ in loader:
        output = model(inputs.to(device, non_blocking=True)).float().cpu().numpy()
        if output.shape[1:] != (128,) or not np.isfinite(output).all():
            raise RuntimeError("invalid checkpoint embedding output")
        batches.append(output)
    return np.concatenate(batches, axis=0)


def _write_pairs(
    path: Path,
    pairs: tuple[VerificationPair, ...],
) -> str:
    if path.exists():
        raise FileExistsError("pair manifest already exists")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=("left_index", "right_index", "is_genuine"),
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(
            {
                "left_index": pair.left_index,
                "right_index": pair.right_index,
                "is_genuine": int(pair.is_genuine),
            }
            for pair in pairs
        )
    return sha256_file(path)


def run_evaluation(
    *,
    mode: str,
    aligned_root: str | Path,
    manifest_path: str | Path,
    partition: str,
    checkpoint_path: str | Path,
    expected_checkpoint_sha256: str,
    pair_manifest_path: str | Path,
    output_path: str | Path,
    batch_size: int,
    seed: int,
    locked_threshold: float | None = None,
) -> EvaluationResult:
    """Calibrate on validation or score once at an already locked threshold."""

    if mode not in {"calibrate", "evaluate"}:
        raise ValueError("mode must be calibrate or evaluate")
    if mode == "calibrate" and partition != "validation":
        raise ValueError("calibration is allowed only on validation")
    if mode == "evaluate" and locked_threshold is None:
        raise ValueError("locked evaluation requires a threshold")
    actual_checkpoint_hash = sha256_file(checkpoint_path)
    if actual_checkpoint_hash != expected_checkpoint_sha256.lower():
        raise ValueError("checkpoint SHA-256 mismatch")
    output_path = Path(output_path)
    if output_path.exists():
        raise FileExistsError("evaluation output already exists")

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model, payload = load_merlens_checkpoint(checkpoint_path, device=device)
    dataset = AlignedFaceDataset(
        aligned_root,
        manifest_path,
        partition=partition,
        training=False,
    )
    pairs = generate_verification_pairs(dataset.records, seed=seed)
    pair_hash = _write_pairs(Path(pair_manifest_path), pairs)
    embeddings = _embeddings(
        model,
        dataset,
        device=device,
        batch_size=batch_size,
    )
    scores, labels = pair_scores(embeddings, pairs)
    if mode == "calibrate":
        metrics = calibrate_threshold(scores, labels)
    else:
        metrics = metrics_at_threshold(
            scores,
            labels,
            threshold=float(locked_threshold),
        )
    checkpoint_epoch = payload.get("completed_epoch", payload.get("epoch"))
    if checkpoint_epoch is None:
        raise ValueError("MerLens V2 checkpoint lacks a completed epoch")
    result = EvaluationResult(
        mode=mode,
        partition=partition,
        checkpoint_sha256=actual_checkpoint_hash,
        checkpoint_epoch=int(checkpoint_epoch),
        identity_count=dataset.num_classes,
        image_count=len(dataset),
        pair_manifest_sha256=pair_hash,
        metrics=metrics,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(asdict(result), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("calibrate", "evaluate"), required=True)
    parser.add_argument("--aligned-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--partition", required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--checkpoint-sha256", required=True)
    parser.add_argument("--pair-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--seed", type=int, default=20260727)
    parser.add_argument("--locked-threshold", type=float)
    return parser.parse_args()


def main() -> int:
    """Run one validation calibration or locked held-out evaluation."""

    args = _parse_args()
    result = run_evaluation(
        mode=args.mode,
        aligned_root=args.aligned_root,
        manifest_path=args.manifest,
        partition=args.partition,
        checkpoint_path=args.checkpoint,
        expected_checkpoint_sha256=args.checkpoint_sha256,
        pair_manifest_path=args.pair_manifest,
        output_path=args.output,
        batch_size=args.batch_size,
        seed=args.seed,
        locked_threshold=args.locked_threshold,
    )
    print(json.dumps(asdict(result), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
