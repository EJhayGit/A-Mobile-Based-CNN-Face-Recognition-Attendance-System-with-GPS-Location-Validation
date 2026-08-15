"""Deterministic cosine-verification pairs, calibration, and exact metrics."""

from __future__ import annotations

import random
from collections.abc import Sequence
from dataclasses import dataclass, replace
from itertools import combinations
from typing import Protocol

import numpy as np

from ai.src.datasets.digiface import DatasetIntegrityError


class IdentityRecord(Protocol):
    identity: str


@dataclass(frozen=True)
class VerificationPair:
    left_index: int
    right_index: int
    is_genuine: bool


@dataclass(frozen=True)
class VerificationMetrics:
    threshold: float
    genuine_pairs: int
    impostor_pairs: int
    true_accepts: int
    false_rejects: int
    true_rejects: int
    false_accepts: int
    accuracy: float
    false_acceptance_rate: float
    false_rejection_rate: float
    balanced_error_rate: float
    equal_error_rate: float | None


def generate_verification_pairs(
    records: Sequence[IdentityRecord],
    *,
    seed: int,
    maximum_genuine_pairs_per_identity: int | None = None,
) -> tuple[VerificationPair, ...]:
    """Use capped genuine pairs and an equal seeded unique impostor set."""

    by_identity: dict[str, list[int]] = {}
    for index, record in enumerate(records):
        by_identity.setdefault(record.identity, []).append(index)
    if len(by_identity) < 2:
        raise DatasetIntegrityError("verification requires at least two identities")

    if (
        maximum_genuine_pairs_per_identity is not None
        and maximum_genuine_pairs_per_identity <= 0
    ):
        raise ValueError("maximum genuine pairs per identity must be positive")
    genuine: list[VerificationPair] = []
    genuine_generator = random.Random(seed)
    identity_order = (
        by_identity
        if maximum_genuine_pairs_per_identity is None
        else sorted(by_identity)
    )
    for identity in identity_order:
        candidates = [
            VerificationPair(left, right, True)
            for left, right in combinations(by_identity[identity], 2)
        ]
        if (
            maximum_genuine_pairs_per_identity is not None
            and len(candidates) > maximum_genuine_pairs_per_identity
        ):
            candidates = genuine_generator.sample(
                candidates,
                maximum_genuine_pairs_per_identity,
            )
        genuine.extend(candidates)
    if not genuine:
        raise DatasetIntegrityError("verification requires genuine pairs")
    total_pair_candidates = len(records) * (len(records) - 1) // 2
    same_identity_candidates = sum(
        len(indices) * (len(indices) - 1) // 2 for indices in by_identity.values()
    )
    impostor_candidate_count = total_pair_candidates - same_identity_candidates
    if impostor_candidate_count < len(genuine):
        raise DatasetIntegrityError("insufficient unique impostor pairs")

    # Preserve the exact Model V1 behavior for its small manifests. MerLens's
    # larger validation/test sets use bounded rejection sampling instead of
    # materializing tens of millions of Python objects.
    if total_pair_candidates <= 2_000_000:
        impostor_candidates = [
            VerificationPair(left, right, False)
            for left, right in combinations(range(len(records)), 2)
            if records[left].identity != records[right].identity
        ]
        random.Random(seed).shuffle(impostor_candidates)
        impostor = impostor_candidates[: len(genuine)]
    else:
        generator = random.Random(seed)
        selected: set[tuple[int, int]] = set()
        impostor = []
        while len(impostor) < len(genuine):
            left = generator.randrange(len(records))
            right = generator.randrange(len(records))
            if left == right:
                continue
            if left > right:
                left, right = right, left
            key = (left, right)
            if key in selected or records[left].identity == records[right].identity:
                continue
            selected.add(key)
            impostor.append(VerificationPair(left, right, False))
    return tuple(genuine + impostor)


def pair_scores(
    embeddings: np.ndarray,
    pairs: Sequence[VerificationPair],
) -> tuple[np.ndarray, np.ndarray]:
    """Return cosine scores and genuine labels for normalized embeddings."""

    values = np.asarray(embeddings, dtype=np.float32)
    if values.ndim != 2 or values.shape[1] != 128:
        raise ValueError("embeddings must have shape [batch, 128]")
    if not np.isfinite(values).all():
        raise ValueError("embeddings must be finite")
    norms = np.linalg.norm(values, axis=1)
    if not np.allclose(norms, 1.0, rtol=1e-4, atol=1e-5):
        raise ValueError("embeddings must be L2 normalized")
    left = np.fromiter((pair.left_index for pair in pairs), dtype=np.int64)
    right = np.fromiter((pair.right_index for pair in pairs), dtype=np.int64)
    if left.size == 0 or left.max() >= len(values) or right.max() >= len(values):
        raise ValueError("verification pair index is invalid")
    scores = np.sum(values[left] * values[right], axis=1, dtype=np.float32)
    labels = np.fromiter((pair.is_genuine for pair in pairs), dtype=np.bool_)
    return scores, labels


def metrics_at_threshold(
    scores: np.ndarray,
    genuine_labels: np.ndarray,
    *,
    threshold: float,
) -> VerificationMetrics:
    """Calculate exact-denominator verification metrics for one threshold."""

    scores = np.asarray(scores, dtype=np.float64)
    genuine = np.asarray(genuine_labels, dtype=np.bool_)
    if scores.ndim != 1 or genuine.shape != scores.shape or not len(scores):
        raise ValueError("scores and labels must be equally sized vectors")
    if not np.isfinite(scores).all() or not np.isfinite(threshold):
        raise ValueError("scores and threshold must be finite")
    accepted = scores >= threshold
    true_accepts = int(np.count_nonzero(accepted & genuine))
    false_rejects = int(np.count_nonzero(~accepted & genuine))
    false_accepts = int(np.count_nonzero(accepted & ~genuine))
    true_rejects = int(np.count_nonzero(~accepted & ~genuine))
    genuine_count = true_accepts + false_rejects
    impostor_count = false_accepts + true_rejects
    if genuine_count == 0 or impostor_count == 0:
        raise ValueError("both genuine and impostor pairs are required")
    far = false_accepts / impostor_count
    frr = false_rejects / genuine_count
    return VerificationMetrics(
        threshold=float(threshold),
        genuine_pairs=genuine_count,
        impostor_pairs=impostor_count,
        true_accepts=true_accepts,
        false_rejects=false_rejects,
        true_rejects=true_rejects,
        false_accepts=false_accepts,
        accuracy=(true_accepts + true_rejects) / len(scores),
        false_acceptance_rate=far,
        false_rejection_rate=frr,
        balanced_error_rate=(far + frr) / 2.0,
        equal_error_rate=None,
    )


def calibrate_threshold(
    scores: np.ndarray,
    genuine_labels: np.ndarray,
) -> VerificationMetrics:
    """Minimize |FAR-FRR| on validation, breaking ties by highest threshold."""

    scores = np.asarray(scores, dtype=np.float64)
    if scores.ndim != 1 or not len(scores) or not np.isfinite(scores).all():
        raise ValueError("scores must be a finite non-empty vector")
    genuine = np.asarray(genuine_labels, dtype=np.bool_)
    if genuine.shape != scores.shape:
        raise ValueError("scores and labels must be equally sized vectors")
    genuine_count = int(np.count_nonzero(genuine))
    impostor_count = len(genuine) - genuine_count
    if genuine_count == 0 or impostor_count == 0:
        raise ValueError("both genuine and impostor pairs are required")

    order = np.argsort(-scores, kind="stable")
    sorted_scores = scores[order]
    sorted_genuine = genuine[order]
    cumulative_genuine = np.cumsum(sorted_genuine, dtype=np.int64)
    cumulative_impostor = np.cumsum(~sorted_genuine, dtype=np.int64)
    group_ends = np.flatnonzero(np.r_[sorted_scores[:-1] != sorted_scores[1:], True])

    def from_counts(
        *,
        threshold: float,
        true_accepts: int,
        false_accepts: int,
    ) -> VerificationMetrics:
        false_rejects = genuine_count - true_accepts
        true_rejects = impostor_count - false_accepts
        far = false_accepts / impostor_count
        frr = false_rejects / genuine_count
        return VerificationMetrics(
            threshold=threshold,
            genuine_pairs=genuine_count,
            impostor_pairs=impostor_count,
            true_accepts=true_accepts,
            false_rejects=false_rejects,
            true_rejects=true_rejects,
            false_accepts=false_accepts,
            accuracy=(true_accepts + true_rejects) / len(scores),
            false_acceptance_rate=far,
            false_rejection_rate=frr,
            balanced_error_rate=(far + frr) / 2.0,
            equal_error_rate=None,
        )

    evaluated = [
        from_counts(
            threshold=float(np.nextafter(sorted_scores[0], np.inf)),
            true_accepts=0,
            false_accepts=0,
        )
    ]
    evaluated.extend(
        from_counts(
            threshold=float(sorted_scores[index]),
            true_accepts=int(cumulative_genuine[index]),
            false_accepts=int(cumulative_impostor[index]),
        )
        for index in group_ends
    )
    evaluated.append(
        from_counts(
            threshold=float(np.nextafter(sorted_scores[-1], -np.inf)),
            true_accepts=genuine_count,
            false_accepts=impostor_count,
        )
    )
    selected = min(
        evaluated,
        key=lambda metric: (
            abs(metric.false_acceptance_rate - metric.false_rejection_rate),
            -metric.threshold,
        ),
    )
    return replace(
        selected,
        equal_error_rate=selected.balanced_error_rate,
    )
