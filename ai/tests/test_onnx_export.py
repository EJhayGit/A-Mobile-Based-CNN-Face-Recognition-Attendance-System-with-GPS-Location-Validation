"""Synthetic ONNX validation and desktop CPU parity smoke test."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import pytest
import torch

from ai.src.export.export_onnx import export_embedding_model_onnx
from ai.src.export.final_export import export_and_verify_final_model
from ai.src.models import build_merlens_model


def test_fp32_opset18_export_validation_and_cpu_parity() -> None:
    torch.manual_seed(20260729)
    model = build_merlens_model().eval()
    export_input = torch.randn(2, 3, 224, 224, dtype=torch.float32)
    parity_input = torch.randn(3, 3, 224, 224, dtype=torch.float32)
    output_path = Path("tmp/onnx-smoke/face_embedding_smoke.onnx")

    try:
        export_embedding_model_onnx(model, output_path, export_input)
        graph = onnx.load(output_path)
        onnx.checker.check_model(graph)
        assert graph.opset_import[0].version == 18
        assert graph.graph.input[0].name == "input"
        assert graph.graph.output[0].name == "embedding"

        with torch.inference_mode():
            expected = model(parity_input).cpu().numpy()

        session = ort.InferenceSession(
            str(output_path),
            providers=["CPUExecutionProvider"],
        )
        actual = session.run(
            ["embedding"],
            {"input": parity_input.numpy()},
        )[0]

        assert actual.shape == (3, 128)
        assert np.isfinite(actual).all()
        max_absolute_difference = float(np.max(np.abs(actual - expected)))
        cosine_similarity = np.sum(actual * expected, axis=1) / (
            np.linalg.norm(actual, axis=1) * np.linalg.norm(expected, axis=1)
        )
        minimum_cosine_similarity = float(np.min(cosine_similarity))
        print(
            "ONNX parity: "
            f"max_abs={max_absolute_difference:.10g}, "
            f"min_cosine={minimum_cosine_similarity:.10g}"
        )
        np.testing.assert_allclose(
            np.linalg.norm(actual, axis=1),
            np.ones(3, dtype=np.float32),
            rtol=1e-5,
            atol=1e-6,
        )
        np.testing.assert_allclose(actual, expected, rtol=1e-4, atol=1e-5)
        assert max_absolute_difference <= 1e-5
        assert minimum_cosine_similarity >= 0.99999
    finally:
        output_path.unlink(missing_ok=True)
        output_path.parent.rmdir()


def test_final_export_rejects_a_checkpoint_hash_mismatch(tmp_path: Path) -> None:
    checkpoint_path = tmp_path / "synthetic-checkpoint.bin"
    checkpoint_path.write_bytes(b"synthetic checkpoint hash fixture")
    with pytest.raises(ValueError, match="checkpoint SHA-256 mismatch"):
        export_and_verify_final_model(
            checkpoint_path=checkpoint_path,
            expected_checkpoint_sha256="0" * 64,
            aligned_root="unused",
            validation_manifest="unused",
            output_path="unused.onnx",
            report_path="unused.json",
            locked_threshold=0.5,
        )
