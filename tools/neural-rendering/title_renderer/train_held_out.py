#!/usr/bin/env python3
"""Train and validation-select NR5-C while leaving the test split sealed."""

from __future__ import annotations

import argparse
import copy
import random
import shutil
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

from title_renderer.artifacts import audit_checkpoint, save_checkpoint
from title_renderer.authorize_held_out import SCOPE
from title_renderer.dataset import TitleCorpusDataset
from title_renderer.evaluation import evaluate, model_output, synchronize
from title_renderer.io import atomic_json, create_absent_absolute, environment_record, load_json, repository_record, require_existing_absolute, sha256_file
from title_renderer.metrics import loss_terms
from title_renderer.models import SpatialTitleRendererConfig, create_spatial_model


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--authorization", required=True, type=Path)
    parser.add_argument("--configuration", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    corpus = require_existing_absolute(args.corpus, "--corpus")
    authorization_path = require_existing_absolute(args.authorization, "--authorization")
    configuration_path = require_existing_absolute(args.configuration, "--configuration")
    repository = require_existing_absolute(args.repository, "--repository")
    output = create_absent_absolute(args.output, "--output")
    try:
        authorization = load_json(authorization_path)
        if (
            authorization.get("status") != "accepted"
            or authorization.get("authorization_scope") != SCOPE
            or authorization.get("test_pixels_opened") is not False
            or authorization.get("corpus_manifest_sha256") != sha256_file(corpus / "corpus.json")
        ):
            raise ValueError("NR5-C requires the exact sealed held-out authorization")
        configuration = load_json(configuration_path)
        if configuration.get("schema") != 1 or configuration.get("stage") != "held_out_structural_reconstruction":
            raise ValueError("unsupported NR5-C configuration")
        if configuration.get("train_splits") != ["overfit", "train"] or configuration.get("selection_split") != "validation":
            raise ValueError("NR5-C split ownership drifted")
        initialization_seed = int(configuration["initialization_seed"])
        training_seed = int(configuration["training_seed"])
        random.seed(training_seed)
        np.random.seed(training_seed)
        torch.manual_seed(training_seed)
        if configuration.get("device") != "mps" or not torch.backends.mps.is_available():
            raise ValueError("NR5-C requires the declared Apple MPS host")
        device = torch.device("mps")
        train_dataset = TitleCorpusDataset(corpus, ("overfit", "train"))
        validation_dataset = TitleCorpusDataset(corpus, ("validation",))
        if (
            train_dataset.specification.semantic_vocabulary != validation_dataset.specification.semantic_vocabulary
            or train_dataset.specification.instance_vocabulary != validation_dataset.specification.instance_vocabulary
            or train_dataset.specification.control_minimum != validation_dataset.specification.control_minimum
            or train_dataset.specification.control_maximum != validation_dataset.specification.control_maximum
        ):
            raise ValueError("validation preprocessing vocabulary/range differs from training")
        atomic_json(output / "dataset" / "train.json", train_dataset.specification.json())
        atomic_json(output / "dataset" / "validation.json", validation_dataset.specification.json())
        authorization_snapshot = output / "dataset" / "authorization.json"
        authorization_snapshot.write_bytes(authorization_path.read_bytes())
        configuration_snapshot = output / "configuration.json"
        configuration_snapshot.write_bytes(configuration_path.read_bytes())
        dataset_sha256 = sha256_file(output / "dataset" / "train.json")
        model_configuration = SpatialTitleRendererConfig(**configuration["model"])
        model = create_spatial_model(
            model_configuration,
            semantic_categories=len(train_dataset.specification.semantic_vocabulary),
            instance_categories=len(train_dataset.specification.instance_vocabulary),
            initialization_seed=initialization_seed,
        )
        parameter_count = sum(parameter.numel() for parameter in model.parameters())
        initializer = save_checkpoint(
            output / "checkpoints" / "initializer.pt",
            kind="random_initializer",
            model=model,
            model_configuration=model_configuration.json(),
            dataset_sha256=dataset_sha256,
            initialization_seed=initialization_seed,
            training_seed=training_seed,
            epoch=0,
            optimizer=None,
            scheduler=None,
            ancestors=[],
            tensor_origin=f"random_initializer:{initialization_seed}",
        )
        audit_checkpoint(Path(initializer["path"]), output / "checkpoints" / "initializer-audit.json")
        model = model.to(device)
        optimizer = torch.optim.AdamW(
            model.parameters(),
            lr=float(configuration["optimizer"]["learning_rate"]),
            weight_decay=float(configuration["optimizer"]["weight_decay"]),
        )
        scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
            optimizer,
            T_max=int(configuration["epochs"]),
            eta_min=float(configuration["scheduler"]["minimum_learning_rate"]),
        )
        train_loader = DataLoader(
            train_dataset,
            batch_size=int(configuration["batch_size"]),
            shuffle=True,
            generator=torch.Generator().manual_seed(training_seed),
            num_workers=0,
        )
        validation_loader = DataLoader(validation_dataset, batch_size=1, shuffle=False, num_workers=0)
        best_metric = float("inf")
        selected_epoch = 0
        selected_state = copy.deepcopy(model.state_dict())
        selected_optimizer = copy.deepcopy(optimizer.state_dict())
        selected_scheduler = copy.deepcopy(scheduler.state_dict())
        history = []
        started = time.perf_counter()
        for epoch in range(1, int(configuration["epochs"]) + 1):
            model.train()
            total = 0.0
            batches = 0
            epoch_started = time.perf_counter()
            for batch in train_loader:
                continuous = batch["continuous"].to(device)
                semantic = batch["semantic"].to(device)
                instance = batch["instance"].to(device)
                controls = batch["global_controls"].to(device)
                target = batch["target"].to(device)
                coverage = batch["target_coverage"].to(device)
                optimizer.zero_grad(set_to_none=True)
                prediction = model(continuous, semantic, instance, controls)
                loss, _terms = loss_terms(prediction, target, semantic, instance, coverage)
                loss.backward()
                optimizer.step()
                total += float(loss.detach())
                batches += 1
            synchronize(device)
            scheduler.step()
            record = {
                "epoch": epoch,
                "training_loss": total / batches,
                "learning_rate": float(optimizer.param_groups[0]["lr"]),
                "duration_ms": (time.perf_counter() - epoch_started) * 1000.0,
            }
            if epoch == 1 or epoch % int(configuration["validate_every_epochs"]) == 0 or epoch == int(configuration["epochs"]):
                selected_evaluation = evaluate(model, validation_loader, device)
                validation_mae = float(selected_evaluation["metrics"]["model"]["linear_hdr_mae"])
                record["validation_linear_hdr_mae"] = validation_mae
                if validation_mae < best_metric:
                    best_metric = validation_mae
                    selected_epoch = epoch
                    selected_state = copy.deepcopy(model.state_dict())
                    selected_optimizer = copy.deepcopy(optimizer.state_dict())
                    selected_scheduler = copy.deepcopy(scheduler.state_dict())
                print(f"epoch={epoch} train_loss={record['training_loss']:.8f} validation_mae={validation_mae:.8f}", flush=True)
            history.append(record)
        training_duration_ms = (time.perf_counter() - started) * 1000.0
        model.load_state_dict(selected_state)
        optimizer.load_state_dict(selected_optimizer)
        scheduler.load_state_dict(selected_scheduler)
        checkpoint = save_checkpoint(
            output / "checkpoints" / "validation-selected.pt",
            kind="title_validation_selected_checkpoint",
            model=model,
            model_configuration=model_configuration.json(),
            dataset_sha256=dataset_sha256,
            initialization_seed=initialization_seed,
            training_seed=training_seed,
            epoch=selected_epoch,
            optimizer=optimizer,
            scheduler=scheduler,
            ancestors=[{"path": initializer["path"], "sha256": initializer["sha256"], "kind": initializer["kind"]}],
            tensor_origin=f"title_checkpoint:{initializer['sha256']}",
        )
        checkpoint_audit = audit_checkpoint(Path(checkpoint["path"]), output / "checkpoints" / "checkpoint-audit.json")
        validation = evaluate(
            model,
            validation_loader,
            device,
            sample_root=output / "evaluation" / "validation" / "samples",
            overview_path=output / "evaluation" / "validation" / "overview.png",
        )
        model_metrics = validation["metrics"]["model"]
        bilinear_metrics = validation["metrics"]["bilinear"]
        appearance_metrics = validation["metrics"]["appearance_only"]
        gates = {
            "selected_on_validation": selected_epoch > 0,
            "model_beats_bilinear_hdr": model_metrics["linear_hdr_mae"] < bilinear_metrics["linear_hdr_mae"],
            "model_beats_bilinear_semantic_boundary": model_metrics["semantic_boundary_mae"] < bilinear_metrics["semantic_boundary_mae"],
            "model_beats_bilinear_instance_boundary": model_metrics["instance_boundary_mae"] < bilinear_metrics["instance_boundary_mae"],
            "full_model_beats_appearance_only": model_metrics["linear_hdr_mae"] < appearance_metrics["linear_hdr_mae"],
            "all_metrics_finite": all(np.isfinite(value) for owner in validation["metrics"].values() for value in owner.values()),
            "test_pixels_opened": False,
        }
        automated_gate_passed = all(value for name, value in gates.items() if name != "test_pixels_opened") and gates["test_pixels_opened"] is False
        validation_path = output / "evaluation" / "validation" / "evaluation.json"
        atomic_json(validation_path, {"schema": 1, "phase": "NR5-C", "split": "validation", "evaluation": validation, "gates": gates, "automated_gate_passed": automated_gate_passed})
        model_cpu = copy.deepcopy(model).cpu().eval()
        sample = validation_dataset[0]
        inputs = tuple(sample[name].unsqueeze(0) for name in ("continuous", "semantic", "instance", "global_controls"))
        with torch.inference_mode():
            expected = model_cpu(*inputs)
            traced = torch.jit.trace(model_cpu, inputs, strict=True)
            export_path = output / "export" / "model-torchscript.pt"
            export_path.parent.mkdir(parents=True, exist_ok=True)
            traced.save(str(export_path))
            actual = torch.jit.load(str(export_path)).eval()(*inputs)
        export = {"schema": 1, "format": "torchscript_trace_candidate_not_runtime_bundle", "path": str(export_path), "bytes": export_path.stat().st_size, "sha256": sha256_file(export_path), "maximum_absolute_agreement": float((expected - actual).abs().max()), "mean_absolute_agreement": float((expected - actual).abs().mean())}
        export_manifest = output / "export" / "export.json"
        atomic_json(export_manifest, export)
        environment_path = output / "environment.json"
        atomic_json(environment_path, environment_record() | {"torch": torch.__version__, "numpy": np.__version__, "device": str(device)})
        source_paths = [
            Path(__file__).resolve(), Path(__file__).with_name("__init__.py"), Path(__file__).with_name("artifacts.py"),
            Path(__file__).with_name("authorize_held_out.py"), Path(__file__).with_name("contracts.py"), Path(__file__).with_name("dataset.py"),
            Path(__file__).with_name("evaluation.py"), Path(__file__).with_name("io.py"), Path(__file__).with_name("metrics.py"),
            Path(__file__).with_name("models") / "__init__.py", Path(__file__).with_name("models") / "spatial.py",
        ]
        source_records = []
        for source in source_paths:
            relative = source.relative_to(repository)
            snapshot = output / "source" / relative
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, snapshot)
            source_records.append({"repository_path": str(relative), "repository_sha256": sha256_file(source), "snapshot_path": str(snapshot.relative_to(output)), "snapshot_sha256": sha256_file(snapshot), "bytes": snapshot.stat().st_size})
        run = {
            "schema": 2, "experiment": "NR-0005", "phase": "NR5-C", "status": "validation_selected_pending_test" if automated_gate_passed else "validation_gate_failed",
            "configuration": "configuration.json", "configuration_sha256": sha256_file(configuration_snapshot),
            "authorization": "dataset/authorization.json", "authorization_sha256": sha256_file(authorization_snapshot),
            "repository": repository_record(repository), "train_dataset": "dataset/train.json", "train_dataset_sha256": dataset_sha256,
            "validation_dataset": "dataset/validation.json", "validation_dataset_sha256": sha256_file(output / "dataset" / "validation.json"),
            "initializer": initializer, "checkpoint": checkpoint, "checkpoint_audit": checkpoint_audit, "parameter_count": parameter_count,
            "selected_epoch": selected_epoch, "selected_validation_linear_hdr_mae": best_metric, "training_duration_ms": training_duration_ms, "history": history,
            "validation": "evaluation/validation/evaluation.json", "validation_sha256": sha256_file(validation_path),
            "export": "export/export.json", "export_sha256": sha256_file(export_manifest), "environment": "environment.json", "environment_sha256": sha256_file(environment_path),
            "tool_sources": source_records, "external_pretrained_weights": False, "test_pixels_opened": False, "promotion_eligible": False,
        }
        atomic_json(output / "run.json", run)
        atomic_json(output / "selection.json", {"schema": 1, "phase": "NR5-C", "status": "selected_for_single_test_open" if automated_gate_passed else "not_selected", "run_sha256": sha256_file(output / "run.json"), "checkpoint_sha256": checkpoint["sha256"], "selected_epoch": selected_epoch, "selection_split": "validation", "test_pixels_opened": False})
    except Exception as error:
        atomic_json(output / "failure.json", {"schema": 1, "phase": "NR5-C", "error": str(error)})
        raise
    print(f"NR5_C_VALIDATION_SELECTED passed={automated_gate_passed} epoch={selected_epoch} validation_mae={best_metric:.8f} output={output}")


if __name__ == "__main__":
    main()
