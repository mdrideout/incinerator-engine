"""Immutable checkpoint lineage and learned-tensor origin audit."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import torch

from .io import atomic_json, sha256_file


CHECKPOINT_SCHEMA = 1


def tensor_inventory(state_dict: dict[str, torch.Tensor], origin: str) -> list[dict[str, Any]]:
    return [
        {
            "name": name,
            "shape": list(value.shape),
            "dtype": str(value.dtype),
            "origin": origin,
        }
        for name, value in sorted(state_dict.items())
    ]


def save_checkpoint(
    path: Path,
    *,
    kind: str,
    model: torch.nn.Module,
    model_configuration: dict[str, Any],
    dataset_sha256: str,
    initialization_seed: int,
    training_seed: int,
    epoch: int,
    optimizer: torch.optim.Optimizer | None,
    scheduler: torch.optim.lr_scheduler.LRScheduler | None,
    ancestors: list[dict[str, str]],
    tensor_origin: str,
) -> dict[str, Any]:
    if path.exists():
        raise ValueError(f"checkpoint path already exists: {path}")
    state = {name: value.detach().cpu() for name, value in model.state_dict().items()}
    payload = {
        "schema": CHECKPOINT_SCHEMA,
        "kind": kind,
        "model_configuration": model_configuration,
        "dataset_sha256": dataset_sha256,
        "initialization_seed": initialization_seed,
        "training_seed": training_seed,
        "epoch": epoch,
        "ancestors": ancestors,
        "tensor_inventory": tensor_inventory(state, tensor_origin),
        "state_dict": state,
        "optimizer_state": optimizer.state_dict() if optimizer is not None else None,
        "scheduler_state": scheduler.state_dict() if scheduler is not None else None,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(payload, path)
    return {
        "path": str(path),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
        "kind": kind,
        "epoch": epoch,
    }


def load_checkpoint(path: Path) -> dict[str, Any]:
    value = torch.load(path, map_location="cpu", weights_only=True)
    if not isinstance(value, dict) or value.get("schema") != CHECKPOINT_SCHEMA:
        raise ValueError(f"unsupported title-renderer checkpoint: {path}")
    state = value.get("state_dict")
    inventory = value.get("tensor_inventory")
    if not isinstance(state, dict) or not isinstance(inventory, list):
        raise ValueError(f"checkpoint has no learned-tensor inventory: {path}")
    expected = {
        item["name"]: (tuple(item["shape"]), item["dtype"], item["origin"])
        for item in inventory
    }
    actual = {name: (tuple(tensor.shape), str(tensor.dtype)) for name, tensor in state.items()}
    if set(expected) != set(actual):
        raise ValueError(f"checkpoint tensor inventory names drifted: {path}")
    for name, (shape, dtype) in actual.items():
        expected_shape, expected_dtype, origin = expected[name]
        if shape != expected_shape or dtype != expected_dtype or not str(origin):
            raise ValueError(f"checkpoint tensor inventory drifted for {name}: {path}")
    return value


def audit_checkpoint(path: Path, output: Path | None = None) -> dict[str, Any]:
    checkpoint = load_checkpoint(path)
    ancestors = checkpoint["ancestors"]
    for ancestor in ancestors:
        ancestor_path = Path(str(ancestor["path"]))
        if not ancestor_path.is_file() or sha256_file(ancestor_path) != ancestor["sha256"]:
            raise ValueError(f"checkpoint ancestor is missing or changed: {ancestor_path}")
    origins = sorted({str(item["origin"]) for item in checkpoint["tensor_inventory"]})
    if any(not (origin.startswith("random_initializer:") or origin.startswith("title_checkpoint:")) for origin in origins):
        raise ValueError(f"checkpoint declares a foreign learned origin: {origins}")
    result = {
        "schema": 1,
        "checkpoint": str(path.resolve()),
        "checkpoint_sha256": sha256_file(path),
        "kind": checkpoint["kind"],
        "epoch": checkpoint["epoch"],
        "tensor_count": len(checkpoint["tensor_inventory"]),
        "origins": origins,
        "ancestors": ancestors,
        "status": "passed",
    }
    if output is not None:
        atomic_json(output, result)
    return result


def write_lineage(path: Path, value: dict[str, Any]) -> None:
    """Separate JSON owner used by inspectors without importing Torch."""

    atomic_json(path, value)
    json.loads(path.read_text(encoding="utf-8"))
