"""Deterministic, Git-safe DigiFace archive inventory and subset extraction."""

from __future__ import annotations

import argparse
import csv
from dataclasses import asdict, dataclass
from hashlib import sha256
import json
from pathlib import Path, PurePosixPath
import random
import re
from typing import BinaryIO
from zipfile import BadZipFile, ZipFile, ZipInfo

import cv2
import numpy as np


_MEMBER_PATTERN = re.compile(r"^(?P<identity>[0-9]+)/(?P<image>[0-4])\.png$")
_EXPECTED_IMAGE_NAMES = frozenset(f"{index}.png" for index in range(5))
_PARTITION_ORDER = ("train", "validation", "held_out")


class DatasetIntegrityError(RuntimeError):
    """Raised when an archive or requested split violates the frozen contract."""


@dataclass(frozen=True)
class ArchiveInventory:
    """Aggregate, non-image evidence from an inspected DigiFace archive."""

    identity_count: int
    image_count: int
    malformed_member_count: int
    incomplete_identity_count: int
    duplicate_member_count: int
    uncompressed_bytes: int


@dataclass(frozen=True)
class SubsetInventory:
    """Aggregate evidence for one deterministic extracted subset."""

    seed: int
    train_identities: int
    validation_identities: int
    held_out_identities: int
    images_per_identity: int
    selected_identity_count: int
    selected_image_count: int
    malformed_identity_count: int
    duplicate_identity_count: int
    train_manifest_sha256: str
    validation_manifest_sha256: str
    held_out_manifest_sha256: str


@dataclass(frozen=True)
class _DecodedImage:
    image_name: str
    encoded: bytes
    encoded_sha256: str
    pixel_sha256: str


@dataclass(frozen=True)
class _SelectedIdentity:
    source_identity: str
    images: tuple[_DecodedImage, ...]


def _sha256_stream(stream: BinaryIO) -> str:
    digest = sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def _sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return _sha256_stream(stream)


def _archive_members(
    archive: ZipFile,
) -> tuple[dict[str, dict[str, ZipInfo]], ArchiveInventory]:
    identities: dict[str, dict[str, ZipInfo]] = {}
    seen_names: set[str] = set()
    malformed_members = 0
    duplicate_members = 0
    uncompressed_bytes = 0

    for member in archive.infolist():
        if member.is_dir():
            malformed_members += 1
            continue
        uncompressed_bytes += member.file_size
        if member.filename in seen_names:
            duplicate_members += 1
            continue
        seen_names.add(member.filename)

        pure_path = PurePosixPath(member.filename)
        if pure_path.is_absolute() or ".." in pure_path.parts:
            malformed_members += 1
            continue
        match = _MEMBER_PATTERN.fullmatch(member.filename)
        if match is None:
            malformed_members += 1
            continue
        identity = match.group("identity")
        image_name = f"{match.group('image')}.png"
        identities.setdefault(identity, {})[image_name] = member

    incomplete_identities = sum(
        set(images) != _EXPECTED_IMAGE_NAMES for images in identities.values()
    )
    inventory = ArchiveInventory(
        identity_count=len(identities),
        image_count=sum(len(images) for images in identities.values()),
        malformed_member_count=malformed_members,
        incomplete_identity_count=incomplete_identities,
        duplicate_member_count=duplicate_members,
        uncompressed_bytes=uncompressed_bytes,
    )
    return identities, inventory


def inspect_archive(archive_path: str | Path) -> ArchiveInventory:
    """Inspect central-directory structure without extracting image content."""

    path = Path(archive_path)
    if not path.is_file():
        raise FileNotFoundError("DigiFace archive is missing")
    try:
        with ZipFile(path) as archive:
            _, inventory = _archive_members(archive)
    except BadZipFile as error:
        raise DatasetIntegrityError("DigiFace archive is not a valid ZIP") from error
    return inventory


def _decode_member(archive: ZipFile, member: ZipInfo) -> _DecodedImage:
    encoded = archive.read(member)
    decoded = cv2.imdecode(np.frombuffer(encoded, dtype=np.uint8), cv2.IMREAD_COLOR)
    if decoded is None or decoded.ndim != 3 or decoded.shape[2] != 3:
        raise DatasetIntegrityError("malformed_image")
    if decoded.size == 0 or not np.isfinite(decoded).all():
        raise DatasetIntegrityError("malformed_image")
    return _DecodedImage(
        image_name=PurePosixPath(member.filename).name,
        encoded=encoded,
        encoded_sha256=sha256(encoded).hexdigest(),
        pixel_sha256=sha256(decoded.tobytes(order="C")).hexdigest(),
    )


def _validate_output_path(path: Path, *, label: str) -> None:
    if path.exists() and any(path.iterdir()):
        raise FileExistsError(f"{label} must be absent or empty")


def _partition_for_index(
    index: int,
    *,
    train_identities: int,
    validation_identities: int,
) -> str:
    if index < train_identities:
        return "train"
    if index < train_identities + validation_identities:
        return "validation"
    return "held_out"


def _write_manifest(
    path: Path,
    rows: list[dict[str, str | int]],
) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=(
                "partition",
                "identity",
                "image_index",
                "relative_path",
                "encoded_sha256",
                "pixel_sha256",
            ),
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)
    return _sha256_file(path)


def create_deterministic_subset(
    archive_path: str | Path,
    output_root: str | Path,
    manifest_root: str | Path,
    *,
    seed: int,
    train_identities: int,
    validation_identities: int,
    held_out_identities: int,
) -> SubsetInventory:
    """Validate and extract one deterministic identity-disjoint subset.

    Source identity names are replaced by deterministic opaque identities.
    Manifests contain only paths relative to ``output_root`` and must remain in
    the repository's ignored data area.
    """

    requested = train_identities + validation_identities + held_out_identities
    if requested <= 0:
        raise ValueError("at least one identity is required")
    if min(train_identities, validation_identities, held_out_identities) < 0:
        raise ValueError("partition identity counts must be non-negative")

    archive_path = Path(archive_path)
    output_root = Path(output_root)
    manifest_root = Path(manifest_root)
    _validate_output_path(output_root, label="output_root")
    _validate_output_path(manifest_root, label="manifest_root")

    malformed_identity_count = 0
    duplicate_identity_count = 0
    selected: list[_SelectedIdentity] = []
    accepted_encoded_hashes: set[str] = set()
    accepted_pixel_hashes: set[str] = set()

    try:
        with ZipFile(archive_path) as archive:
            identities, inventory = _archive_members(archive)
            if (
                inventory.malformed_member_count
                or inventory.duplicate_member_count
            ):
                raise DatasetIntegrityError(
                    "archive contains malformed or duplicate member paths"
                )

            candidates = sorted(identities)
            random.Random(seed).shuffle(candidates)
            for source_identity in candidates:
                members = identities[source_identity]
                if set(members) != _EXPECTED_IMAGE_NAMES:
                    malformed_identity_count += 1
                    continue

                try:
                    images = tuple(
                        _decode_member(archive, members[f"{index}.png"])
                        for index in range(5)
                    )
                except (DatasetIntegrityError, OSError):
                    malformed_identity_count += 1
                    continue

                encoded_hashes = {image.encoded_sha256 for image in images}
                pixel_hashes = {image.pixel_sha256 for image in images}
                if (
                    len(encoded_hashes) != 5
                    or len(pixel_hashes) != 5
                    or encoded_hashes & accepted_encoded_hashes
                    or pixel_hashes & accepted_pixel_hashes
                ):
                    duplicate_identity_count += 1
                    continue

                selected.append(
                    _SelectedIdentity(
                        source_identity=source_identity,
                        images=images,
                    )
                )
                accepted_encoded_hashes.update(encoded_hashes)
                accepted_pixel_hashes.update(pixel_hashes)
                if len(selected) == requested:
                    break
    except BadZipFile as error:
        raise DatasetIntegrityError("DigiFace archive is not a valid ZIP") from error

    if len(selected) != requested:
        raise DatasetIntegrityError(
            f"only {len(selected)} valid unique identities were available; "
            f"{requested} required"
        )

    output_root.mkdir(parents=True, exist_ok=True)
    manifest_root.mkdir(parents=True, exist_ok=True)
    manifest_rows: dict[str, list[dict[str, str | int]]] = {
        partition: [] for partition in _PARTITION_ORDER
    }

    for identity_index, selected_identity in enumerate(selected):
        partition = _partition_for_index(
            identity_index,
            train_identities=train_identities,
            validation_identities=validation_identities,
        )
        opaque_identity = f"identity_{identity_index:06d}"
        identity_directory = output_root / partition / opaque_identity
        identity_directory.mkdir(parents=True, exist_ok=False)
        for image_index, image in enumerate(selected_identity.images):
            relative_path = (
                Path(partition) / opaque_identity / f"{image_index}.png"
            )
            (output_root / relative_path).write_bytes(image.encoded)
            manifest_rows[partition].append(
                {
                    "partition": partition,
                    "identity": opaque_identity,
                    "image_index": image_index,
                    "relative_path": relative_path.as_posix(),
                    "encoded_sha256": image.encoded_sha256,
                    "pixel_sha256": image.pixel_sha256,
                }
            )

    manifest_hashes = {
        partition: _write_manifest(
            manifest_root / f"{partition}.csv",
            manifest_rows[partition],
        )
        for partition in _PARTITION_ORDER
    }
    result = SubsetInventory(
        seed=seed,
        train_identities=train_identities,
        validation_identities=validation_identities,
        held_out_identities=held_out_identities,
        images_per_identity=5,
        selected_identity_count=len(selected),
        selected_image_count=len(selected) * 5,
        malformed_identity_count=malformed_identity_count,
        duplicate_identity_count=duplicate_identity_count,
        train_manifest_sha256=manifest_hashes["train"],
        validation_manifest_sha256=manifest_hashes["validation"],
        held_out_manifest_sha256=manifest_hashes["held_out"],
    )
    (manifest_root / "inventory.json").write_text(
        json.dumps(asdict(result), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return result


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect_parser = subparsers.add_parser("inspect")
    inspect_parser.add_argument("--archive", type=Path, required=True)

    extract_parser = subparsers.add_parser("extract")
    extract_parser.add_argument("--archive", type=Path, required=True)
    extract_parser.add_argument("--output-root", type=Path, required=True)
    extract_parser.add_argument("--manifest-root", type=Path, required=True)
    extract_parser.add_argument("--seed", type=int, default=20260727)
    extract_parser.add_argument("--train-identities", type=int, default=800)
    extract_parser.add_argument("--validation-identities", type=int, default=100)
    extract_parser.add_argument("--held-out-identities", type=int, default=100)
    return parser.parse_args()


def main() -> int:
    """Run a non-interactive archive inspection or extraction command."""

    args = _parse_args()
    if args.command == "inspect":
        result = inspect_archive(args.archive)
    else:
        result = create_deterministic_subset(
            args.archive,
            args.output_root,
            args.manifest_root,
            seed=args.seed,
            train_identities=args.train_identities,
            validation_identities=args.validation_identities,
            held_out_identities=args.held_out_identities,
        )
    print(json.dumps(asdict(result), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
