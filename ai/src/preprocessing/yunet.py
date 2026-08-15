"""Deterministic validation around OpenCV's frozen YuNet detector contract."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import cv2
import numpy as np
from numpy.typing import NDArray

FloatArray = NDArray[np.float32]
UInt8Array = NDArray[np.uint8]


class YuNetBackend(Protocol):
    """Minimal OpenCV detector interface used by the testable wrapper."""

    def setInputSize(self, input_size: tuple[int, int]) -> None: ...

    def detect(self, image: UInt8Array) -> tuple[int, FloatArray | None]: ...


class FaceDetectionError(ValueError):
    """A deterministic, non-sensitive face-rejection result."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class FaceDetection:
    """One validated YuNet detection in upright source-image coordinates."""

    bbox_xywh: FloatArray
    landmarks_xy: FloatArray
    confidence: float


def _validate_image(image: UInt8Array) -> tuple[int, int]:
    if not isinstance(image, np.ndarray):
        raise FaceDetectionError("invalid_image_type")
    if image.dtype != np.uint8:
        raise FaceDetectionError("invalid_image_dtype")
    if image.ndim != 3 or image.shape[2] != 3:
        raise FaceDetectionError("invalid_image_shape")
    height, width = image.shape[:2]
    if height <= 0 or width <= 0:
        raise FaceDetectionError("empty_image")
    return height, width


class YuNetDetector:
    """Require exactly one finite, geometrically valid YuNet detection."""

    def __init__(
        self,
        backend: YuNetBackend,
        *,
        confidence_threshold: float,
        max_bbox_outside_fraction: float = 0.05,
    ) -> None:
        if not 0.0 < confidence_threshold <= 1.0:
            raise ValueError("confidence_threshold must be in (0, 1]")
        if not 0.0 <= max_bbox_outside_fraction <= 0.25:
            raise ValueError("max_bbox_outside_fraction must be in [0, 0.25]")
        self._backend = backend
        self.confidence_threshold = float(confidence_threshold)
        self.max_bbox_outside_fraction = float(max_bbox_outside_fraction)

    @classmethod
    def from_model(
        cls,
        model_path: str | Path,
        *,
        confidence_threshold: float,
        nms_threshold: float = 0.3,
        top_k: int = 5000,
    ) -> YuNetDetector:
        """Construct the pinned OpenCV backend from an ignored local artifact."""

        path = Path(model_path)
        if not path.is_file():
            raise FileNotFoundError("YuNet model artifact is missing")
        if not 0.0 < nms_threshold <= 1.0:
            raise ValueError("nms_threshold must be in (0, 1]")
        if top_k <= 0:
            raise ValueError("top_k must be positive")
        backend = cv2.FaceDetectorYN.create(
            str(path),
            "",
            (320, 320),
            float(confidence_threshold),
            float(nms_threshold),
            int(top_k),
        )
        return cls(backend, confidence_threshold=confidence_threshold)

    def detect_one(self, image: UInt8Array) -> FaceDetection:
        """Return one validated face or raise a stable rejection reason."""

        height, width = _validate_image(image)
        self._backend.setInputSize((width, height))
        _, raw_faces = self._backend.detect(image)
        if raw_faces is None or np.asarray(raw_faces).size == 0:
            raise FaceDetectionError("zero_faces")

        faces = np.asarray(raw_faces, dtype=np.float32)
        if faces.ndim == 1:
            faces = faces[np.newaxis, :]
        if faces.ndim != 2 or faces.shape[1] < 15:
            raise FaceDetectionError("invalid_detection_shape")
        if faces.shape[0] != 1:
            raise FaceDetectionError("multiple_faces")

        row = faces[0, :15]
        if not np.isfinite(row).all():
            raise FaceDetectionError("non_finite_detection")

        bbox = row[:4].copy()
        landmarks = row[4:14].reshape(5, 2).copy()
        confidence = float(row[14])
        if confidence < self.confidence_threshold:
            raise FaceDetectionError("below_confidence_threshold")

        x, y, box_width, box_height = (float(value) for value in bbox)
        if box_width <= 0.0 or box_height <= 0.0:
            raise FaceDetectionError("invalid_bbox")
        x_margin = width * self.max_bbox_outside_fraction
        y_margin = height * self.max_bbox_outside_fraction
        if (
            x < -x_margin
            or y < -y_margin
            or x + box_width > width + x_margin
            or y + box_height > height + y_margin
        ):
            raise FaceDetectionError("bbox_materially_out_of_bounds")
        if (
            (landmarks[:, 0] < 0.0).any()
            or (landmarks[:, 0] >= width).any()
            or (landmarks[:, 1] < 0.0).any()
            or (landmarks[:, 1] >= height).any()
        ):
            raise FaceDetectionError("landmarks_out_of_bounds")

        return FaceDetection(
            bbox_xywh=bbox,
            landmarks_xy=landmarks,
            confidence=confidence,
        )
