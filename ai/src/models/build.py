"""Factory for the active MerLens V2 facial-embedding model."""

from __future__ import annotations

from .merlens import MerLensV2FaceEmbedding


def build_merlens_model(*, embedding_dimension: int = 128) -> MerLensV2FaceEmbedding:
    """Build random-initialized MerLens V2 without loading a checkpoint."""

    return MerLensV2FaceEmbedding(embedding_dimension=embedding_dimension)
