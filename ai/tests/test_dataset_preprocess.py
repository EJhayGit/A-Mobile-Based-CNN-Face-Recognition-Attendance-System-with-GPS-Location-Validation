"""Synthetic tests for manifest safety, leakage, and preprocessing records."""

from __future__ import annotations

import csv
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path

import cv2
import numpy as np
import pytest
import torch

from ai.src.datasets.aligned import AlignedFaceDataset
from ai.src.datasets.digiface import DatasetIntegrityError
from ai.src.datasets.manifest import (
    assert_identity_disjoint,
    read_source_manifest,
)
from ai.src.datasets.preprocess import preprocess_partition
from ai.src.preprocessing import FaceDetectionError


@contextmanager
def _workspace() -> Path:
    Path("tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="preprocess-test-", dir="tmp") as path:
        yield Path(path)


def _write_source_partition(
    workspace: Path,
    partition: str,
    identity_start: int,
    identity_count: int,
) -> tuple[Path, Path]:
    source_root = workspace / "source"
    manifest = workspace / f"{partition}.csv"
    rows: list[dict[str, str | int]] = []
    for offset in range(identity_count):
        identity = f"identity_{identity_start + offset:06d}"
        for image_index in range(5):
            relative_path = Path(partition) / identity / f"{image_index}.png"
            path = source_root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            image = np.full(
                (24, 24, 3),
                offset * 10 + image_index,
                dtype=np.uint8,
            )
            success, encoded = cv2.imencode(".png", image)
            assert success
            payload = encoded.tobytes()
            path.write_bytes(payload)
            rows.append(
                {
                    "partition": partition,
                    "identity": identity,
                    "image_index": image_index,
                    "relative_path": relative_path.as_posix(),
                    "encoded_sha256": sha256(payload).hexdigest(),
                    "pixel_sha256": sha256(image.tobytes()).hexdigest(),
                }
            )
    with manifest.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=tuple(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    return source_root, manifest


@dataclass(frozen=True)
class _Detection:
    confidence: float = 0.95


@dataclass(frozen=True)
class _Result:
    detection: _Detection
    aligned_bgr: np.ndarray
    recognition_chw: np.ndarray


class _FakePreprocessor:
    def process(self, image_bgr: np.ndarray) -> _Result:
        if int(image_bgr[0, 0, 0]) == 3:
            raise FaceDetectionError("zero_faces")
        return _Result(
            detection=_Detection(),
            aligned_bgr=np.zeros((224, 224, 3), dtype=np.uint8),
            recognition_chw=np.zeros((3, 224, 224), dtype=np.float32),
        )


def test_manifest_validation_and_identity_disjointness() -> None:
    with _workspace() as workspace:
        root, train_path = _write_source_partition(workspace, "train", 0, 2)
        _, validation_path = _write_source_partition(workspace, "validation", 2, 1)
        train = read_source_manifest(train_path, root, expected_partition="train")
        validation = read_source_manifest(
            validation_path, root, expected_partition="validation"
        )

        assert assert_identity_disjoint({"train": train, "validation": validation}) == {
            "train": 2,
            "validation": 1,
        }


def test_identity_leakage_is_rejected() -> None:
    with _workspace() as workspace:
        root, train_path = _write_source_partition(workspace, "train", 0, 1)
        _, validation_path = _write_source_partition(workspace, "validation", 0, 1)
        train = read_source_manifest(train_path, root, expected_partition="train")
        validation = read_source_manifest(
            validation_path, root, expected_partition="validation"
        )

        with pytest.raises(DatasetIntegrityError, match="identity leakage"):
            assert_identity_disjoint({"train": train, "validation": validation})


def test_preprocess_records_success_and_safe_rejection() -> None:
    with _workspace() as workspace:
        source_root, manifest = _write_source_partition(workspace, "train", 0, 1)
        output_manifest = workspace / "processed" / "train.csv"

        result = preprocess_partition(
            source_root=source_root,
            source_manifest=manifest,
            output_root=workspace / "aligned",
            output_manifest=output_manifest,
            partition="train",
            preprocessor=_FakePreprocessor(),
        )

        assert result.input_image_count == 5
        assert result.successful_image_count == 4
        assert result.rejected_image_count == 1
        assert result.complete_identity_count == 0
        assert result.usable_identity_count == 1
        assert result.rejection_reasons == {"zero_faces": 1}
        rows = list(csv.DictReader(output_manifest.open(encoding="utf-8")))
        rejected = [row for row in rows if row["status"] == "rejected"]
        assert len(rejected) == 1
        assert rejected[0]["reason"] == "zero_faces"
        assert rejected[0]["relative_path"] == ""


def test_aligned_dataset_filters_unusable_identities_and_returns_tensor() -> None:
    with _workspace() as workspace:
        source_root, manifest = _write_source_partition(workspace, "train", 0, 2)
        output_root = workspace / "aligned"
        output_manifest = workspace / "processed" / "train.csv"
        preprocess_partition(
            source_root=source_root,
            source_manifest=manifest,
            output_root=output_root,
            output_manifest=output_manifest,
            partition="train",
            preprocessor=_FakePreprocessor(),
        )

        dataset = AlignedFaceDataset(
            output_root,
            output_manifest,
            partition="train",
            training=False,
        )
        tensor, label = dataset[0]

        assert len(dataset) == 9
        assert dataset.num_classes == 2
        assert tensor.shape == (3, 224, 224)
        assert tensor.dtype == torch.float32
        assert torch.isfinite(tensor).all()
        assert label.dtype == torch.long
