"""One deterministic detection, alignment, and tensor-preparation path."""

from __future__ import annotations

from dataclasses import dataclass

from numpy.typing import NDArray
import numpy as np

from .alignment import align_face
from .tensor import prepare_recognition_input
from .yunet import FaceDetection, YuNetDetector


@dataclass(frozen=True)
class PreprocessingResult:
    """In-memory preprocessing output; callers must not persist biometric data."""

    detection: FaceDetection
    aligned_bgr: NDArray[np.uint8]
    recognition_chw: NDArray[np.float32]


class FacePreprocessor:
    """Apply the single frozen preprocessing path to one upright BGR image."""

    def __init__(self, detector: YuNetDetector) -> None:
        self._detector = detector

    def process(self, image_bgr: NDArray[np.uint8]) -> PreprocessingResult:
        detection = self._detector.detect_one(image_bgr)
        aligned = align_face(image_bgr, detection.landmarks_xy)
        recognition = prepare_recognition_input(aligned)
        return PreprocessingResult(
            detection=detection,
            aligned_bgr=aligned,
            recognition_chw=recognition,
        )
