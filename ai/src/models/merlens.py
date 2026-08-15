"""Project-authored MerLens V2 facial-embedding architecture.

MerLens is assembled from standard convolution, depthwise convolution,
residual, channel-gating, pooling, and normalization operations. The source and
exact topology are project-authored; those established building blocks are not
claimed as new research inventions.
"""

from __future__ import annotations

from dataclasses import dataclass

import torch
from torch import Tensor, nn
from torch.nn import functional as F


class ConvNormAct(nn.Sequential):
    """Convolution followed by batch normalization and PReLU."""

    def __init__(
        self,
        in_channels: int,
        out_channels: int,
        *,
        kernel_size: int,
        stride: int = 1,
        groups: int = 1,
    ) -> None:
        padding = kernel_size // 2
        super().__init__(
            nn.Conv2d(
                in_channels,
                out_channels,
                kernel_size,
                stride=stride,
                padding=padding,
                groups=groups,
                bias=False,
            ),
            nn.BatchNorm2d(out_channels),
            nn.PReLU(out_channels),
        )


class MerLensChannelGate(nn.Module):
    """Apply lightweight learned channel reweighting to one feature map."""

    def __init__(self, channels: int, reduction: int = 4) -> None:
        super().__init__()
        hidden_channels = max(8, channels // reduction)
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.reduce = nn.Conv2d(channels, hidden_channels, 1)
        self.expand = nn.Conv2d(hidden_channels, channels, 1)

    def forward(self, inputs: Tensor) -> Tensor:
        weights = self.pool(inputs)
        weights = F.relu(self.reduce(weights), inplace=True)
        weights = F.hardsigmoid(self.expand(weights), inplace=True)
        return inputs * weights


class MerLensContextBlock(nn.Module):
    """Fuse local and wider depthwise context before a residual projection."""

    def __init__(
        self,
        in_channels: int,
        out_channels: int,
        *,
        expanded_channels: int,
        stride: int,
    ) -> None:
        super().__init__()
        if expanded_channels % 2:
            raise ValueError("expanded_channels must be even")
        if stride not in (1, 2):
            raise ValueError("stride must be one or two")

        branch_channels = expanded_channels // 2
        self.expand = ConvNormAct(
            in_channels,
            expanded_channels,
            kernel_size=1,
        )
        self.local_context = ConvNormAct(
            branch_channels,
            branch_channels,
            kernel_size=3,
            stride=stride,
            groups=branch_channels,
        )
        self.wide_context = ConvNormAct(
            branch_channels,
            branch_channels,
            kernel_size=5,
            stride=stride,
            groups=branch_channels,
        )
        self.channel_gate = MerLensChannelGate(expanded_channels)
        self.project = nn.Sequential(
            nn.Conv2d(expanded_channels, out_channels, 1, bias=False),
            nn.BatchNorm2d(out_channels),
        )
        self.use_residual = stride == 1 and in_channels == out_channels
        self.output_activation = nn.PReLU(out_channels)

    def forward(self, inputs: Tensor) -> Tensor:
        expanded = self.expand(inputs)
        local, wide = torch.chunk(expanded, chunks=2, dim=1)
        fused = torch.cat(
            (self.local_context(local), self.wide_context(wide)),
            dim=1,
        )
        outputs = self.project(self.channel_gate(fused))
        if self.use_residual:
            outputs = outputs + inputs
        return self.output_activation(outputs)


@dataclass(frozen=True)
class MerLensStage:
    """One declarative MerLens feature stage."""

    out_channels: int
    expanded_channels: int
    repeats: int
    first_stride: int


MERLENS_V2_STAGES = (
    MerLensStage(32, 64, 1, 1),
    MerLensStage(48, 96, 2, 2),
    MerLensStage(72, 144, 2, 2),
    MerLensStage(112, 224, 3, 2),
    MerLensStage(160, 320, 2, 2),
)


class MerLensV2FaceEmbedding(nn.Module):
    """Return one 128-D unit-normalized MerLens embedding per aligned face."""

    architecture_name = "merlens_v2_face_embedding"

    def __init__(self, embedding_dimension: int = 128) -> None:
        super().__init__()
        if embedding_dimension <= 0:
            raise ValueError("embedding_dimension must be positive")

        layers: list[nn.Module] = [ConvNormAct(3, 32, kernel_size=3, stride=2)]
        in_channels = 32
        for stage in MERLENS_V2_STAGES:
            for repeat in range(stage.repeats):
                stride = stage.first_stride if repeat == 0 else 1
                layers.append(
                    MerLensContextBlock(
                        in_channels,
                        stage.out_channels,
                        expanded_channels=stage.expanded_channels,
                        stride=stride,
                    )
                )
                in_channels = stage.out_channels
        layers.append(ConvNormAct(in_channels, 256, kernel_size=1))

        self.features = nn.Sequential(*layers)
        self.pool = nn.AdaptiveAvgPool2d(1)
        self.embedding_dropout = nn.Dropout(p=0.1)
        self.embedding_projection = nn.Linear(
            256,
            embedding_dimension,
            bias=False,
        )
        self.embedding_batch_norm = nn.BatchNorm1d(embedding_dimension)
        self.embedding_dimension = embedding_dimension
        self.reset_parameters()

    def reset_parameters(self) -> None:
        """Initialize all trainable tensors locally without pretrained weights."""

        for module in self.modules():
            if isinstance(module, nn.Conv2d):
                nn.init.kaiming_normal_(
                    module.weight,
                    mode="fan_out",
                    nonlinearity="relu",
                )
                if module.bias is not None:
                    nn.init.zeros_(module.bias)
            elif isinstance(module, (nn.BatchNorm1d, nn.BatchNorm2d)):
                nn.init.ones_(module.weight)
                nn.init.zeros_(module.bias)
            elif isinstance(module, nn.Linear):
                nn.init.xavier_uniform_(module.weight)
                if module.bias is not None:
                    nn.init.zeros_(module.bias)
            elif isinstance(module, nn.PReLU):
                nn.init.constant_(module.weight, 0.25)

    def forward(self, inputs: Tensor) -> Tensor:
        features = self.features(inputs)
        pooled = torch.flatten(self.pool(features), 1)
        projected = self.embedding_projection(self.embedding_dropout(pooled))
        normalized_projection = self.embedding_batch_norm(projected)
        return F.normalize(normalized_projection, p=2, dim=1)
