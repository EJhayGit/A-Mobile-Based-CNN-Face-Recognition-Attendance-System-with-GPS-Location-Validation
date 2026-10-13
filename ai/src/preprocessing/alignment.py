"""Frozen non-reflective five-landmark similarity alignment."""

from __future__ import annotations

import cv2
import numpy as np
from numpy.typing import NDArray


FloatArray = NDArray[np.float32]
UInt8Array = NDArray[np.uint8]


TARGET_LANDMARKS_224: FloatArray = np.asarray(
    [
        [76.5892, 103.3926],
        [147.0636, 103.0028],
        [112.0504, 143.4732],
        [83.0986, 184.7310],
        [141.4598, 184.4082],
    ],
    dtype=np.float32,
)


def _landmark_array(points: NDArray[np.floating]) -> NDArray[np.float64]:
    array = np.asarray(points, dtype=np.float64)
    if array.shape != (5, 2):
        raise ValueError("landmarks must have shape [5, 2]")
    if not np.isfinite(array).all():
        raise ValueError("landmarks must be finite")
    return array


def similarity_transform(
    source_xy: NDArray[np.floating],
    target_xy: NDArray[np.floating] = TARGET_LANDMARKS_224,
) -> FloatArray:
    """Return the least-squares non-reflective 2D similarity transform."""

    source = _landmark_array(source_xy)
    target = _landmark_array(target_xy)
    source_center = source.mean(axis=0)
    target_center = target.mean(axis=0)
    source_zero = source - source_center
    target_zero = target - target_center
    source_energy = float(np.square(source_zero).sum())
    if source_energy <= np.finfo(np.float64).eps:
        raise ValueError("source landmarks produce a degenerate transform")

    covariance = source_zero.T @ target_zero
    left, singular_values, right_transpose = np.linalg.svd(covariance)
    correction = np.eye(2, dtype=np.float64)
    if np.linalg.det(right_transpose.T @ left.T) < 0.0:
        correction[-1, -1] = -1.0
    rotation = right_transpose.T @ correction @ left.T
    scale = float((singular_values * np.diag(correction)).sum() / source_energy)
    if not np.isfinite(scale) or scale <= 0.0:
        raise ValueError("landmarks produce a non-positive similarity scale")

    linear = scale * rotation
    translation = target_center - linear @ source_center
    matrix = np.concatenate((linear, translation[:, np.newaxis]), axis=1)
    if not np.isfinite(matrix).all() or np.linalg.det(linear) <= 0.0:
        raise ValueError("landmarks produce an invalid non-reflective transform")
    return matrix.astype(np.float32)


def align_face(image_bgr: UInt8Array, landmarks_xy: FloatArray) -> UInt8Array:
    """Warp one upright BGR image to the frozen 224 by 224 face template."""

    if not isinstance(image_bgr, np.ndarray) or image_bgr.dtype != np.uint8:
        raise ValueError("image_bgr must be a uint8 NumPy array")
    if image_bgr.ndim != 3 or image_bgr.shape[2] != 3:
        raise ValueError("image_bgr must have shape [height, width, 3]")
    transform = similarity_transform(landmarks_xy)
    aligned = cv2.warpAffine(
        image_bgr,
        transform,
        (224, 224),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0),
    )
    if aligned.shape != (224, 224, 3) or aligned.dtype != np.uint8:
        raise ValueError("alignment did not produce a uint8 224 by 224 BGR image")
    return aligned
