"""Recognition tensor preparation shared by training and inference."""

from __future__ import annotations

import cv2
import numpy as np
from numpy.typing import NDArray

FloatArray = NDArray[np.float32]
UInt8Array = NDArray[np.uint8]

IMAGENET_MEAN = np.asarray([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.asarray([0.229, 0.224, 0.225], dtype=np.float32)


def prepare_recognition_input(aligned_bgr: UInt8Array) -> FloatArray:
    """Convert one aligned BGR crop to contiguous normalized CHW float32."""

    if not isinstance(aligned_bgr, np.ndarray) or aligned_bgr.dtype != np.uint8:
        raise ValueError("aligned_bgr must be a uint8 NumPy array")
    if aligned_bgr.shape != (224, 224, 3):
        raise ValueError("aligned_bgr must have shape [224, 224, 3]")
    rgb = cv2.cvtColor(aligned_bgr, cv2.COLOR_BGR2RGB)
    scaled = rgb.astype(np.float32) / np.float32(255.0)
    normalized = (scaled - IMAGENET_MEAN) / IMAGENET_STD
    return np.ascontiguousarray(normalized.transpose(2, 0, 1), dtype=np.float32)
