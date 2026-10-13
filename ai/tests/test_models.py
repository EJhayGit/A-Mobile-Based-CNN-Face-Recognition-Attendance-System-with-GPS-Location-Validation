"""Synthetic checks for MerLens V2 and its ArcFace head."""

from __future__ import annotations

from pathlib import Path

import pytest
import torch

from ai.src.models import (
    ArcFaceTrainingHead,
    build_merlens_model,
    load_merlens_checkpoint,
)


def _assert_embedding_contract(embeddings: torch.Tensor, batch_size: int) -> None:
    assert embeddings.shape == (batch_size, 128)
    assert embeddings.dtype == torch.float32
    assert torch.isfinite(embeddings).all()
    torch.testing.assert_close(
        torch.linalg.vector_norm(embeddings, dim=1),
        torch.ones(batch_size, device=embeddings.device),
        rtol=1e-5,
        atol=1e-6,
    )


def _run_forward_backward_and_update(device: torch.device) -> None:
    torch.manual_seed(20260729)
    model = build_merlens_model().to(device)
    arcface = ArcFaceTrainingHead(num_classes=4).to(device)
    model.train()
    arcface.train()

    inputs = torch.randn(4, 3, 224, 224, device=device)
    labels = torch.arange(4, device=device, dtype=torch.long)
    embeddings = model(inputs)
    _assert_embedding_contract(embeddings, batch_size=4)

    logits = arcface.logits(embeddings)
    assert logits.shape == (4, 4)
    assert torch.isfinite(logits).all()

    loss = arcface(embeddings, labels)
    assert loss.ndim == 0
    assert torch.isfinite(loss)

    optimizer = torch.optim.SGD(
        [*model.parameters(), *arcface.parameters()],
        lr=1e-3,
    )
    optimizer.zero_grad(set_to_none=True)
    loss.backward()

    backbone_parameters = list(model.features.parameters())
    assert any(
        parameter.grad is not None
        and torch.isfinite(parameter.grad).all()
        and torch.count_nonzero(parameter.grad) > 0
        for parameter in backbone_parameters
    )
    assert model.embedding_projection.weight.grad is not None
    assert torch.isfinite(model.embedding_projection.weight.grad).all()
    assert model.embedding_batch_norm.weight.grad is not None
    assert torch.isfinite(model.embedding_batch_norm.weight.grad).all()
    assert arcface.class_centers.grad is not None
    assert torch.isfinite(arcface.class_centers.grad).all()

    before_step = [parameter.detach().clone() for parameter in backbone_parameters]
    optimizer.step()
    assert any(
        not torch.equal(before, after.detach())
        for before, after in zip(before_step, backbone_parameters, strict=True)
    )


def test_cpu_forward_backward_and_backbone_update() -> None:
    _run_forward_backward_and_update(torch.device("cpu"))


@pytest.mark.skipif(not torch.cuda.is_available(), reason="CUDA is required")
def test_cuda_forward_backward_and_backbone_update() -> None:
    _run_forward_backward_and_update(torch.device("cuda"))


def test_invalid_model_and_arcface_dimensions_are_rejected() -> None:
    with pytest.raises(ValueError, match="embedding_dimension"):
        build_merlens_model(embedding_dimension=0)
    with pytest.raises(ValueError, match="num_classes"):
        ArcFaceTrainingHead(num_classes=1)


def test_curriculum_checkpoint_loads_strict_merlens_model() -> None:
    checkpoint_path = Path("tmp/curriculum-load-test/last_state.pt")
    checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        expected = build_merlens_model().eval()
        torch.save(
            {
                "schema_version": 1,
                "run_name": "merlens-v2-curriculum",
                "completed_epoch": 12,
                "model_state_dict": expected.state_dict(),
            },
            checkpoint_path,
        )
        actual, payload = load_merlens_checkpoint(checkpoint_path)
        assert actual.architecture_name == "merlens_v2_face_embedding"
        assert payload["completed_epoch"] == 12
        for expected_tensor, actual_tensor in zip(
            expected.state_dict().values(), actual.state_dict().values(), strict=True
        ):
            torch.testing.assert_close(actual_tensor, expected_tensor, rtol=0.0, atol=0.0)
    finally:
        checkpoint_path.unlink(missing_ok=True)
        checkpoint_path.parent.rmdir()


def test_legacy_model_v1_checkpoint_is_rejected() -> None:
    checkpoint_path = Path("tmp/curriculum-load-test/legacy-state.pt")
    checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        torch.save(
            {
                "schema_version": 1,
                "run_name": "legacy-model-v1",
                "architecture": "mobilenet_v3_small_face_embedding",
                "model_state_dict": {},
            },
            checkpoint_path,
        )
        with pytest.raises(RuntimeError, match="not from MerLens V2 curriculum"):
            load_merlens_checkpoint(checkpoint_path)
    finally:
        checkpoint_path.unlink(missing_ok=True)
        checkpoint_path.parent.rmdir()
