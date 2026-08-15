"""Synthetic tests for deterministic validation calibration and metrics."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pytest

from ai.src.evaluation import (
    calibrate_threshold,
    generate_verification_pairs,
    metrics_at_threshold,
    pair_scores,
)
from ai.src.evaluation.lfw_external import fixed_threshold_metrics


@dataclass(frozen=True)
class _Record:
    identity: str


def test_pairs_are_balanced_unique_and_deterministic() -> None:
    records = tuple(
        _Record(identity) for identity in ("a", "a", "a", "b", "b", "b", "c", "c", "c")
    )
    first = generate_verification_pairs(records, seed=20260727)
    second = generate_verification_pairs(records, seed=20260727)

    assert first == second
    genuine = [pair for pair in first if pair.is_genuine]
    impostor = [pair for pair in first if not pair.is_genuine]
    assert len(genuine) == 9
    assert len(impostor) == 9
    assert len({(pair.left_index, pair.right_index) for pair in first}) == 18


def test_cosine_scores_calibration_and_exact_denominators() -> None:
    embeddings = np.zeros((4, 128), dtype=np.float32)
    embeddings[0, 0] = 1.0
    embeddings[1, :2] = np.asarray([0.8, 0.6], dtype=np.float32)
    embeddings[2, 1] = 1.0
    embeddings[3, :2] = np.asarray([-0.8, 0.6], dtype=np.float32)
    records = tuple(_Record(identity) for identity in ("a", "a", "b", "b"))
    pairs = generate_verification_pairs(records, seed=1)

    scores, labels = pair_scores(embeddings, pairs)
    calibrated = calibrate_threshold(scores, labels)
    repeated = metrics_at_threshold(
        scores,
        labels,
        threshold=calibrated.threshold,
    )

    assert calibrated.threshold == repeated.threshold
    assert calibrated.true_accepts == repeated.true_accepts
    assert calibrated.false_rejects == repeated.false_rejects
    assert calibrated.true_rejects == repeated.true_rejects
    assert calibrated.false_accepts == repeated.false_accepts
    assert repeated.equal_error_rate is None
    assert calibrated.genuine_pairs == 2
    assert calibrated.impostor_pairs == 2
    assert calibrated.accuracy == pytest.approx(1.0)
    assert calibrated.false_acceptance_rate == pytest.approx(0.0)
    assert calibrated.false_rejection_rate == pytest.approx(0.0)
    assert calibrated.balanced_error_rate == pytest.approx(0.0)
    assert calibrated.equal_error_rate == pytest.approx(0.0)


def test_fixed_threshold_reports_balanced_error_not_eer() -> None:
    metrics = metrics_at_threshold(
        np.asarray([0.9, 0.4, 0.8, 0.1]),
        np.asarray([True, True, False, False]),
        threshold=0.5,
    )

    assert metrics.false_rejection_rate == pytest.approx(0.5)
    assert metrics.false_acceptance_rate == pytest.approx(0.5)
    assert metrics.balanced_error_rate == pytest.approx(0.5)
    assert metrics.equal_error_rate is None


def test_non_normalized_embeddings_are_rejected() -> None:
    embeddings = np.ones((2, 128), dtype=np.float32)
    pairs = generate_verification_pairs(
        (_Record("a"), _Record("a"), _Record("b"), _Record("b")),
        seed=1,
    )
    with pytest.raises(ValueError, match="L2 normalized"):
        pair_scores(embeddings, pairs)


def test_lfw_fixed_metrics_count_missing_preprocessing_as_rejection() -> None:
    labels = np.asarray([True, True, False, False], dtype=bool)
    accepted = np.asarray([True, False, True, False], dtype=bool)
    metrics = fixed_threshold_metrics(labels, accepted)
    assert metrics["accuracy"] == 0.5
    assert metrics["false_acceptance_rate"] == 0.5
    assert metrics["false_rejection_rate"] == 0.5
    assert metrics["balanced_error_rate"] == 0.5
