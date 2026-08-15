"""Safe relative-path manifest validation and identity-leakage checks."""

from __future__ import annotations

import csv
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path, PurePosixPath
import re

from .digiface import DatasetIntegrityError


_IDENTITY_PATTERN = re.compile(r"^identity_[0-9]{6}$")
_SOURCE_FIELDS = (
    "partition",
    "identity",
    "image_index",
    "relative_path",
    "encoded_sha256",
    "pixel_sha256",
)


@dataclass(frozen=True)
class ManifestRecord:
    """One validated source image reference without a private absolute path."""

    partition: str
    identity: str
    image_index: int
    relative_path: PurePosixPath
    encoded_sha256: str
    pixel_sha256: str


def _digest(value: str, *, field: str) -> str:
    normalized = value.strip().lower()
    if len(normalized) != 64 or any(
        character not in "0123456789abcdef" for character in normalized
    ):
        raise DatasetIntegrityError(f"invalid {field}")
    return normalized


def _safe_relative_path(value: str, *, partition: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or ".." in path.parts
        or len(path.parts) != 3
        or path.parts[0] != partition
    ):
        raise DatasetIntegrityError("manifest contains an unsafe relative path")
    return path


def _resolved_member(root: Path, relative_path: PurePosixPath) -> Path:
    root_resolved = root.resolve()
    candidate = root.joinpath(*relative_path.parts).resolve()
    if root_resolved not in candidate.parents:
        raise DatasetIntegrityError("manifest path escapes dataset root")
    return candidate


def read_source_manifest(
    manifest_path: str | Path,
    dataset_root: str | Path,
    *,
    expected_partition: str,
    require_files: bool = True,
    require_five_images: bool = True,
) -> tuple[ManifestRecord, ...]:
    """Read and validate one ignored source manifest."""

    root = Path(dataset_root)
    records: list[ManifestRecord] = []
    seen_paths: set[PurePosixPath] = set()
    seen_slots: set[tuple[str, int]] = set()
    identity_images: dict[str, set[int]] = {}

    with Path(manifest_path).open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != _SOURCE_FIELDS:
            raise DatasetIntegrityError("source manifest fields do not match")
        for row in reader:
            partition = row["partition"]
            identity = row["identity"]
            if partition != expected_partition:
                raise DatasetIntegrityError("manifest partition mismatch")
            if _IDENTITY_PATTERN.fullmatch(identity) is None:
                raise DatasetIntegrityError("invalid opaque identity")
            try:
                image_index = int(row["image_index"])
            except ValueError as error:
                raise DatasetIntegrityError("invalid image index") from error
            if image_index not in range(5):
                raise DatasetIntegrityError("invalid image index")
            relative_path = _safe_relative_path(
                row["relative_path"],
                partition=partition,
            )
            if relative_path.parts[1] != identity:
                raise DatasetIntegrityError("manifest identity/path mismatch")
            if relative_path.name != f"{image_index}.png":
                raise DatasetIntegrityError("manifest image/path mismatch")
            if relative_path in seen_paths or (identity, image_index) in seen_slots:
                raise DatasetIntegrityError("duplicate manifest record")
            member = _resolved_member(root, relative_path)
            if require_files and not member.is_file():
                raise DatasetIntegrityError("manifest source image is missing")

            seen_paths.add(relative_path)
            seen_slots.add((identity, image_index))
            identity_images.setdefault(identity, set()).add(image_index)
            records.append(
                ManifestRecord(
                    partition=partition,
                    identity=identity,
                    image_index=image_index,
                    relative_path=relative_path,
                    encoded_sha256=_digest(
                        row["encoded_sha256"], field="encoded SHA-256"
                    ),
                    pixel_sha256=_digest(
                        row["pixel_sha256"], field="pixel SHA-256"
                    ),
                )
            )

    if not records:
        raise DatasetIntegrityError("source manifest is empty")
    if require_five_images and any(
        indices != set(range(5)) for indices in identity_images.values()
    ):
        raise DatasetIntegrityError("manifest identity does not contain five images")
    return tuple(records)


def assert_identity_disjoint(
    manifests: dict[str, tuple[ManifestRecord, ...]],
) -> dict[str, int]:
    """Prove that no opaque identity appears in multiple partitions."""

    partitions = list(manifests)
    identities = {
        partition: {record.identity for record in records}
        for partition, records in manifests.items()
    }
    for index, left in enumerate(partitions):
        for right in partitions[index + 1 :]:
            overlap = identities[left] & identities[right]
            if overlap:
                raise DatasetIntegrityError(
                    f"identity leakage between {left} and {right}"
                )
    return {partition: len(values) for partition, values in identities.items()}


def sha256_file(path: str | Path) -> str:
    """Hash one file without loading it in full."""

    digest = sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
