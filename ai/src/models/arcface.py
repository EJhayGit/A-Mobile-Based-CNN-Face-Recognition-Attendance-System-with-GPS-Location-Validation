"""ArcFace training-head wrapper for the frozen dependency implementation."""

from __future__ import annotations

from pytorch_metric_learning.losses import ArcFaceLoss
from torch import Tensor, nn


class ArcFaceTrainingHead(nn.Module):
    """Expose ArcFace logits, loss, and trainable class centers.

    The wrapped class centers are training-only parameters and are not part of
    the facial-embedding inference/export model.
    """

    def __init__(
        self,
        num_classes: int,
        embedding_dimension: int = 128,
        margin_degrees: float = 28.6,
        scale: float = 64.0,
    ) -> None:
        super().__init__()
        if num_classes <= 1:
            raise ValueError("num_classes must be greater than one")
        if embedding_dimension <= 0:
            raise ValueError("embedding_dimension must be positive")

        self.loss_module = ArcFaceLoss(
            num_classes=num_classes,
            embedding_size=embedding_dimension,
            margin=margin_degrees,
            scale=scale,
        )
        self.num_classes = num_classes
        self.embedding_dimension = embedding_dimension

    @property
    def class_centers(self) -> nn.Parameter:
        return self.loss_module.W

    def logits(self, embeddings: Tensor) -> Tensor:
        return self.loss_module.get_logits(embeddings)

    def forward(self, embeddings: Tensor, labels: Tensor) -> Tensor:
        return self.loss_module(embeddings, labels)
