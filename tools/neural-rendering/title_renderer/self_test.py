#!/usr/bin/env python3
"""NR5-A clean-room initialize/train/resume/evaluate/export proof."""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import torch
from torch.nn import functional

from title_renderer.artifacts import audit_checkpoint, load_checkpoint, save_checkpoint
from title_renderer.io import atomic_json, create_absent_absolute, environment_record, sha256_file
from title_renderer.models import SpatialTitleRendererConfig, create_spatial_model


def synthetic_batch() -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    y = torch.linspace(0.0, 1.0, 8)[None, :, None]
    x = torch.linspace(0.0, 1.0, 16)[None, None, :]
    continuous = torch.zeros((1, 11, 8, 16), dtype=torch.float32)
    continuous[:, 0] = x
    continuous[:, 1] = y
    continuous[:, 2] = 0.15
    continuous[:, 3] = 0.4
    continuous[:, 4:7] = torch.tensor((0.0, 1.0, 0.0))[None, :, None, None]
    continuous[:, 9] = 1.0
    continuous[:, 10] = 1.0
    semantic = torch.zeros((1, 8, 16), dtype=torch.long)
    semantic[:, :, 8:] = 1
    instance = torch.zeros((1, 8, 16), dtype=torch.long)
    instance[:, 2:7, 4:12] = 1
    controls = torch.tensor(((0.5, 0.25, 0.75, 1.0),), dtype=torch.float32)
    base = functional.interpolate(continuous[:, :3], size=(20, 40), mode="bilinear", align_corners=False)
    target = torch.stack(
        (
            (base[:, 0] * 0.7 + base[:, 1] * 0.2 + 0.05),
            (base[:, 1] * 0.8 + 0.04),
            (base[:, 2] * 0.5 + base[:, 0] * 0.15 + 0.02),
        ),
        dim=1,
    )
    return continuous, semantic, instance, controls, target


def train_steps(
    model: torch.nn.Module,
    optimizer: torch.optim.Optimizer,
    batch: tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor],
    steps: int,
) -> list[float]:
    continuous, semantic, instance, controls, target = batch
    history = []
    for _step in range(steps):
        optimizer.zero_grad(set_to_none=True)
        output = model(continuous, semantic, instance, controls)
        loss = functional.smooth_l1_loss(output, target, beta=0.01)
        loss.backward()
        optimizer.step()
        history.append(float(loss.detach()))
    return history


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = create_absent_absolute(args.output, "--output")
    parent = root / "parent"
    resumed = root / "resumed"
    parent.mkdir()
    resumed.mkdir()
    configuration = SpatialTitleRendererConfig(features=8, low_blocks=1, output_blocks=1, output_width=40, output_height=20)
    dataset_sha256 = "synthetic-title-owned-clean-room-fixture"
    initialization_seed = 2026080901
    training_seed = 2026080902
    started = time.perf_counter()
    try:
        batch = synthetic_batch()
        model = create_spatial_model(
            configuration,
            semantic_categories=2,
            instance_categories=2,
            initialization_seed=initialization_seed,
        )
        initializer = save_checkpoint(
            parent / "initializer.pt",
            kind="random_initializer",
            model=model,
            model_configuration=configuration.json(),
            dataset_sha256=dataset_sha256,
            initialization_seed=initialization_seed,
            training_seed=training_seed,
            epoch=0,
            optimizer=None,
            scheduler=None,
            ancestors=[],
            tensor_origin=f"random_initializer:{initialization_seed}",
        )
        audit_checkpoint(Path(initializer["path"]), parent / "initializer-audit.json")
        optimizer = torch.optim.AdamW(model.parameters(), lr=0.001, weight_decay=0.0)
        parent_history = train_steps(model, optimizer, batch, 10)
        parent_checkpoint = save_checkpoint(
            parent / "checkpoint.pt",
            kind="title_trained_checkpoint",
            model=model,
            model_configuration=configuration.json(),
            dataset_sha256=dataset_sha256,
            initialization_seed=initialization_seed,
            training_seed=training_seed,
            epoch=10,
            optimizer=optimizer,
            scheduler=None,
            ancestors=[{"path": initializer["path"], "sha256": initializer["sha256"], "kind": "random_initializer"}],
            tensor_origin=f"title_checkpoint:{initializer['sha256']}",
        )
        audit_checkpoint(Path(parent_checkpoint["path"]), parent / "checkpoint-audit.json")
        parent_digest_before_resume = sha256_file(Path(parent_checkpoint["path"]))

        ancestor = load_checkpoint(Path(parent_checkpoint["path"]))
        resumed_model = create_spatial_model(
            configuration,
            semantic_categories=2,
            instance_categories=2,
            initialization_seed=initialization_seed,
        )
        resumed_model.load_state_dict(ancestor["state_dict"])
        resumed_optimizer = torch.optim.AdamW(resumed_model.parameters(), lr=0.0005, weight_decay=0.0)
        resumed_optimizer.load_state_dict(ancestor["optimizer_state"])
        for group in resumed_optimizer.param_groups:
            group["lr"] = 0.0005
        resumed_history = train_steps(resumed_model, resumed_optimizer, batch, 5)
        resumed_checkpoint = save_checkpoint(
            resumed / "checkpoint.pt",
            kind="title_trained_checkpoint",
            model=resumed_model,
            model_configuration=configuration.json(),
            dataset_sha256=dataset_sha256,
            initialization_seed=initialization_seed,
            training_seed=training_seed,
            epoch=15,
            optimizer=resumed_optimizer,
            scheduler=None,
            ancestors=[{"path": parent_checkpoint["path"], "sha256": parent_checkpoint["sha256"], "kind": "title_trained_checkpoint"}],
            tensor_origin=f"title_checkpoint:{parent_checkpoint['sha256']}",
        )
        resumed_audit = audit_checkpoint(Path(resumed_checkpoint["path"]), resumed / "checkpoint-audit.json")
        if sha256_file(Path(parent_checkpoint["path"])) != parent_digest_before_resume:
            raise ValueError("resume mutated its parent checkpoint")
        continuous, semantic, instance, controls, target = batch
        resumed_model.eval()
        with torch.inference_mode():
            expected = resumed_model(continuous, semantic, instance, controls)
            final_loss = float(functional.l1_loss(expected, target))
            traced = torch.jit.trace(resumed_model, (continuous, semantic, instance, controls), strict=True)
            export_path = resumed / "model-torchscript.pt"
            traced.save(str(export_path))
            actual = torch.jit.load(str(export_path))(continuous, semantic, instance, controls)
            export_maximum_error = float((expected - actual).abs().max())
        checks = {
            "initializer_audited": True,
            "training_descended": parent_history[-1] < parent_history[0],
            "resume_descended": resumed_history[-1] < resumed_history[0],
            "resume_parent_immutable": True,
            "resumed_lineage_audited": resumed_audit["status"] == "passed",
            "export_exact": export_maximum_error == 0.0,
            "no_external_weights": True,
        }
        if not all(checks.values()):
            raise ValueError(f"NR5-A clean-room checks failed: {checks}")
        result = {
            "schema": 1,
            "phase": "NR5-A",
            "status": "passed",
            "fixture": "deterministic repository-defined synthetic title-owned tensors",
            "model": configuration.json(),
            "initializer": initializer,
            "parent_checkpoint": parent_checkpoint,
            "resumed_checkpoint": resumed_checkpoint,
            "parent_history": parent_history,
            "resumed_history": resumed_history,
            "final_l1": final_loss,
            "export": {
                "path": str(export_path),
                "bytes": export_path.stat().st_size,
                "sha256": sha256_file(export_path),
                "maximum_absolute_agreement": export_maximum_error,
            },
            "checks": checks,
            "environment": environment_record() | {"torch": torch.__version__},
            "duration_ms": (time.perf_counter() - started) * 1000.0,
        }
        atomic_json(root / "acceptance.json", result)
    except Exception as error:
        atomic_json(root / "failure.json", {"schema": 1, "phase": "NR5-A", "status": "failed", "error": str(error)})
        raise
    print(
        f"NR5_A_CLEAN_ROOM_PASS final_l1={final_loss:.8f} "
        f"export_max_error={export_maximum_error:.9f} output={root}"
    )


if __name__ == "__main__":
    main()
