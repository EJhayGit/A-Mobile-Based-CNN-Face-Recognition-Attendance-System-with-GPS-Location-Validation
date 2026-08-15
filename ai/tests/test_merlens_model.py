"""Focused checks for the final MerLens V2 architecture and checkpoint loader."""

from __future__ import annotations

from pathlib import Path

import pytest
import torch

from ai.src.models import (
    ArcFaceTrainingHead,
    build_merlens_model,
    load_merlens_checkpoint,
)


def test_merlens_embedding_and_arcface_contract() -> None:
    model = build_merlens_model().eval()
    embeddings = model(torch.randn(2, 3, 224, 224))
    assert embeddings.shape == (2, 128)
    torch.testing.assert_close(
        torch.linalg.vector_norm(embeddings, dim=1),
        torch.ones(2),
        rtol=1e-5,
        atol=1e-6,
    )
    assert ArcFaceTrainingHead(num_classes=4).logits(embeddings).shape == (2, 4)


def test_invalid_dimensions_are_rejected() -> None:
    with pytest.raises(ValueError, match="embedding_dimension"):
        build_merlens_model(embedding_dimension=0)
    with pytest.raises(ValueError, match="num_classes"):
        ArcFaceTrainingHead(num_classes=1)


def test_curriculum_checkpoint_loads_strictly(tmp_path: Path) -> None:
    expected = build_merlens_model().eval()
    checkpoint = tmp_path / "state.pt"
    torch.save(
        {
            "schema_version": 1,
            "run_name": "merlens-v2-curriculum",
            "completed_epoch": 12,
            "model_state_dict": expected.state_dict(),
        },
        checkpoint,
    )
    actual, payload = load_merlens_checkpoint(checkpoint)
    assert payload["completed_epoch"] == 12
    for expected_tensor, actual_tensor in zip(
        expected.state_dict().values(), actual.state_dict().values(), strict=True
    ):
        torch.testing.assert_close(actual_tensor, expected_tensor, rtol=0, atol=0)
