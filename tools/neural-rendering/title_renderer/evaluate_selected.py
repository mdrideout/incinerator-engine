#!/usr/bin/env python3
"""Open the selected NR5-C test once, then evaluate NR5-D stress separately."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

from title_renderer.artifacts import load_checkpoint
from title_renderer.dataset import TitleCorpusDataset
from title_renderer.evaluation import evaluate
from title_renderer.io import atomic_json, load_json, sha256_file
from title_renderer.models import SpatialTitleRendererConfig, create_spatial_model


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--split", required=True, choices=("test", "stress"))
    args = parser.parse_args()
    root = args.run.resolve()
    corpus = args.corpus.resolve()
    run_path = root / "run.json"
    run = load_json(run_path)
    selection = load_json(root / "selection.json")
    if (
        run.get("schema") != 2
        or run.get("phase") != "NR5-C"
        or run.get("status") != "validation_selected_pending_test"
        or selection.get("status") != "selected_for_single_test_open"
        or selection.get("run_sha256") != sha256_file(run_path)
        or selection.get("checkpoint_sha256") != run["checkpoint"]["sha256"]
    ):
        raise ValueError("NR5-C run was not validation-selected for evaluation")
    if args.split == "test" and (root / "test-opening.json").exists():
        opening_path = root / "test-opening.json"
        rejection_path = root / "test-reopen-rejection.json"
        if not rejection_path.exists():
            atomic_json(
                rejection_path,
                {
                    "schema": 1,
                    "phase": "NR5-C",
                    "status": "rejected",
                    "reason": "the sealed test split was already opened by the immutable selected checkpoint",
                    "test_opening_sha256": sha256_file(opening_path),
                    "requested_split": "test",
                    "pixels_opened_by_rejected_attempt": False,
                },
            )
        raise ValueError("the sealed NR5-C test split has already been opened")
    if args.split == "stress" and not (root / "test-opening.json").is_file():
        raise ValueError("NR5-D stress evaluation requires completed NR5-C test evaluation")
    destination = root / "evaluation" / args.split
    if destination.exists():
        raise ValueError(f"evaluation split already exists: {destination}")
    configuration = load_json(root / run["configuration"])
    train_spec = load_json(root / run["train_dataset"])
    dataset = TitleCorpusDataset(corpus, (args.split,), allow_test=args.split == "test")
    if (
        dataset.specification.semantic_vocabulary != {int(key): value for key, value in train_spec["semantic_vocabulary"].items()}
        or dataset.specification.instance_vocabulary != {int(key): value for key, value in train_spec["instance_vocabulary"].items()}
        or list(dataset.specification.control_minimum) != train_spec["control_minimum"]
        or list(dataset.specification.control_maximum) != train_spec["control_maximum"]
    ):
        raise ValueError("evaluation preprocessing vocabulary/range differs from training")
    checkpoint = load_checkpoint(Path(run["checkpoint"]["path"]))
    model_config = SpatialTitleRendererConfig(**configuration["model"])
    model = create_spatial_model(
        model_config,
        semantic_categories=len(dataset.specification.semantic_vocabulary),
        instance_categories=len(dataset.specification.instance_vocabulary),
        initialization_seed=int(configuration["initialization_seed"]),
    )
    model.load_state_dict(checkpoint["state_dict"])
    if not torch.backends.mps.is_available():
        raise ValueError("selected evaluation requires the declared Apple MPS host")
    device = torch.device("mps")
    model = model.to(device)
    result = evaluate(
        model,
        DataLoader(dataset, batch_size=1, shuffle=False, num_workers=0),
        device,
        sample_root=destination / "samples",
        overview_path=destination / "overview.png",
    )
    full = result["metrics"]["model"]
    bilinear = result["metrics"]["bilinear"]
    appearance = result["metrics"]["appearance_only"]
    gates = {
        "model_beats_bilinear_hdr": full["linear_hdr_mae"] < bilinear["linear_hdr_mae"],
        "model_beats_bilinear_semantic_boundary": full["semantic_boundary_mae"] < bilinear["semantic_boundary_mae"],
        "model_beats_bilinear_instance_boundary": full["instance_boundary_mae"] < bilinear["instance_boundary_mae"],
        "full_model_beats_appearance_only": full["linear_hdr_mae"] < appearance["linear_hdr_mae"],
        "all_metrics_finite": all(np.isfinite(value) for owner in result["metrics"].values() for value in owner.values()),
    }
    record_path = destination / "evaluation.json"
    record = {
        "schema": 1,
        "phase": "NR5-C" if args.split == "test" else "NR5-D",
        "split": args.split,
        "run_sha256": sha256_file(run_path),
        "checkpoint_sha256": run["checkpoint"]["sha256"],
        "dataset": dataset.specification.json(),
        "evaluation": result,
        "gates": gates,
        "automated_gate_passed": all(gates.values()),
        "test_pixels_opened": args.split == "test",
        "promotion_authorized": False,
    }
    atomic_json(record_path, record)
    if args.split == "test":
        atomic_json(
            root / "test-opening.json",
            {
                "schema": 1,
                "phase": "NR5-C",
                "status": "complete",
                "policy": "single opening after immutable validation selection",
                "selection_sha256": sha256_file(root / "selection.json"),
                "evaluation": "evaluation/test/evaluation.json",
                "evaluation_sha256": sha256_file(record_path),
                "frames_opened": len(dataset),
                "test_pixels_opened": True,
                "reopen_guard_installed": True,
            },
        )
    else:
        atomic_json(
            root / "stress-evaluation.json",
            {
                "schema": 1,
                "phase": "NR5-D",
                "status": "complete",
                "evaluation": "evaluation/stress/evaluation.json",
                "evaluation_sha256": sha256_file(record_path),
                "frames": len(dataset),
                "promotion_authorized": False,
            },
        )
    print(f"NR5_SELECTED_EVALUATION_COMPLETE split={args.split} passed={all(gates.values())} mae={full['linear_hdr_mae']:.8f} root={root}")


if __name__ == "__main__":
    main()
