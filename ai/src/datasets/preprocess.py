"""Dataset-backed execution of the frozen YuNet and alignment contract."""

from __future__ import annotations

import argparse
import csv
from collections import Counter
from dataclasses import asdict, dataclass
import json
from pathlib import Path
from typing import Protocol

import cv2
import numpy as np

from ai.src.preprocessing import FaceDetectionError, FacePreprocessor, YuNetDetector

from .digiface import DatasetIntegrityError
from .manifest import ManifestRecord, read_source_manifest, sha256_file


class _Detection(Protocol):
    confidence: float


class _PreprocessingResult(Protocol):
    detection: _Detection
    aligned_bgr: np.ndarray
    recognition_chw: np.ndarray


class ImagePreprocessor(Protocol):
    def process(self, image_bgr: np.ndarray) -> _PreprocessingResult: ...


@dataclass(frozen=True)
class PreprocessingSummary:
    """Aggregate, non-image evidence for one processed partition."""

    partition: str
    input_image_count: int
    successful_image_count: int
    rejected_image_count: int
    input_identity_count: int
    complete_identity_count: int
    usable_identity_count: int
    rejection_reasons: dict[str, int]
    source_manifest_sha256: str
    output_manifest_sha256: str


def _write_rows(path: Path, rows: list[dict[str, str | int | float]]) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=(
                "partition",
                "identity",
                "image_index",
                "relative_path",
                "status",
                "reason",
                "detection_confidence",
                "aligned_sha256",
            ),
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)
    return sha256_file(path)


def preprocess_partition(
    *,
    source_root: str | Path,
    source_manifest: str | Path,
    output_root: str | Path,
    output_manifest: str | Path,
    partition: str,
    preprocessor: ImagePreprocessor,
) -> PreprocessingSummary:
    """Process one partition without reading or changing any other partition."""

    source_root = Path(source_root)
    output_root = Path(output_root)
    output_manifest = Path(output_manifest)
    partition_root = output_root / partition
    if partition_root.exists() and any(partition_root.iterdir()):
        raise FileExistsError("processed partition must be absent or empty")
    if output_manifest.exists():
        raise FileExistsError("preprocessing manifest already exists")

    records = read_source_manifest(
        source_manifest,
        source_root,
        expected_partition=partition,
    )
    partition_root.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, str | int | float]] = []
    successful_by_identity: Counter[str] = Counter()
    rejection_reasons: Counter[str] = Counter()

    for record in records:
        source_path = source_root.joinpath(*record.relative_path.parts)
        if sha256_file(source_path) != record.encoded_sha256:
            raise DatasetIntegrityError("source image SHA-256 mismatch")
        source_image = cv2.imread(str(source_path), cv2.IMREAD_COLOR)
        if source_image is None:
            raise DatasetIntegrityError("source image became unreadable")

        reason = ""
        confidence: float | str = ""
        aligned_sha256 = ""
        output_relative = record.relative_path.as_posix()
        try:
            result = preprocessor.process(source_image)
            if (
                result.aligned_bgr.shape != (224, 224, 3)
                or result.aligned_bgr.dtype != np.uint8
                or result.recognition_chw.shape != (3, 224, 224)
                or result.recognition_chw.dtype != np.float32
                or not np.isfinite(result.recognition_chw).all()
            ):
                raise DatasetIntegrityError("invalid preprocessing output")
            success, encoded = cv2.imencode(".png", result.aligned_bgr)
            if not success:
                raise DatasetIntegrityError("aligned image encoding failed")
            output_path = output_root.joinpath(*record.relative_path.parts)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(encoded.tobytes())
            aligned_sha256 = sha256_file(output_path)
            confidence = round(float(result.detection.confidence), 9)
            status = "accepted"
            successful_by_identity[record.identity] += 1
        except FaceDetectionError as error:
            status = "rejected"
            reason = error.reason
            output_relative = ""
            rejection_reasons[reason] += 1
        except ValueError:
            status = "rejected"
            reason = "alignment_or_tensor_error"
            output_relative = ""
            rejection_reasons[reason] += 1

        rows.append(
            {
                "partition": record.partition,
                "identity": record.identity,
                "image_index": record.image_index,
                "relative_path": output_relative,
                "status": status,
                "reason": reason,
                "detection_confidence": confidence,
                "aligned_sha256": aligned_sha256,
            }
        )

    output_manifest_hash = _write_rows(output_manifest, rows)
    identity_count = len({record.identity for record in records})
    successful_count = sum(successful_by_identity.values())
    summary = PreprocessingSummary(
        partition=partition,
        input_image_count=len(records),
        successful_image_count=successful_count,
        rejected_image_count=len(records) - successful_count,
        input_identity_count=identity_count,
        complete_identity_count=sum(
            count == 5 for count in successful_by_identity.values()
        ),
        usable_identity_count=sum(
            count >= 2 for count in successful_by_identity.values()
        ),
        rejection_reasons=dict(sorted(rejection_reasons.items())),
        source_manifest_sha256=sha256_file(source_manifest),
        output_manifest_sha256=output_manifest_hash,
    )
    summary_path = output_manifest.with_suffix(".summary.json")
    summary_path.write_text(
        json.dumps(asdict(summary), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-manifest", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--output-manifest", type=Path, required=True)
    parser.add_argument("--partition", required=True)
    parser.add_argument("--detector", type=Path, required=True)
    parser.add_argument("--detector-sha256", required=True)
    parser.add_argument("--confidence-threshold", type=float, default=0.9)
    parser.add_argument("--nms-threshold", type=float, default=0.3)
    parser.add_argument("--top-k", type=int, default=5000)
    return parser.parse_args()


def main() -> int:
    """Execute one explicitly named, non-held-out-or-held-out partition."""

    args = _parse_args()
    if sha256_file(args.detector) != args.detector_sha256.lower():
        raise DatasetIntegrityError("YuNet artifact SHA-256 mismatch")
    detector = YuNetDetector.from_model(
        args.detector,
        confidence_threshold=args.confidence_threshold,
        nms_threshold=args.nms_threshold,
        top_k=args.top_k,
    )
    result = preprocess_partition(
        source_root=args.source_root,
        source_manifest=args.source_manifest,
        output_root=args.output_root,
        output_manifest=args.output_manifest,
        partition=args.partition,
        preprocessor=FacePreprocessor(detector),
    )
    print(json.dumps(asdict(result), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
