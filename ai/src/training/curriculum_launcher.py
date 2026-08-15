"""Command boundary for the single MerLens curriculum launcher."""

from __future__ import annotations

import argparse
import json
from collections.abc import Callable
from dataclasses import asdict
from typing import Any, Literal

from .curriculum import (
    CURRICULUM_STAGES,
    curriculum_paths,
    inspect_preflight,
    repository_root,
    run_mechanics_test,
    run_one_epoch,
)

ControllerAction = Literal[
    "continue_same_stage",
    "transition_next_stage",
    "stop_failed",
    "stop_complete",
]


def controller_action(result: dict[str, Any]) -> ControllerAction:
    """Choose the next continuous-mode action from saved epoch evidence."""

    if result["health"] == "FAILED":
        return "stop_failed"
    if result["health"] != "HEALTHY":
        raise RuntimeError("unknown curriculum health state")
    if not result["ready_to_advance"]:
        return "continue_same_stage"
    if int(result["stage"]) >= len(CURRICULUM_STAGES):
        return "stop_complete"
    return "transition_next_stage"


def execute_training_mode(
    mode: Literal["one_epoch", "continuous"],
    approval_token: str,
    *,
    epoch_runner: Callable[..., dict[str, Any]] = run_one_epoch,
) -> dict[str, Any]:
    """Run one epoch or continue until a structural/terminal stop."""

    if mode == "one_epoch":
        return {
            "stop_reason": "one_epoch_pause",
            "last_result": epoch_runner(approval_token=approval_token),
        }
    actions: list[ControllerAction] = []
    while True:
        result = epoch_runner(approval_token=approval_token)
        action = controller_action(result)
        actions.append(action)
        if action in ("stop_failed", "stop_complete"):
            return {
                "stop_reason": action,
                "actions": actions,
                "last_result": result,
            }


def status() -> dict[str, object]:
    root = repository_root()
    preflight = inspect_preflight(root)
    state_path, status_path, _ = curriculum_paths(root)
    payload: dict[str, object] = {
        "run_name": "merlens-v2-curriculum",
        "stage": preflight.stage,
        "stage_count": len(CURRICULUM_STAGES),
        "identity_count": preflight.identity_count,
        "current_epoch": 0,
        "next_epoch": 1,
        "resume_available": state_path.is_file(),
        "health": "Pending",
        "preflight": asdict(preflight),
    }
    if status_path.is_file():
        completed = json.loads(status_path.read_text(encoding="utf-8"))
        payload.update(
            current_epoch=completed["epoch"],
            next_epoch=completed["epoch"] + 1,
            health=completed["health"],
        )
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=("preflight", "status", "mechanics", "one_epoch", "continuous"),
        default="status",
    )
    parser.add_argument("--approval-token", default="")
    args = parser.parse_args()
    if args.mode == "preflight":
        result: object = asdict(inspect_preflight())
    elif args.mode == "status":
        result = status()
    elif args.mode == "mechanics":
        result = run_mechanics_test()
    else:
        result = execute_training_mode(args.mode, args.approval_token)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
