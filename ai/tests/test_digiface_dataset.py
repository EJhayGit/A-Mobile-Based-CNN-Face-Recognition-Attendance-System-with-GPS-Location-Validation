"""Synthetic tests for deterministic DigiFace inventory and subset creation."""

from __future__ import annotations

import tempfile
from contextlib import contextmanager
from pathlib import Path
from zipfile import ZIP_STORED, ZipFile

import cv2
import numpy as np
import pytest

from ai.src.datasets.digiface import (
    DatasetIntegrityError,
    create_deterministic_subset,
    inspect_archive,
)


@contextmanager
def _workspace() -> Path:
    Path("tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="digiface-test-", dir="tmp") as path:
        yield Path(path)


def _png_bytes(value: int) -> bytes:
    image = np.full((12, 10, 3), value, dtype=np.uint8)
    success, encoded = cv2.imencode(".png", image)
    assert success
    return encoded.tobytes()


def _write_archive(
    path: Path,
    identity_count: int,
    *,
    malformed_identity: int | None = None,
    duplicate_identity: int | None = None,
) -> None:
    with ZipFile(path, "w", compression=ZIP_STORED) as archive:
        for identity in range(identity_count):
            for image_index in range(5):
                if identity == malformed_identity and image_index == 4:
                    payload = b"not a PNG"
                else:
                    value_identity = 0 if identity == duplicate_identity else identity
                    payload = _png_bytes(value_identity * 5 + image_index)
                archive.writestr(f"{100000 + identity}/{image_index}.png", payload)


def test_inspect_archive_reports_exact_aggregate_structure() -> None:
    with _workspace() as workspace:
        archive_path = workspace / "sample.zip"
        _write_archive(archive_path, 6)

        inventory = inspect_archive(archive_path)

        assert inventory.identity_count == 6
        assert inventory.image_count == 30
        assert inventory.malformed_member_count == 0
        assert inventory.incomplete_identity_count == 0
        assert inventory.duplicate_member_count == 0


def test_subset_is_deterministic_identity_disjoint_and_relative() -> None:
    with _workspace() as workspace:
        archive_path = workspace / "sample.zip"
        _write_archive(archive_path, 10)

        first = create_deterministic_subset(
            archive_path,
            workspace / "subset-one",
            workspace / "manifests-one",
            seed=20260727,
            train_identities=4,
            validation_identities=1,
            held_out_identities=1,
        )
        second = create_deterministic_subset(
            archive_path,
            workspace / "subset-two",
            workspace / "manifests-two",
            seed=20260727,
            train_identities=4,
            validation_identities=1,
            held_out_identities=1,
        )

        assert first == second
        assert first.selected_identity_count == 6
        assert first.selected_image_count == 30
        all_identities: set[str] = set()
        for partition, expected_identities in (
            ("train", 4),
            ("validation", 1),
            ("held_out", 1),
        ):
            rows = (
                (workspace / "manifests-one" / f"{partition}.csv")
                .read_text(encoding="utf-8")
                .splitlines()[1:]
            )
            identities = {row.split(",")[1] for row in rows}
            assert len(rows) == expected_identities * 5
            assert len(identities) == expected_identities
            assert not all_identities & identities
            all_identities.update(identities)
            assert all("tmp" not in row and ":\\" not in row for row in rows)


def test_subset_replaces_malformed_and_duplicate_identities() -> None:
    with _workspace() as workspace:
        archive_path = workspace / "sample.zip"
        _write_archive(
            archive_path,
            12,
            malformed_identity=3,
            duplicate_identity=8,
        )

        inventory = create_deterministic_subset(
            archive_path,
            workspace / "subset",
            workspace / "manifests",
            seed=7,
            train_identities=8,
            validation_identities=1,
            held_out_identities=1,
        )

        assert inventory.selected_identity_count == 10
        assert inventory.selected_image_count == 50
        assert inventory.malformed_identity_count == 1
        assert inventory.duplicate_identity_count == 1


def test_subset_rejects_unsafe_archive_member() -> None:
    with _workspace() as workspace:
        archive_path = workspace / "unsafe.zip"
        with ZipFile(archive_path, "w", compression=ZIP_STORED) as archive:
            archive.writestr("../escape.png", _png_bytes(1))

        with pytest.raises(DatasetIntegrityError, match="malformed"):
            create_deterministic_subset(
                archive_path,
                workspace / "subset",
                workspace / "manifests",
                seed=1,
                train_identities=1,
                validation_identities=0,
                held_out_identities=0,
            )
