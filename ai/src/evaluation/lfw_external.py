"""One-shot external LFW evaluation for the final MerLens curriculum checkpoint."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from hashlib import sha256
from pathlib import Path

import cv2
import numpy as np
import torch

from ai.src.datasets.digiface import DatasetIntegrityError
from ai.src.models import build_merlens_model
from ai.src.preprocessing import FaceDetectionError, FacePreprocessor, YuNetDetector


def sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_view2_pairs(
    path: Path, image_root: Path
) -> tuple[tuple[Path, Path, bool], ...]:
    lines = [line.split() for line in path.read_text(encoding="utf-8").splitlines()]
    if not lines or lines[0] != ["10", "300"] or len(lines) != 6001:
        raise DatasetIntegrityError("unexpected LFW View-2 pair protocol")

    def image(name: str, index: str) -> Path:
        if not name or not index.isdigit() or int(index) < 1:
            raise DatasetIntegrityError("invalid LFW pair member")
        candidate = image_root / name / f"{name}_{int(index):04d}.jpg"
        if not candidate.is_file():
            raise DatasetIntegrityError("LFW pair image is missing")
        return candidate

    pairs: list[tuple[Path, Path, bool]] = []
    offset = 1
    for _fold in range(10):
        for fields in lines[offset : offset + 300]:
            if len(fields) != 3:
                raise DatasetIntegrityError("invalid genuine LFW pair")
            pairs.append(
                (image(fields[0], fields[1]), image(fields[0], fields[2]), True)
            )
        offset += 300
        for fields in lines[offset : offset + 300]:
            if len(fields) != 4:
                raise DatasetIntegrityError("invalid impostor LFW pair")
            pairs.append(
                (image(fields[0], fields[1]), image(fields[2], fields[3]), False)
            )
        offset += 300
    return tuple(pairs)


def fixed_threshold_metrics(
    labels: np.ndarray, accepted: np.ndarray
) -> dict[str, float | int]:
    genuine = labels.astype(bool)
    impostor = ~genuine
    false_accepts = int(np.sum(accepted & impostor))
    false_rejects = int(np.sum(~accepted & genuine))
    genuine_count = int(np.sum(genuine))
    impostor_count = int(np.sum(impostor))
    far = false_accepts / impostor_count
    frr = false_rejects / genuine_count
    return {
        "pair_count": int(labels.size),
        "genuine_pairs": genuine_count,
        "impostor_pairs": impostor_count,
        "accuracy": float(np.mean(accepted == genuine)),
        "false_acceptance_rate": far,
        "false_rejection_rate": frr,
        "balanced_error_rate": (far + frr) / 2.0,
        "false_accepts": false_accepts,
        "false_rejects": false_rejects,
    }


@torch.inference_mode()
def run(args: argparse.Namespace) -> dict[str, object]:
    expected = {
        args.archive: args.archive_sha256,
        args.pairs: args.pairs_sha256,
        args.checkpoint: args.checkpoint_sha256,
        args.detector: args.detector_sha256,
    }
    for path, digest in expected.items():
        if sha256_file(path) != digest.lower():
            raise DatasetIntegrityError(f"SHA-256 mismatch: {path.name}")
    if args.output.exists():
        raise FileExistsError("LFW evaluation output already exists")

    payload = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    health = payload.get("health", {}) if isinstance(payload, dict) else {}
    if not (
        isinstance(payload, dict)
        and payload.get("schema_version") == 1
        and payload.get("run_name") == "merlens-v2-curriculum"
        and payload.get("stage_index") == 4
        and payload.get("completed_epoch") == 12
        and health.get("verdict") == "HEALTHY"
        and health.get("ready_to_advance") is True
    ):
        raise DatasetIntegrityError(
            "checkpoint is not the completed healthy curriculum model"
        )
    checkpoint_threshold = float(payload["history"][-1]["validation_threshold"])
    if checkpoint_threshold != args.locked_threshold:
        raise DatasetIntegrityError(
            "locked threshold does not match checkpoint history"
        )

    pairs = parse_view2_pairs(args.pairs, args.image_root)
    detector = YuNetDetector.from_model(
        args.detector, confidence_threshold=0.9, nms_threshold=0.3, top_k=5000
    )
    preprocessor = FacePreprocessor(detector)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = build_merlens_model().to(device).eval()
    model.load_state_dict(payload["model_state_dict"], strict=True)

    unique_images = sorted({pair[0] for pair in pairs} | {pair[1] for pair in pairs})
    embeddings: dict[Path, np.ndarray] = {}
    rejection_reasons: Counter[str] = Counter()
    for start in range(0, len(unique_images), args.batch_size):
        batch_paths = unique_images[start : start + args.batch_size]
        tensors: list[np.ndarray] = []
        accepted_paths: list[Path] = []
        for image_path in batch_paths:
            image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
            if image is None:
                raise DatasetIntegrityError("LFW image became unreadable")
            try:
                tensors.append(preprocessor.process(image).recognition_chw)
                accepted_paths.append(image_path)
            except FaceDetectionError as error:
                rejection_reasons[error.reason] += 1
            except ValueError:
                rejection_reasons["alignment_or_tensor_error"] += 1
        if tensors:
            outputs = (
                model(torch.from_numpy(np.stack(tensors)).to(device))
                .float()
                .cpu()
                .numpy()
            )
            for image_path, embedding in zip(accepted_paths, outputs, strict=True):
                embeddings[image_path] = embedding

    labels = np.asarray([pair[2] for pair in pairs], dtype=bool)
    accepted = np.zeros(len(pairs), dtype=bool)
    fully_processed = 0
    for index, (left_path, right_path, _genuine) in enumerate(pairs):
        left = embeddings.get(left_path)
        right = embeddings.get(right_path)
        if left is not None and right is not None:
            fully_processed += 1
            accepted[index] = float(np.dot(left, right)) >= args.locked_threshold

    result: dict[str, object] = {
        "protocol": "LFW View-2 fixed external threshold; no LFW calibration",
        "checkpoint_sha256": args.checkpoint_sha256.lower(),
        "checkpoint_stage": 5,
        "checkpoint_epoch": 12,
        "locked_threshold": args.locked_threshold,
        "threshold_source": "MerLens curriculum final validation",
        "archive_sha256": args.archive_sha256.lower(),
        "pairs_sha256": args.pairs_sha256.lower(),
        "unique_images": len(unique_images),
        "processed_images": len(embeddings),
        "rejected_images": len(unique_images) - len(embeddings),
        "rejection_reasons": dict(sorted(rejection_reasons.items())),
        "fully_processed_pairs": fully_processed,
        "failed_preprocessing_rule": "verification rejection",
        "metrics": fixed_threshold_metrics(labels, accepted),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--pairs", type=Path, required=True)
    parser.add_argument("--pairs-sha256", required=True)
    parser.add_argument("--image-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--checkpoint-sha256", required=True)
    parser.add_argument("--detector", type=Path, required=True)
    parser.add_argument("--detector-sha256", required=True)
    parser.add_argument("--locked-threshold", type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=96)
    args = parser.parse_args()
    print(json.dumps(run(args), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
