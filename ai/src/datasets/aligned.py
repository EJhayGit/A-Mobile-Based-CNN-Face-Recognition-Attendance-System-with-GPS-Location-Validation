"""PyTorch loader for ignored aligned images and safe preprocessing manifests."""

from __future__ import annotations

import csv
from collections import Counter
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import re

import cv2
import numpy as np
import torch
from torch import Tensor
from torch.utils.data import Dataset
from torchvision.transforms import functional as vision_functional

from ai.src.preprocessing.tensor import IMAGENET_MEAN, IMAGENET_STD

from .digiface import DatasetIntegrityError


_IDENTITY_PATTERN = re.compile(r"^identity_[0-9]{6}$")
_FIELDS = (
    "partition",
    "identity",
    "image_index",
    "relative_path",
    "status",
    "reason",
    "detection_confidence",
    "aligned_sha256",
)


@dataclass(frozen=True)
class AlignedRecord:
    """One accepted aligned-image record."""

    partition: str
    identity: str
    image_index: int
    relative_path: PurePosixPath
    aligned_sha256: str


def _safe_path(value: str, *, partition: str, identity: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or ".." in path.parts
        or len(path.parts) not in (3, 4)
        or path.parts[0] != partition
        or path.parts[-2] != identity
    ):
        raise DatasetIntegrityError("unsafe aligned-image path")
    return path


def read_preprocessing_manifest(
    manifest_path: str | Path,
    aligned_root: str | Path,
    *,
    expected_partition: str,
    minimum_images_per_identity: int = 2,
    maximum_identities: int | None = None,
) -> tuple[AlignedRecord, ...]:
    """Validate a preprocessing manifest and return usable accepted records."""

    if minimum_images_per_identity <= 0:
        raise ValueError("minimum_images_per_identity must be positive")
    root = Path(aligned_root).resolve()
    accepted: list[AlignedRecord] = []
    seen_slots: set[tuple[str, int]] = set()

    with Path(manifest_path).open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != _FIELDS:
            raise DatasetIntegrityError("preprocessing manifest fields do not match")
        for row in reader:
            partition = row["partition"]
            identity = row["identity"]
            if partition != expected_partition:
                raise DatasetIntegrityError("preprocessing partition mismatch")
            if _IDENTITY_PATTERN.fullmatch(identity) is None:
                raise DatasetIntegrityError("invalid opaque identity")
            try:
                image_index = int(row["image_index"])
            except ValueError as error:
                raise DatasetIntegrityError("invalid image index") from error
            slot = (identity, image_index)
            if image_index not in range(72) or slot in seen_slots:
                raise DatasetIntegrityError("invalid or duplicate image slot")
            seen_slots.add(slot)

            if row["status"] == "rejected":
                if row["relative_path"] or row["aligned_sha256"]:
                    raise DatasetIntegrityError("rejected row exposes an output path")
                if not row["reason"]:
                    raise DatasetIntegrityError("rejected row lacks a reason")
                continue
            if row["status"] != "accepted" or row["reason"]:
                raise DatasetIntegrityError("invalid preprocessing status")

            relative_path = _safe_path(
                row["relative_path"],
                partition=partition,
                identity=identity,
            )
            if (
                relative_path.stem != str(image_index)
                or relative_path.suffix.lower() not in (".png", ".jpg")
            ):
                raise DatasetIntegrityError("aligned image/path mismatch")
            digest = row["aligned_sha256"].strip().lower()
            if len(digest) != 64 or any(
                character not in "0123456789abcdef" for character in digest
            ):
                raise DatasetIntegrityError("invalid aligned-image SHA-256")
            accepted.append(
                AlignedRecord(
                    partition=partition,
                    identity=identity,
                    image_index=image_index,
                    relative_path=relative_path,
                    aligned_sha256=digest,
                )
            )

    counts = Counter(record.identity for record in accepted)
    usable_identities = sorted({
        identity
        for identity, count in counts.items()
        if count >= minimum_images_per_identity
    })
    if maximum_identities is not None:
        if maximum_identities <= 1:
            raise ValueError("maximum_identities must exceed one")
        usable_identities = usable_identities[:maximum_identities]
    allowed = set(usable_identities)
    usable = tuple(
        record for record in accepted if record.identity in allowed
    )
    if len(usable_identities) < 2:
        raise DatasetIntegrityError("fewer than two usable identities")
    for record in usable:
        candidate = Path(aligned_root).joinpath(*record.relative_path.parts).resolve()
        if root not in candidate.parents or not candidate.is_file():
            raise DatasetIntegrityError("aligned image is missing or unsafe")
    return usable


class AlignedFaceDataset(Dataset[tuple[Tensor, Tensor]]):
    """Load aligned images with deterministic labels and role-specific transforms."""

    def __init__(
        self,
        aligned_root: str | Path,
        manifest_path: str | Path,
        *,
        partition: str,
        training: bool,
        minimum_images_per_identity: int = 2,
        maximum_identities: int | None = None,
    ) -> None:
        records = read_preprocessing_manifest(
            manifest_path,
            aligned_root,
            expected_partition=partition,
            minimum_images_per_identity=minimum_images_per_identity,
            maximum_identities=maximum_identities,
        )
        identities = sorted({record.identity for record in records})
        allowed = set(identities)
        self.records = tuple(
            record for record in records if record.identity in allowed
        )
        self.identity_to_label = {
            identity: label for label, identity in enumerate(identities)
        }
        self.label_to_identity = tuple(identities)
        self.aligned_root = Path(aligned_root)
        self.partition = partition
        self.training = training
        self._mean = torch.tensor(IMAGENET_MEAN).view(3, 1, 1)
        self._std = torch.tensor(IMAGENET_STD).view(3, 1, 1)

    @property
    def num_classes(self) -> int:
        return len(self.label_to_identity)

    def __len__(self) -> int:
        return len(self.records)

    def _transform(self, image_bgr: np.ndarray) -> Tensor:
        rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
        tensor = torch.from_numpy(
            np.ascontiguousarray(rgb.transpose(2, 0, 1))
        ).to(dtype=torch.float32) / 255.0
        if self.training:
            if torch.rand(()) < 0.5:
                tensor = torch.flip(tensor, dims=(2,))
            brightness = float(torch.empty(()).uniform_(0.9, 1.1))
            contrast = float(torch.empty(()).uniform_(0.9, 1.1))
            saturation = float(torch.empty(()).uniform_(0.9, 1.1))
            tensor = vision_functional.adjust_brightness(tensor, brightness)
            tensor = vision_functional.adjust_contrast(tensor, contrast)
            tensor = vision_functional.adjust_saturation(tensor, saturation)
        return (tensor - self._mean) / self._std

    def __getitem__(self, index: int) -> tuple[Tensor, Tensor]:
        record = self.records[index]
        path = self.aligned_root.joinpath(*record.relative_path.parts)
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if image is None or image.shape != (224, 224, 3):
            raise DatasetIntegrityError("aligned image became unreadable")
        tensor = self._transform(image)
        if tensor.shape != (3, 224, 224) or not torch.isfinite(tensor).all():
            raise DatasetIntegrityError("invalid training tensor")
        label = torch.tensor(self.identity_to_label[record.identity], dtype=torch.long)
        return tensor, label
