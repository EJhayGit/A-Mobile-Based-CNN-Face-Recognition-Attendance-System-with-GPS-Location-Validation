"""Factory for the final MerLens V2 embedding architecture."""

from __future__ import annotations

from .merlens import MerLensV2FaceEmbedding


def build_merlens_model(*, embedding_dimension: int = 128) -> MerLensV2FaceEmbedding:
    """Build MerLens V2 with locally initialized trainable parameters."""

    return MerLensV2FaceEmbedding(embedding_dimension=embedding_dimension)
