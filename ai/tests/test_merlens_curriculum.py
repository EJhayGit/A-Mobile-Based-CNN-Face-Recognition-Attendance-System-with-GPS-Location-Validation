"""Focused curriculum stage, expansion, resume, and health checks."""

from __future__ import annotations

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

from ai.src.models import ArcFaceTrainingHead
from ai.src.training.curriculum import (
    CURRICULUM_STAGES,
    classify_health,
    expand_arcface_head,
    format_live_summary,
    format_validation_summary,
    identity_manifest_sha256,
    nested_stage_identities,
    representation_statistics,
    verify_expansion,
)
from ai.src.training.curriculum_launcher import (
    controller_action,
    execute_training_mode,
)


class _TinyEmbedding(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.features = nn.Linear(12, 128)
        self.embedding_projection = nn.Identity()
        self.embedding_batch_norm = nn.BatchNorm1d(128)

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        projected = self.features(inputs.flatten(1))
        return F.normalize(self.embedding_batch_norm(projected), dim=1)


def test_curriculum_identity_sets_are_deterministic_nested_and_stable() -> None:
    mapping = tuple(f"identity_{index:06d}" for index in range(92_329))
    selections = [nested_stage_identities(mapping, count) for count in CURRICULUM_STAGES]
    assert [len(item) for item in selections] == list(CURRICULUM_STAGES)
    for earlier, later in zip(selections[:-1], selections[1:], strict=True):
        assert later[: len(earlier)] == earlier
    assert identity_manifest_sha256(selections[0]) == identity_manifest_sha256(
        nested_stage_identities(mapping, 256)
    )


def test_classifier_expansion_preserves_old_centers_and_is_deterministic() -> None:
    torch.manual_seed(17)
    old = ArcFaceTrainingHead(16)
    before = old.class_centers.detach().clone()
    first = expand_arcface_head(old, 32, seed=99)
    second = expand_arcface_head(old, 32, seed=99)
    assert torch.equal(first.class_centers[:, :16], before)
    assert torch.equal(second.class_centers[:, :16], before)
    assert torch.equal(first.class_centers[:, 16:], second.class_centers[:, 16:])
    assert first.class_centers[:, 16:].numel() > 0


def test_expansion_does_not_change_model_bn_or_fixed_embeddings() -> None:
    torch.manual_seed(23)
    model = _TinyEmbedding()
    model.eval()
    fixed = torch.randn(4, 3, 2, 2)
    old = ArcFaceTrainingHead(16)
    expanded = expand_arcface_head(old, 32, seed=101)
    before = {key: value.clone() for key, value in model.state_dict().items()}
    verify_expansion(model, old, expanded, fixed)
    assert all(torch.equal(before[key], value) for key, value in model.state_dict().items())


def test_health_gate_passes_healthy_and_stops_rank_one_collapse() -> None:
    rng = np.random.default_rng(20260811)
    embeddings = rng.normal(size=(64, 128))
    embeddings /= np.linalg.norm(embeddings, axis=1, keepdims=True)
    effective_rank, pc1 = representation_statistics(embeddings)
    healthy = classify_health(
        effective_rank=effective_rank,
        first_pc_variance=pc1,
        genuine_mean=0.6,
        impostor_mean=0.1,
        validation_accuracy=0.8,
        validation_eer=0.2,
        validation_threshold=0.4,
        finite_gradients=True,
        training_target_top1=0.5,
        training_median_target_rank=2.0,
        completed_stage_epochs=12,
        minimum_epochs_before_advance=12,
    )
    failed = classify_health(
        effective_rank=1.01,
        first_pc_variance=0.999,
        genuine_mean=0.001,
        impostor_mean=0.0,
        validation_accuracy=0.5,
        validation_eer=0.5,
        validation_threshold=0.99,
        finite_gradients=True,
        training_target_top1=0.0,
        training_median_target_rank=31.0,
        completed_stage_epochs=1,
        minimum_epochs_before_advance=12,
    )
    assert healthy.verdict == "HEALTHY"
    assert healthy.ready_to_advance
    assert failed.verdict == "FAILED"
    assert not failed.ready_to_advance
    assert "effective_rank_collapse" in failed.reasons


def _epoch_result(
    *, health: str, ready: bool, stage: int = 1, epoch: int = 1
) -> dict[str, object]:
    return {
        "health": health,
        "ready_to_advance": ready,
        "stage": stage,
        "epoch": epoch,
    }


def test_continuous_controller_continues_same_stage_when_healthy_not_ready() -> None:
    results = iter(
        (
            _epoch_result(health="HEALTHY", ready=False, stage=1, epoch=4),
            _epoch_result(health="FAILED", ready=False, stage=1, epoch=5),
        )
    )
    calls: list[str] = []

    def runner(*, approval_token: str) -> dict[str, object]:
        calls.append(approval_token)
        return next(results)

    outcome = execute_training_mode("continuous", "approved", epoch_runner=runner)
    assert outcome["actions"] == ["continue_same_stage", "stop_failed"]
    assert len(calls) == 2


def test_continuous_controller_transitions_after_healthy_ready() -> None:
    results = iter(
        (
            _epoch_result(health="HEALTHY", ready=True, stage=1, epoch=12),
            _epoch_result(health="FAILED", ready=False, stage=2, epoch=1),
        )
    )

    def runner(*, approval_token: str) -> dict[str, object]:
        return next(results)

    outcome = execute_training_mode("continuous", "approved", epoch_runner=runner)
    assert outcome["actions"] == ["transition_next_stage", "stop_failed"]
    assert controller_action(
        _epoch_result(health="HEALTHY", ready=True, stage=5, epoch=12)
    ) == "stop_complete"


def test_continuous_controller_stops_immediately_on_failed_health() -> None:
    calls = 0

    def runner(*, approval_token: str) -> dict[str, object]:
        nonlocal calls
        calls += 1
        return _epoch_result(health="FAILED", ready=False)

    outcome = execute_training_mode("continuous", "approved", epoch_runner=runner)
    assert outcome["stop_reason"] == "stop_failed"
    assert calls == 1


def test_one_epoch_mode_stops_after_exactly_one_epoch() -> None:
    calls = 0

    def runner(*, approval_token: str) -> dict[str, object]:
        nonlocal calls
        calls += 1
        return _epoch_result(health="HEALTHY", ready=False, epoch=4)

    outcome = execute_training_mode("one_epoch", "approved", epoch_runner=runner)
    assert outcome["stop_reason"] == "one_epoch_pause"
    assert calls == 1


def test_compact_live_summary_contains_requested_monitoring_fields() -> None:
    latest = {
        "elapsed_seconds": 120.0,
        "validation_accuracy": 0.6393,
        "validation_eer": 0.3607,
        "effective_rank": 3.1268,
        "first_pc_variance": 0.6622,
        "health": "HEALTHY",
        "ready_to_advance": False,
    }
    summary = format_live_summary(
        stage=1,
        epoch=5,
        minimum_epoch=12,
        batch=25,
        total_batches=138,
        samples=2400,
        elapsed_seconds=20.0,
        loss=35.5,
        latest=latest,
    )
    assert "Stage 1/5" in summary
    assert "Epoch 5/20" in summary
    assert "min 12" in summary
    assert "Batch 25/138" in summary
    assert "img/s" in summary
    assert "ETA epoch" in summary
    assert "ETA min-12" in summary
    assert "loss 35.50000" in summary
    assert "Val acc 0.6393" in summary
    assert "EER 0.3607" in summary
    assert "rank 3.127" in summary
    assert "PC1 66.22%" in summary
    assert "health HEALTHY" in summary
    assert "ready false" in summary


def test_compact_validation_summary_is_readable() -> None:
    record = {
        "stage": 1,
        "epoch": 5,
        "images_per_second": 120.0,
        "elapsed_seconds": 110.0,
        "training_loss": 35.5,
        "validation_accuracy": 0.64,
        "validation_eer": 0.36,
        "effective_rank": 3.2,
        "first_pc_variance": 0.66,
        "health": "HEALTHY",
        "ready_to_advance": False,
    }
    summary = format_validation_summary(record)
    assert "Epoch 5/20 complete" in summary
    assert "Val acc 0.6400" in summary
    assert "health HEALTHY | ready false" in summary
