"""Strict loading for final MerLens V2 curriculum checkpoints."""

from __future__ import annotations

from pathlib import Path

import torch

from ai.src.datasets.digiface import DatasetIntegrityError

from .build import build_merlens_model


def load_merlens_checkpoint(
    checkpoint_path: str | Path,
    *,
    device: str | torch.device = "cpu",
) -> tuple[torch.nn.Module, dict[str, object]]:
    """Restore one MerLens V2 curriculum checkpoint without legacy fallbacks."""

    payload = torch.load(checkpoint_path, map_location=device, weights_only=True)
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise DatasetIntegrityError("unsupported MerLens V2 checkpoint")
    if payload.get("run_name") != "merlens-v2-curriculum":
        raise DatasetIntegrityError("checkpoint is not from MerLens V2 curriculum")
    architecture = payload.get("architecture")
    if architecture not in {None, "merlens_v2_face_embedding"}:
        raise DatasetIntegrityError("MerLens V2 checkpoint architecture mismatch")
    state = payload.get("model_state_dict")
    if not isinstance(state, dict):
        raise DatasetIntegrityError("MerLens V2 checkpoint lacks model state")

    model = build_merlens_model()
    model.load_state_dict(state, strict=True)
    model.to(device).eval()
    if not all(torch.isfinite(parameter).all() for parameter in model.parameters()):
        raise DatasetIntegrityError("MerLens V2 checkpoint contains non-finite values")
    return model, payload
