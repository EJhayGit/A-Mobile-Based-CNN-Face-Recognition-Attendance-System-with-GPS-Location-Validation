"""Stage-aware MerLens V2 curriculum training and transition mechanics."""

from __future__ import annotations

import csv
import json
import os
import random
import subprocess
import time
from dataclasses import asdict, dataclass
from hashlib import sha256
from pathlib import Path
from typing import Any, Literal, Sequence

import numpy as np
import torch
import yaml
from torch.utils.data import DataLoader, WeightedRandomSampler

from ai.src.datasets.aligned import AlignedFaceDataset
from ai.src.datasets.digiface import DatasetIntegrityError
from ai.src.datasets.manifest import sha256_file
from ai.src.evaluation import calibrate_threshold, generate_verification_pairs, pair_scores
from ai.src.models import ArcFaceTrainingHead, build_merlens_model

CURRICULUM_STAGES = (256, 2_048, 8_192, 32_768, 92_329)
RUN_NAME = "merlens-v2-curriculum"
APPROVAL_TOKEN = "MERLENS_CURRICULUM_APPROVED"
STATE_SCHEMA_VERSION = 1
# Monitoring-only denominator requested for the console. It does not change
# the configured scheduler or any training/advancement behavior.
MONITOR_EPOCH_DISPLAY_MAX = 20
PROGRESS_INTERVAL_BATCHES = 25


@dataclass(frozen=True)
class CurriculumConfig:
    seed: int
    batch_size: int
    model_learning_rate: float
    center_learning_rate: float
    weight_decay: float
    gradient_clip_norm: float
    maximum_epochs_per_stage: int
    minimum_epochs_before_advance: int
    maximum_genuine_pairs_per_identity: int


@dataclass(frozen=True)
class HealthEvidence:
    verdict: Literal["HEALTHY", "FAILED"]
    ready_to_advance: bool
    reasons: tuple[str, ...]
    effective_rank: float
    first_pc_variance: float
    genuine_mean: float
    impostor_mean: float
    separation: float
    validation_accuracy: float
    validation_eer: float
    validation_threshold: float
    finite_gradients: bool
    training_target_top1: float
    training_median_target_rank: float


@dataclass(frozen=True)
class CurriculumPreflight:
    curriculum_valid: bool
    ready_for_training: bool
    cuda_available: bool
    cuda_device_name: str | None
    stage: int
    identity_count: int
    train_image_count: int
    full_train_identity_count: int
    validation_identity_count: int
    identity_manifest_sha256: str
    train_validation_disjoint: bool
    held_out_sealed: bool
    continuation_available: bool
    worktree_clean: bool
    issues: tuple[str, ...]


def _set_determinism(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.use_deterministic_algorithms(True, warn_only=True)


def _identity_balanced_weights(dataset: AlignedFaceDataset) -> torch.Tensor:
    counts: dict[str, int] = {}
    for record in dataset.records:
        counts[record.identity] = counts.get(record.identity, 0) + 1
    return torch.tensor(
        [1.0 / counts[record.identity] for record in dataset.records],
        dtype=torch.float64,
    )


def _numpy_random_state() -> dict[str, object]:
    algorithm, state, position, has_gauss, cached_gaussian = np.random.get_state()
    return {
        "algorithm": algorithm,
        "state": state.tolist(),
        "position": position,
        "has_gauss": has_gauss,
        "cached_gaussian": cached_gaussian,
    }


def _capture_random_state(generator: torch.Generator) -> dict[str, object]:
    return {
        "python": random.getstate(),
        "numpy": _numpy_random_state(),
        "torch_cpu": torch.random.get_rng_state(),
        "torch_cuda": torch.cuda.get_rng_state_all() if torch.cuda.is_available() else [],
        "loader_generator": generator.get_state(),
    }


def _cpu_rng_state(value: object) -> torch.Tensor:
    if not isinstance(value, torch.Tensor) or value.dtype != torch.uint8 or value.ndim != 1:
        raise TypeError("RNG state must be a one-dimensional byte tensor")
    return value.detach().cpu()


def _restore_random_state(state: dict[str, object], generator: torch.Generator) -> None:
    try:
        numpy_state = state["numpy"]
        if not isinstance(numpy_state, dict):
            raise TypeError
        restored_numpy = (
            str(numpy_state["algorithm"]),
            np.asarray(numpy_state["state"], dtype=np.uint32),
            int(numpy_state["position"]),
            int(numpy_state["has_gauss"]),
            float(numpy_state["cached_gaussian"]),
        )
        cuda_states = state["torch_cuda"]
        restored_cuda: list[torch.Tensor] = []
        if torch.cuda.is_available():
            if not isinstance(cuda_states, list) or len(cuda_states) != torch.cuda.device_count():
                raise DatasetIntegrityError("resume CUDA random state is incompatible")
            restored_cuda = [_cpu_rng_state(item) for item in cuda_states]
        random.setstate(state["python"])
        np.random.set_state(restored_numpy)
        torch.random.set_rng_state(_cpu_rng_state(state["torch_cpu"]))
        if restored_cuda:
            torch.cuda.set_rng_state_all(restored_cuda)
        generator.set_state(_cpu_rng_state(state["loader_generator"]))
    except (KeyError, TypeError, ValueError, RuntimeError) as error:
        raise DatasetIntegrityError("resume random state is invalid") from error


def _atomic_torch_save(payload: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".part")
    torch.save(payload, partial)
    os.replace(partial, path)


def _atomic_json_write(payload: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".part")
    partial.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(partial, path)


def _duration_text(seconds: float) -> str:
    value = max(0, int(round(seconds)))
    hours, remainder = divmod(value, 3600)
    minutes, seconds_value = divmod(remainder, 60)
    if hours:
        return f"{hours:d}h {minutes:02d}m"
    return f"{minutes:d}m {seconds_value:02d}s"


def format_live_summary(
    *,
    stage: int,
    epoch: int,
    minimum_epoch: int,
    batch: int,
    total_batches: int,
    samples: int,
    elapsed_seconds: float,
    loss: float,
    latest: dict[str, Any] | None,
) -> str:
    """Return a compact monitoring-only summary for one training batch."""

    rate = samples / max(elapsed_seconds, 1e-9)
    estimated_training_seconds = elapsed_seconds / batch * total_batches
    epoch_eta = max(0.0, estimated_training_seconds - elapsed_seconds)
    previous_epoch_seconds = (
        float(latest["elapsed_seconds"])
        if latest is not None and "elapsed_seconds" in latest
        else estimated_training_seconds
    )
    full_epochs_to_minimum = max(0, minimum_epoch - epoch)
    minimum_eta = epoch_eta + full_epochs_to_minimum * previous_epoch_seconds
    if latest is None:
        validation = "Val acc n/a | EER n/a | rank n/a | PC1 n/a | health Pending | ready false"
    else:
        validation = (
            f"Val acc {float(latest['validation_accuracy']):.4f} | "
            f"EER {float(latest['validation_eer']):.4f} | "
            f"rank {float(latest['effective_rank']):.3f} | "
            f"PC1 {float(latest['first_pc_variance']) * 100:.2f}% | "
            f"health {latest['health']} | "
            f"ready {str(bool(latest['ready_to_advance'])).lower()}"
        )
    return (
        f"Stage {stage}/{len(CURRICULUM_STAGES)} | "
        f"Epoch {epoch}/{MONITOR_EPOCH_DISPLAY_MAX} | min {minimum_epoch} | "
        f"Batch {batch}/{total_batches} | {rate:.1f} img/s\n"
        f"ETA epoch {_duration_text(epoch_eta)} | "
        f"ETA min-{minimum_epoch} {_duration_text(minimum_eta)} | "
        f"loss {loss:.5f}\n"
        f"{validation}"
    )


def format_validation_summary(record: dict[str, Any]) -> str:
    """Return the compact post-validation summary for a completed epoch."""

    return (
        f"Stage {int(record['stage'])}/{len(CURRICULUM_STAGES)} | "
        f"Epoch {int(record['epoch'])}/{MONITOR_EPOCH_DISPLAY_MAX} complete | "
        f"min 12 | {float(record['images_per_second']):.1f} img/s | "
        f"elapsed {_duration_text(float(record['elapsed_seconds']))}\n"
        f"loss {float(record['training_loss']):.5f} | "
        f"Val acc {float(record['validation_accuracy']):.4f} | "
        f"EER {float(record['validation_eer']):.4f} | "
        f"rank {float(record['effective_rank']):.3f} | "
        f"PC1 {float(record['first_pc_variance']) * 100:.2f}% | "
        f"health {record['health']} | "
        f"ready {str(bool(record['ready_to_advance'])).lower()}"
    )


def repository_root() -> Path:
    return Path(__file__).resolve().parents[3]


def load_curriculum_configuration(root: Path | None = None) -> tuple[dict[str, Any], CurriculumConfig]:
    root = repository_root() if root is None else root
    payload = yaml.safe_load(
        (root / "ai/configs/merlens_curriculum.yaml").read_text(encoding="utf-8")
    )
    training = payload["training"]
    return payload, CurriculumConfig(
        seed=int(training["seed"]),
        batch_size=int(training["batch_size"]),
        model_learning_rate=float(training["model_learning_rate"]),
        center_learning_rate=float(training["center_learning_rate"]),
        weight_decay=float(training["weight_decay"]),
        gradient_clip_norm=float(training["gradient_clip_norm"]),
        maximum_epochs_per_stage=int(training["maximum_epochs_per_stage"]),
        minimum_epochs_before_advance=int(training["minimum_epochs_before_advance"]),
        maximum_genuine_pairs_per_identity=int(
            training["maximum_genuine_pairs_per_identity"]
        ),
    )


def preprocessing_identity_mapping(manifest: str | Path) -> tuple[str, ...]:
    """Return the frozen sorted usable identity mapping without opening images."""

    counts: dict[str, int] = {}
    with Path(manifest).open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        required = {"partition", "identity", "status"}
        if not required.issubset(reader.fieldnames or ()):
            raise DatasetIntegrityError("preprocessing manifest fields do not match")
        for row in reader:
            if row["status"] == "accepted":
                counts[row["identity"]] = counts.get(row["identity"], 0) + 1
    identities = tuple(sorted(identity for identity, count in counts.items() if count >= 2))
    if len(identities) < 2:
        raise DatasetIntegrityError("preprocessing manifest has too few usable identities")
    return identities


def nested_stage_identities(
    full_mapping: Sequence[str], identity_count: int
) -> tuple[str, ...]:
    if identity_count not in CURRICULUM_STAGES and identity_count not in (16, 32):
        raise ValueError("unsupported curriculum identity count")
    if len(full_mapping) < identity_count:
        raise DatasetIntegrityError("training mapping is smaller than the stage")
    selected = tuple(full_mapping[:identity_count])
    if len(set(selected)) != identity_count or selected != tuple(sorted(selected)):
        raise DatasetIntegrityError("training identity mapping is not stable and sorted")
    return selected


def identity_manifest_sha256(identities: Sequence[str]) -> str:
    return sha256(("\n".join(identities) + "\n").encode("utf-8")).hexdigest()


def _head_with_seed(num_classes: int, seed: int, device: torch.device) -> ArcFaceTrainingHead:
    devices = [device.index or 0] if device.type == "cuda" else []
    with torch.random.fork_rng(devices=devices):
        torch.manual_seed(seed)
        if device.type == "cuda":
            torch.cuda.manual_seed_all(seed)
        return ArcFaceTrainingHead(num_classes=num_classes).to(device)


def expand_arcface_head(
    previous: ArcFaceTrainingHead,
    new_class_count: int,
    *,
    seed: int,
) -> ArcFaceTrainingHead:
    """Preserve old center columns and initialize only new columns."""

    old_count = previous.num_classes
    if new_class_count <= old_count:
        raise ValueError("new class count must exceed the old class count")
    device = previous.class_centers.device
    expanded = _head_with_seed(new_class_count, seed, device)
    with torch.no_grad():
        expanded.class_centers[:, :old_count].copy_(previous.class_centers)
    if not torch.equal(
        expanded.class_centers[:, :old_count], previous.class_centers
    ):
        raise RuntimeError("old ArcFace centers changed during expansion")
    return expanded


def build_optimizer(
    model: torch.nn.Module,
    head: ArcFaceTrainingHead,
    config: CurriculumConfig,
) -> torch.optim.AdamW:
    return torch.optim.AdamW(
        [
            {"params": model.parameters(), "lr": config.model_learning_rate},
            {"params": head.parameters(), "lr": config.center_learning_rate},
        ],
        weight_decay=config.weight_decay,
    )


def build_scheduler(
    optimizer: torch.optim.Optimizer, config: CurriculumConfig
) -> torch.optim.lr_scheduler.CosineAnnealingLR:
    return torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=config.maximum_epochs_per_stage, eta_min=1e-6
    )


def verify_expansion(
    model: torch.nn.Module,
    old_head: ArcFaceTrainingHead,
    new_head: ArcFaceTrainingHead,
    fixed_inputs: torch.Tensor,
) -> None:
    before_state = {key: value.detach().clone() for key, value in model.state_dict().items()}
    was_training = model.training
    model.eval()
    with torch.inference_mode():
        before_embeddings = model(fixed_inputs).detach().clone()
        after_embeddings = model(fixed_inputs).detach().clone()
    model.train(was_training)
    if any(not torch.equal(before_state[key], value) for key, value in model.state_dict().items()):
        raise RuntimeError("model or BN state changed during classifier expansion")
    if not torch.equal(old_head.class_centers, new_head.class_centers[:, : old_head.num_classes]):
        raise RuntimeError("old ArcFace centers changed during classifier expansion")
    if not torch.equal(before_embeddings, after_embeddings):
        raise RuntimeError("fixed embeddings changed during classifier expansion")


def representation_statistics(embeddings: np.ndarray) -> tuple[float, float]:
    values = np.asarray(embeddings, dtype=np.float64)
    if values.ndim != 2 or len(values) < 2 or not np.isfinite(values).all():
        raise ValueError("representation matrix is invalid")
    singular = np.linalg.svd(values - values.mean(axis=0), compute_uv=False)
    variance = singular**2
    total = float(variance.sum())
    if total <= 0.0:
        return 1.0, 1.0
    probabilities = variance[variance > 0.0] / total
    effective_rank = float(np.exp(-np.sum(probabilities * np.log(probabilities))))
    return effective_rank, float(probabilities[0])


def classify_health(
    *,
    effective_rank: float,
    first_pc_variance: float,
    genuine_mean: float,
    impostor_mean: float,
    validation_accuracy: float,
    validation_eer: float,
    validation_threshold: float,
    finite_gradients: bool,
    training_target_top1: float,
    training_median_target_rank: float,
    completed_stage_epochs: int,
    minimum_epochs_before_advance: int,
) -> HealthEvidence:
    separation = genuine_mean - impostor_mean
    reasons: list[str] = []
    if not finite_gradients:
        reasons.append("non_finite_gradients")
    if effective_rank < 1.5:
        reasons.append("effective_rank_collapse")
    if first_pc_variance > 0.98:
        reasons.append("first_pc_dominance")
    if (
        separation < 0.005
        and validation_eer > 0.47
        and validation_accuracy < 0.53
        and (effective_rank < 2.0 or first_pc_variance > 0.95)
    ):
        reasons.append("verification_separation_collapse")
    verdict: Literal["HEALTHY", "FAILED"] = "FAILED" if reasons else "HEALTHY"
    return HealthEvidence(
        verdict=verdict,
        ready_to_advance=(
            verdict == "HEALTHY"
            and completed_stage_epochs >= minimum_epochs_before_advance
        ),
        reasons=tuple(reasons),
        effective_rank=effective_rank,
        first_pc_variance=first_pc_variance,
        genuine_mean=genuine_mean,
        impostor_mean=impostor_mean,
        separation=separation,
        validation_accuracy=validation_accuracy,
        validation_eer=validation_eer,
        validation_threshold=validation_threshold,
        finite_gradients=finite_gradients,
        training_target_top1=training_target_top1,
        training_median_target_rank=training_median_target_rank,
    )


def _git_text(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True
    ).stdout.strip()


def curriculum_paths(root: Path) -> tuple[Path, Path, Path]:
    return (
        root / "ai/checkpoints/runs/merlens-v2-curriculum/last_state.pt",
        root / "ai/outputs/runs/merlens-v2-curriculum/training_status.json",
        root / "ai/outputs/runs/merlens-v2-curriculum/mechanics_status.json",
    )


def inspect_preflight(root: Path | None = None) -> CurriculumPreflight:
    root = repository_root() if root is None else root
    payload, _ = load_curriculum_configuration(root)
    data = payload["data"]
    train_manifest = root / data["train_manifest"]
    validation_manifest = root / data["validation_manifest"]
    state_path, _, _ = curriculum_paths(root)
    issues: list[str] = []
    train_mapping: tuple[str, ...] = ()
    validation_mapping: tuple[str, ...] = ()
    train_image_count = 0
    if not train_manifest.is_file() or not validation_manifest.is_file():
        issues.append("training or validation manifest is missing")
    else:
        if sha256_file(train_manifest) != data["train_manifest_sha256"]:
            issues.append("training manifest hash mismatch")
        if sha256_file(validation_manifest) != data["validation_manifest_sha256"]:
            issues.append("validation manifest hash mismatch")
        train_mapping = preprocessing_identity_mapping(train_manifest)
        validation_mapping = preprocessing_identity_mapping(validation_manifest)
        stage_identity_set = set(train_mapping[: CURRICULUM_STAGES[0]])
        with train_manifest.open(newline="", encoding="utf-8") as stream:
            train_image_count = sum(
                1
                for row in csv.DictReader(stream)
                if row["status"] == "accepted"
                and row["identity"] in stage_identity_set
            )
        if len(train_mapping) != CURRICULUM_STAGES[-1]:
            issues.append("full usable training identity count is not 92,329")
        if set(train_mapping) & set(validation_mapping):
            issues.append("training and validation identities overlap")
    dirty = bool(_git_text(root, "status", "--porcelain=v1", "-uall"))
    if dirty:
        issues.append("worktree is not clean")
    cuda = torch.cuda.is_available()
    if not cuda:
        issues.append("CUDA is unavailable")
    selected = nested_stage_identities(train_mapping, 256) if len(train_mapping) >= 256 else ()
    return CurriculumPreflight(
        curriculum_valid=not any(
            issue for issue in issues if issue not in ("worktree is not clean", "CUDA is unavailable")
        ),
        ready_for_training=not issues,
        cuda_available=cuda,
        cuda_device_name=torch.cuda.get_device_name(0) if cuda else None,
        stage=1,
        identity_count=len(selected),
        train_image_count=train_image_count,
        full_train_identity_count=len(train_mapping),
        validation_identity_count=len(validation_mapping),
        identity_manifest_sha256=identity_manifest_sha256(selected) if selected else "",
        train_validation_disjoint=not bool(set(train_mapping) & set(validation_mapping)),
        held_out_sealed=True,
        continuation_available=state_path.is_file(),
        worktree_clean=not dirty,
        issues=tuple(issues),
    )


@torch.inference_mode()
def _validation_evidence(
    model: torch.nn.Module,
    dataset: AlignedFaceDataset,
    *,
    device: torch.device,
    batch_size: int,
    seed: int,
    maximum_pairs: int,
) -> tuple[Any, np.ndarray, float, float, float, float]:
    model.eval()
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=0, pin_memory=True)
    batches = [model(inputs.to(device, non_blocking=True)).cpu().numpy() for inputs, _ in loader]
    embeddings = np.concatenate(batches)
    pairs = generate_verification_pairs(
        dataset.records,
        seed=seed,
        maximum_genuine_pairs_per_identity=maximum_pairs,
    )
    scores, labels = pair_scores(embeddings, pairs)
    metrics = calibrate_threshold(scores, labels)
    genuine_mean = float(scores[labels].mean())
    impostor_mean = float(scores[~labels].mean())
    rank, pc1 = representation_statistics(embeddings)
    return metrics, embeddings, genuine_mean, impostor_mean, rank, pc1


def _save_state(
    *,
    path: Path,
    model: torch.nn.Module,
    head: ArcFaceTrainingHead,
    optimizer: torch.optim.Optimizer,
    scheduler: torch.optim.lr_scheduler.LRScheduler,
    generator: torch.Generator,
    config: CurriculumConfig,
    stage_index: int,
    stage_identities: tuple[str, ...],
    completed_epoch: int,
    history: list[dict[str, Any]],
    health: HealthEvidence,
    transition: dict[str, Any],
) -> None:
    _atomic_torch_save(
        {
            "schema_version": STATE_SCHEMA_VERSION,
            "run_name": RUN_NAME,
            "stage_index": stage_index,
            "identity_count": len(stage_identities),
            "identity_manifest_sha256": identity_manifest_sha256(stage_identities),
            "stage_identities": stage_identities,
            "completed_epoch": completed_epoch,
            "next_epoch": completed_epoch + 1,
            "model_state_dict": model.state_dict(),
            "arcface_state_dict": head.state_dict(),
            "optimizer_state_dict": optimizer.state_dict(),
            "scheduler_state_dict": scheduler.state_dict(),
            "random_state": _capture_random_state(generator),
            "history": history,
            "health": asdict(health),
            "transition": transition,
            "training_config": asdict(config),
        },
        path,
    )


def load_state(
    path: Path,
    *,
    device: torch.device,
    config: CurriculumConfig,
    generator: torch.Generator,
) -> tuple[torch.nn.Module, ArcFaceTrainingHead, torch.optim.Optimizer, Any, dict[str, Any]]:
    payload = torch.load(path, map_location=device, weights_only=True)
    if payload.get("schema_version") != STATE_SCHEMA_VERSION or payload.get("run_name") != RUN_NAME:
        raise DatasetIntegrityError("unsupported curriculum state")
    stage_index = int(payload["stage_index"])
    identity_count = CURRICULUM_STAGES[stage_index]
    if payload["identity_count"] != identity_count:
        raise DatasetIntegrityError("curriculum stage identity count mismatch")
    model = build_merlens_model().to(device)
    head = ArcFaceTrainingHead(identity_count).to(device)
    model.load_state_dict(payload["model_state_dict"], strict=True)
    head.load_state_dict(payload["arcface_state_dict"], strict=True)
    optimizer = build_optimizer(model, head, config)
    scheduler = build_scheduler(optimizer, config)
    optimizer.load_state_dict(payload["optimizer_state_dict"])
    scheduler.load_state_dict(payload["scheduler_state_dict"])
    _restore_random_state(payload["random_state"], generator)
    return model, head, optimizer, scheduler, payload


def run_one_epoch(*, approval_token: str, root: Path | None = None) -> dict[str, Any]:
    if approval_token != APPROVAL_TOKEN:
        raise PermissionError("curriculum training approval token is invalid")
    root = repository_root() if root is None else root
    preflight = inspect_preflight(root)
    if not preflight.ready_for_training:
        raise RuntimeError("curriculum preflight failed: " + "; ".join(preflight.issues))
    payload, config = load_curriculum_configuration(root)
    data = payload["data"]
    train_manifest = root / data["train_manifest"]
    validation_manifest = root / data["validation_manifest"]
    aligned_root = root / data["aligned_root"]
    state_path, status_path, _ = curriculum_paths(root)
    _set_determinism(config.seed)
    device = torch.device("cuda")
    generator = torch.Generator().manual_seed(config.seed)
    full_mapping = preprocessing_identity_mapping(train_manifest)
    stage_index = 0
    stage_identities = nested_stage_identities(full_mapping, CURRICULUM_STAGES[stage_index])
    history: list[dict[str, Any]] = []
    transition = {"optimizer": "initial_clean_state", "verified": True}
    if state_path.is_file():
        model, head, optimizer, scheduler, restored = load_state(
            state_path, device=device, config=config, generator=generator
        )
        stage_index = int(restored["stage_index"])
        stage_identities = tuple(restored["stage_identities"])
        history = list(restored["history"])
        completed_epoch = int(restored["completed_epoch"])
        if restored["health"]["verdict"] == "FAILED":
            raise RuntimeError("curriculum is stopped by failed structural health")
        if restored["health"]["ready_to_advance"]:
            if stage_index + 1 >= len(CURRICULUM_STAGES):
                raise RuntimeError("curriculum final stage is complete")
            old_count = len(stage_identities)
            fixed_dataset = AlignedFaceDataset(
                aligned_root,
                train_manifest,
                partition="train",
                training=False,
                maximum_identities=old_count,
            )
            fixed_inputs = torch.stack(
                [fixed_dataset[index][0] for index in range(min(4, len(fixed_dataset)))]
            ).to(device)
            model_before = {
                key: value.detach().clone() for key, value in model.state_dict().items()
            }
            with torch.inference_mode():
                model.eval()
                embeddings_before = model(fixed_inputs).detach().clone()
            next_count = CURRICULUM_STAGES[stage_index + 1]
            expanded = expand_arcface_head(
                head, next_count, seed=config.seed + next_count
            )
            verify_expansion(model, head, expanded, fixed_inputs)
            with torch.inference_mode():
                model.eval()
                embeddings_after = model(fixed_inputs).detach().clone()
            if any(
                not torch.equal(model_before[key], value)
                for key, value in model.state_dict().items()
            ):
                raise RuntimeError("model state changed during stage transition")
            if not torch.equal(embeddings_before, embeddings_after):
                raise RuntimeError("old-stage embeddings changed during transition")
            head = expanded
            optimizer = build_optimizer(model, head, config)
            scheduler = build_scheduler(optimizer, config)
            stage_index += 1
            stage_identities = nested_stage_identities(full_mapping, next_count)
            completed_epoch = 0
            transition = {
                "from_identity_count": old_count,
                "to_identity_count": next_count,
                "model_preserved": True,
                "old_centers_preserved": True,
                "fixed_old_embeddings_preserved": True,
                "optimizer": "rebuilt_clean_for_expanded_classifier",
                "scheduler": "reset_for_new_stage",
            }
    else:
        model = build_merlens_model().to(device)
        head = _head_with_seed(len(stage_identities), config.seed, device)
        optimizer = build_optimizer(model, head, config)
        scheduler = build_scheduler(optimizer, config)
        completed_epoch = 0
    train_dataset = AlignedFaceDataset(
        aligned_root,
        train_manifest,
        partition="train",
        training=True,
        maximum_identities=len(stage_identities),
    )
    validation_dataset = AlignedFaceDataset(
        aligned_root,
        validation_manifest,
        partition="validation",
        training=False,
    )
    sampler = WeightedRandomSampler(
        _identity_balanced_weights(train_dataset),
        num_samples=len(train_dataset),
        replacement=True,
        generator=generator,
    )
    loader = DataLoader(
        train_dataset,
        batch_size=config.batch_size,
        sampler=sampler,
        num_workers=0,
        pin_memory=True,
        drop_last=True,
        generator=generator,
    )
    epoch = completed_epoch + 1
    started = time.perf_counter()
    model.train()
    head.train()
    loss_sum = 0.0
    samples = 0
    target_ranks: list[np.ndarray] = []
    target_top1 = 0
    clipped_batches = 0
    finite_gradients = True
    for batch_index, (inputs, labels) in enumerate(loader, start=1):
        inputs = inputs.to(device, non_blocking=True)
        labels = labels.to(device, non_blocking=True)
        optimizer.zero_grad(set_to_none=True)
        embeddings = model(inputs)
        logits = head.logits(embeddings)
        targets = logits.gather(1, labels[:, None])
        ranks = 1 + (logits > targets).sum(dim=1)
        target_ranks.append(ranks.detach().cpu().numpy())
        target_top1 += int((ranks == 1).sum())
        loss = head(embeddings, labels)
        if not torch.isfinite(loss):
            raise FloatingPointError("curriculum loss became non-finite")
        loss.backward()
        gradients = [parameter.grad for parameter in [*model.parameters(), *head.parameters()] if parameter.grad is not None]
        finite_gradients = finite_gradients and bool(gradients) and all(torch.isfinite(item).all() for item in gradients)
        if not finite_gradients:
            raise FloatingPointError("curriculum gradient became non-finite")
        norm = torch.nn.utils.clip_grad_norm_(
            [*model.parameters(), *head.parameters()], config.gradient_clip_norm
        )
        clipped_batches += int(float(norm) > config.gradient_clip_norm)
        optimizer.step()
        count = labels.shape[0]
        loss_sum += float(loss.detach()) * count
        samples += count
        if (
            batch_index % PROGRESS_INTERVAL_BATCHES == 0
            or batch_index == len(loader)
        ):
            print(
                format_live_summary(
                    stage=stage_index + 1,
                    epoch=epoch,
                    minimum_epoch=config.minimum_epochs_before_advance,
                    batch=batch_index,
                    total_batches=len(loader),
                    samples=samples,
                    elapsed_seconds=time.perf_counter() - started,
                    loss=loss_sum / samples,
                    latest=history[-1] if history else None,
                ),
                flush=True,
            )
    scheduler.step()
    metrics, _, genuine_mean, impostor_mean, rank, pc1 = _validation_evidence(
        model,
        validation_dataset,
        device=device,
        batch_size=config.batch_size,
        seed=config.seed,
        maximum_pairs=config.maximum_genuine_pairs_per_identity,
    )
    ranks_array = np.concatenate(target_ranks)
    health = classify_health(
        effective_rank=rank,
        first_pc_variance=pc1,
        genuine_mean=genuine_mean,
        impostor_mean=impostor_mean,
        validation_accuracy=metrics.accuracy,
        validation_eer=float(metrics.equal_error_rate),
        validation_threshold=metrics.threshold,
        finite_gradients=finite_gradients,
        training_target_top1=target_top1 / samples,
        training_median_target_rank=float(np.median(ranks_array)),
        completed_stage_epochs=epoch,
        minimum_epochs_before_advance=config.minimum_epochs_before_advance,
    )
    elapsed = time.perf_counter() - started
    record = {
        "stage": stage_index + 1,
        "identity_count": len(stage_identities),
        "epoch": epoch,
        "training_images": samples,
        "elapsed_seconds": elapsed,
        "images_per_second": samples / elapsed,
        "training_loss": loss_sum / samples,
        "training_target_top1": health.training_target_top1,
        "training_median_target_rank": health.training_median_target_rank,
        "validation_accuracy": health.validation_accuracy,
        "validation_eer": health.validation_eer,
        "validation_threshold": health.validation_threshold,
        "genuine_mean": health.genuine_mean,
        "impostor_mean": health.impostor_mean,
        "separation": health.separation,
        "effective_rank": health.effective_rank,
        "first_pc_variance": health.first_pc_variance,
        "finite_gradients": finite_gradients,
        "clipped_batches": clipped_batches,
        "health": health.verdict,
        "ready_to_advance": health.ready_to_advance,
    }
    history.append(record)
    _save_state(
        path=state_path,
        model=model,
        head=head,
        optimizer=optimizer,
        scheduler=scheduler,
        generator=generator,
        config=config,
        stage_index=stage_index,
        stage_identities=stage_identities,
        completed_epoch=epoch,
        history=history,
        health=health,
        transition=transition,
    )
    record["checkpoint_path"] = state_path.relative_to(root).as_posix()
    record["checkpoint_sha256"] = sha256_file(state_path)
    _atomic_json_write(record, status_path)
    print(format_validation_summary(record), flush=True)
    return record


def run_mechanics_test(root: Path | None = None) -> dict[str, Any]:
    """Bounded 16-to-32 transition, checkpoint/RNG, and health-gate proof."""

    root = repository_root() if root is None else root
    _, config = load_curriculum_configuration(root)
    _set_determinism(config.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    generator = torch.Generator().manual_seed(config.seed)
    model = build_merlens_model().to(device)
    old_head = _head_with_seed(16, config.seed, device)
    model.eval()
    fixed = torch.randn(4, 3, 224, 224, device=device)
    model_state = {key: value.detach().clone() for key, value in model.state_dict().items()}
    with torch.inference_mode():
        embeddings_before = model(fixed).detach().clone()
    expanded = expand_arcface_head(old_head, 32, seed=config.seed + 32)
    verify_expansion(model, old_head, expanded, fixed)
    with torch.inference_mode():
        embeddings_after = model(fixed).detach().clone()
    optimizer = build_optimizer(model, expanded, config)
    scheduler = build_scheduler(optimizer, config)
    healthy_embeddings = np.random.default_rng(config.seed).normal(size=(64, 128))
    healthy_embeddings /= np.linalg.norm(healthy_embeddings, axis=1, keepdims=True)
    healthy_rank, healthy_pc1 = representation_statistics(healthy_embeddings)
    healthy = classify_health(
        effective_rank=healthy_rank,
        first_pc_variance=healthy_pc1,
        genuine_mean=0.6,
        impostor_mean=0.1,
        validation_accuracy=0.8,
        validation_eer=0.2,
        validation_threshold=0.4,
        finite_gradients=True,
        training_target_top1=0.5,
        training_median_target_rank=2.0,
        completed_stage_epochs=12,
        minimum_epochs_before_advance=12,
    )
    failed = classify_health(
        effective_rank=1.01,
        first_pc_variance=0.999,
        genuine_mean=0.001,
        impostor_mean=0.0,
        validation_accuracy=0.5,
        validation_eer=0.5,
        validation_threshold=0.99,
        finite_gradients=True,
        training_target_top1=0.0,
        training_median_target_rank=31.0,
        completed_stage_epochs=1,
        minimum_epochs_before_advance=12,
    )
    checkpoint = root / "tmp/merlens-curriculum-mechanics.pt"
    _atomic_torch_save(
        {
            "model": model.state_dict(),
            "head": expanded.state_dict(),
            "optimizer": optimizer.state_dict(),
            "scheduler": scheduler.state_dict(),
            "random_state": _capture_random_state(generator),
            "stage": 1,
            "identity_count": 32,
        },
        checkpoint,
    )
    expected = (random.random(), float(np.random.random()), torch.rand(1).item())
    restored = torch.load(checkpoint, map_location=device, weights_only=True)
    restored_model = build_merlens_model().to(device)
    restored_head = ArcFaceTrainingHead(32).to(device)
    restored_model.load_state_dict(restored["model"], strict=True)
    restored_head.load_state_dict(restored["head"], strict=True)
    restored_optimizer = build_optimizer(restored_model, restored_head, config)
    restored_scheduler = build_scheduler(restored_optimizer, config)
    restored_optimizer.load_state_dict(restored["optimizer"])
    restored_scheduler.load_state_dict(restored["scheduler"])
    _restore_random_state(restored["random_state"], generator)
    actual = (random.random(), float(np.random.random()), torch.rand(1).item())
    checkpoint.unlink(missing_ok=True)
    report = {
        "nested_mapping": tuple(range(16)) == tuple(range(32))[:16],
        "old_centers_preserved": torch.equal(old_head.class_centers, expanded.class_centers[:, :16]),
        "model_preserved": all(torch.equal(model_state[key], value) for key, value in model.state_dict().items()),
        "embeddings_preserved": torch.equal(embeddings_before, embeddings_after),
        "optimizer_transition": "rebuilt_clean_for_expanded_classifier",
        "scheduler_transition": "reset_for_new_stage",
        "checkpoint_resume": restored["identity_count"] == 32,
        "model_checkpoint_restore": all(
            torch.equal(restored_model.state_dict()[key], value)
            for key, value in model.state_dict().items()
        ),
        "classifier_checkpoint_restore": torch.equal(
            restored_head.class_centers, expanded.class_centers
        ),
        "optimizer_checkpoint_restore": len(restored_optimizer.param_groups) == 2,
        "scheduler_checkpoint_restore": (
            restored_scheduler.last_epoch == scheduler.last_epoch
        ),
        "rng_restore": expected == actual,
        "healthy_case": healthy.verdict == "HEALTHY" and healthy.ready_to_advance,
        "failed_case": failed.verdict == "FAILED" and not failed.ready_to_advance,
        "new_lineage_only": "merlens-v2-curriculum"
        in curriculum_paths(root)[0].as_posix(),
    }
    if not all(value for key, value in report.items() if isinstance(value, bool)):
        raise RuntimeError("curriculum mechanics test failed")
    _, _, mechanics_path = curriculum_paths(root)
    _atomic_json_write(report, mechanics_path)
    return report
