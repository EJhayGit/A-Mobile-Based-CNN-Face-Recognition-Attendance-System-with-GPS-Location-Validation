"""FP32 ONNX opset-18 export for the inference-only embedding model."""

from __future__ import annotations

from pathlib import Path

import torch
from torch import Tensor, nn


def export_embedding_model_onnx(
    model: nn.Module,
    output_path: str | Path,
    example_input: Tensor,
) -> Path:
    """Export a dynamic-batch inference graph and return its local path."""

    if example_input.ndim != 4 or tuple(example_input.shape[1:]) != (3, 224, 224):
        raise ValueError("example_input must have shape [batch, 3, 224, 224]")
    if example_input.dtype != torch.float32:
        raise ValueError("example_input must use float32")

    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    model.eval()
    batch_dimension = torch.export.Dim("batch", min=1)

    torch.onnx.export(
        model,
        (example_input,),
        destination,
        input_names=["input"],
        output_names=["embedding"],
        opset_version=18,
        dynamo=True,
        dynamic_shapes=({0: batch_dimension},),
        external_data=False,
        verbose=False,
    )
    return destination
