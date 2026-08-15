"""Strict loader for final-lineage MerLens V2 checkpoints."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import torch

from .build import build_merlens_model


def load_merlens_checkpoint(
    checkpoint_path: str | Path,
    *,
    device: str | torch.device = "cpu",
) -> tuple[torch.nn.Module, dict[str, Any]]:
    """Restore an inference-only MerLens V2 model from a curriculum checkpoint."""

    payload = torch.load(checkpoint_path, map_location=device, weights_only=True)
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise ValueError("unsupported MerLens checkpoint")
    if payload.get("run_name") != "merlens-v2-curriculum":
        raise ValueError("checkpoint is not from the final MerLens curriculum")
    state = payload.get("model_state_dict")
    if not isinstance(state, dict):
        raise TypeError("checkpoint lacks a model state")

    model = build_merlens_model()
    model.load_state_dict(state, strict=True)
    model.to(device).eval()
    if not all(torch.isfinite(parameter).all() for parameter in model.parameters()):
        raise ValueError("checkpoint contains non-finite model parameters")
    return model, payload
