"""Synthetic tests for the frozen YuNet and alignment preprocessing contract."""

from __future__ import annotations

import numpy as np
import pytest

from ai.src.preprocessing import (
    TARGET_LANDMARKS_224,
    FaceDetectionError,
    FacePreprocessor,
    YuNetDetector,
    align_face,
    prepare_recognition_input,
    similarity_transform,
)


class FakeYuNetBackend:
    def __init__(self, faces: np.ndarray | None) -> None:
        self.faces = faces
        self.input_size: tuple[int, int] | None = None

    def setInputSize(self, input_size: tuple[int, int]) -> None:
        self.input_size = input_size

    def detect(self, image: np.ndarray) -> tuple[int, np.ndarray | None]:
        return 1, self.faces


def _face_row(*, confidence: float = 0.95) -> np.ndarray:
    return np.concatenate(
        (
            np.asarray([32.0, 24.0, 160.0, 190.0], dtype=np.float32),
            TARGET_LANDMARKS_224.reshape(-1),
            np.asarray([confidence], dtype=np.float32),
        )
    )


def test_yunet_wrapper_preserves_size_landmark_order_and_score() -> None:
    backend = FakeYuNetBackend(_face_row()[np.newaxis, :])
    detector = YuNetDetector(backend, confidence_threshold=0.9)
    image = np.zeros((224, 224, 3), dtype=np.uint8)

    detection = detector.detect_one(image)

    assert backend.input_size == (224, 224)
    np.testing.assert_allclose(detection.landmarks_xy, TARGET_LANDMARKS_224)
    assert detection.confidence == pytest.approx(0.95)


@pytest.mark.parametrize(
    ("faces", "reason"),
    [
        (None, "zero_faces"),
        (np.stack((_face_row(), _face_row())), "multiple_faces"),
        (_face_row(confidence=0.5)[np.newaxis, :], "below_confidence_threshold"),
    ],
)
def test_yunet_wrapper_rejects_invalid_face_counts_and_scores(
    faces: np.ndarray | None,
    reason: str,
) -> None:
    detector = YuNetDetector(FakeYuNetBackend(faces), confidence_threshold=0.9)
    with pytest.raises(FaceDetectionError, match=reason):
        detector.detect_one(np.zeros((224, 224, 3), dtype=np.uint8))


def test_yunet_wrapper_rejects_out_of_bounds_landmarks() -> None:
    row = _face_row()
    row[4] = -1.0
    detector = YuNetDetector(
        FakeYuNetBackend(row[np.newaxis, :]),
        confidence_threshold=0.9,
    )
    with pytest.raises(FaceDetectionError, match="landmarks_out_of_bounds"):
        detector.detect_one(np.zeros((224, 224, 3), dtype=np.uint8))


def test_similarity_transform_is_identity_for_frozen_template() -> None:
    transform = similarity_transform(TARGET_LANDMARKS_224)
    np.testing.assert_allclose(
        transform,
        np.asarray([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], dtype=np.float32),
        rtol=0.0,
        atol=1e-5,
    )


def test_similarity_transform_recovers_known_scale_and_translation() -> None:
    scale = 1.25
    translation = np.asarray([12.0, -7.0], dtype=np.float32)
    source = (TARGET_LANDMARKS_224 - translation) / scale
    transform = similarity_transform(source)
    homogeneous = np.concatenate(
        (source, np.ones((5, 1), dtype=np.float32)),
        axis=1,
    )
    actual = homogeneous @ transform.T
    np.testing.assert_allclose(actual, TARGET_LANDMARKS_224, atol=1e-4)


def test_alignment_and_recognition_tensor_contract() -> None:
    image = np.zeros((224, 224, 3), dtype=np.uint8)
    image[:, :, 2] = 255
    aligned = align_face(image, TARGET_LANDMARKS_224)
    tensor = prepare_recognition_input(aligned)

    assert aligned.shape == (224, 224, 3)
    assert tensor.shape == (3, 224, 224)
    assert tensor.dtype == np.float32
    assert tensor.flags.c_contiguous
    np.testing.assert_allclose(tensor[:, 112, 112], [
        (1.0 - 0.485) / 0.229,
        (0.0 - 0.456) / 0.224,
        (0.0 - 0.406) / 0.225,
    ], rtol=1e-6, atol=1e-6)


def test_full_pipeline_uses_one_shared_contract() -> None:
    detector = YuNetDetector(
        FakeYuNetBackend(_face_row()[np.newaxis, :]),
        confidence_threshold=0.9,
    )
    result = FacePreprocessor(detector).process(
        np.zeros((224, 224, 3), dtype=np.uint8)
    )

    assert result.aligned_bgr.shape == (224, 224, 3)
    assert result.recognition_chw.shape == (3, 224, 224)
    assert np.isfinite(result.recognition_chw).all()
