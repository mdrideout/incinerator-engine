#!/usr/bin/env python3
"""Train the first random-initialized Incinerator spatial title renderer."""

from __future__ import annotations

import argparse
import copy
import random
import shutil
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch.utils.data import DataLoader

from title_renderer.artifacts import audit_checkpoint, save_checkpoint
from title_renderer.dataset import TitleCorpusDataset
from title_renderer.io import (
    atomic_json,
    create_absent_absolute,
    environment_record,
    load_json,
    repository_record,
    require_existing_absolute,
    sha256_file,
)
from title_renderer.metrics import BASELINES, ReconstructionLossConfig, comparison_sheet, loss_terms, metrics, overview_sheet, resize_baseline
from title_renderer.coverage import INITIAL_STRUCTURAL_SCOPE, RF6_SCOPE, RF7_SCOPE, RF8_SCOPE, RF9_SCOPE, RF10_SCOPE
from title_renderer.models import SpatialTitleRendererConfig, create_spatial_model


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--coverage-acceptance", required=True, type=Path)
    parser.add_argument("--configuration", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    return parser.parse_args()


def select_device(requested: str) -> torch.device:
    if requested == "mps":
        if not torch.backends.mps.is_available():
            raise ValueError("MPS was requested but is unavailable")
        return torch.device("mps")
    if requested == "cpu":
        return torch.device("cpu")
    raise ValueError(f"unsupported training device: {requested}")


def package_environment(device: torch.device) -> dict[str, Any]:
    value = environment_record()
    value.update(
        {
            "torch": torch.__version__,
            "numpy": np.__version__,
            "openexr": __import__("OpenEXR").__version__,
            "pillow": __import__("PIL").__version__,
            "device": str(device),
            "mps_built": torch.backends.mps.is_built(),
            "mps_available": torch.backends.mps.is_available(),
        }
    )
    return value


def sync(device: torch.device) -> None:
    if device.type == "mps":
        torch.mps.synchronize()


def evaluate(
    model: torch.nn.Module,
    loader: DataLoader,
    device: torch.device,
    sample_root: Path,
) -> dict[str, Any]:
    totals: dict[str, dict[str, float]] = {}
    names = (*BASELINES, "model")
    per_frame: list[dict[str, Any]] = []
    inference_ms: list[float] = []
    model.eval()
    with torch.inference_mode():
        for batch_index, batch in enumerate(loader):
            continuous = batch["continuous"].to(device)
            semantic = batch["semantic"].to(device)
            instance = batch["instance"].to(device)
            controls = batch["global_controls"].to(device)
            target = batch["target"].to(device)
            sync(device)
            started = time.perf_counter()
            model_output = model(continuous, semantic, instance, controls)
            sync(device)
            inference_ms.append((time.perf_counter() - started) * 1000.0)
            outputs = {
                name: resize_baseline(continuous[:, :3], (target.shape[2], target.shape[3]), name)
                for name in BASELINES
            }
            outputs["model"] = model_output
            frame_metrics = {
                name: metrics(output, target, semantic, instance)
                for name, output in outputs.items()
            }
            for name in names:
                totals.setdefault(name, {metric: 0.0 for metric in frame_metrics[name]})
                for metric, value in frame_metrics[name].items():
                    totals[name][metric] += value
            frame_id = str(batch["frame_id"][0])
            per_frame.append({"frame_id": frame_id, "metrics": frame_metrics})
            comparison_sheet(
                sample_root / f"{batch_index:04d}-{frame_id}.png",
                frame_id,
                [
                    ("cheap bilinear", outputs["bilinear"][0]),
                    ("model", model_output[0]),
                    ("target", target[0]),
                ],
            )
    frame_count = len(per_frame)
    averaged = {
        name: {metric: value / frame_count for metric, value in metric_totals.items()}
        for name, metric_totals in totals.items()
    }
    return {
        "frames": frame_count,
        "metrics": averaged,
        "per_frame": per_frame,
        "inference_ms": {
            "minimum": min(inference_ms),
            "median": float(np.percentile(inference_ms, 50)),
            "p95": float(np.percentile(inference_ms, 95)),
            "maximum": max(inference_ms),
            "scope": "offline PyTorch full-frame batch; not installed runtime",
        },
    }


def main() -> None:
    args = arguments()
    corpus = require_existing_absolute(args.corpus, "--corpus")
    coverage_acceptance_path = require_existing_absolute(args.coverage_acceptance, "--coverage-acceptance")
    configuration_path = require_existing_absolute(args.configuration, "--configuration")
    repository = require_existing_absolute(args.repository, "--repository")
    output = create_absent_absolute(args.output, "--output")
    configuration = load_json(configuration_path)
    if configuration.get("schema") != 1 or configuration.get("stage") != "controlled_spatial_overfit":
        raise ValueError("controlled fit requires a controlled_spatial_overfit configuration")
    if configuration.get("splits") != ["overfit"]:
        raise ValueError("controlled fit may open only the declared overfit split")
    initialization_seed = int(configuration["initialization_seed"])
    training_seed = int(configuration["training_seed"])
    random.seed(training_seed)
    np.random.seed(training_seed)
    torch.manual_seed(training_seed)
    device = select_device(str(configuration["device"]))
    try:
        coverage_acceptance = load_json(coverage_acceptance_path)
        authorization_scope = coverage_acceptance.get("authorization_scope")
        rf10 = authorization_scope == RF10_SCOPE
        if (
            coverage_acceptance.get("schema") != 1
            or coverage_acceptance.get("phase") not in ("NR4-E", "RF6-A", "RF7-A", "RF8-A", "RF9-C/D", "RF10-C")
            or coverage_acceptance.get("status") != "accepted"
            or coverage_acceptance.get("model_training_authorized") is not True
            or authorization_scope not in (INITIAL_STRUCTURAL_SCOPE, RF6_SCOPE, RF7_SCOPE, RF8_SCOPE, RF9_SCOPE, RF10_SCOPE)
            or coverage_acceptance.get("sealed_test_pixels_opened") is not False
        ):
            raise ValueError("controlled fit requires an accepted sealed corpus authorization")
        coverage_root = coverage_acceptance_path.parent
        for path_key, digest_key in (
            ("coverage", "coverage_sha256"),
            ("coverage_markdown", "coverage_markdown_sha256"),
            ("environment", "environment_sha256"),
        ):
            authorized_artifact = coverage_root / str(coverage_acceptance[path_key])
            if not authorized_artifact.is_file() or sha256_file(authorized_artifact) != coverage_acceptance[digest_key]:
                raise ValueError(f"NR4-E authorization artifact drifted: {authorized_artifact}")
        authorized_sources = coverage_acceptance.get("tool_sources")
        if not isinstance(authorized_sources, list) or not authorized_sources:
            raise ValueError("NR4-E authorization has no immutable tool-source evidence")
        for source in authorized_sources:
            snapshot = coverage_root / str(source["snapshot_path"])
            if (
                not snapshot.is_file()
                or snapshot.stat().st_size != int(source["bytes"])
                or sha256_file(snapshot) != source["snapshot_sha256"]
                or source["repository_sha256"] != source["snapshot_sha256"]
            ):
                raise ValueError(f"NR4-E tool-source snapshot drifted: {snapshot}")
        configuration_snapshot = output / "configuration.json"
        configuration_snapshot.write_bytes(configuration_path.read_bytes())
        dataset = TitleCorpusDataset(corpus, ("overfit",))
        atomic_json(output / "dataset" / "dataset.json", dataset.specification.json())
        dataset_sha256 = sha256_file(output / "dataset" / "dataset.json")
        if coverage_acceptance.get("corpus_manifest_sha256") != dataset.specification.corpus_manifest_sha256:
            raise ValueError("NR4-E authorization does not name this exact corpus manifest")
        coverage_snapshot = output / "dataset" / "coverage-acceptance.json"
        coverage_snapshot.write_bytes(coverage_acceptance_path.read_bytes())
        model_config = SpatialTitleRendererConfig(**configuration["model"])
        loss_config = ReconstructionLossConfig(**configuration.get("loss", {}))
        model = create_spatial_model(
            model_config,
            semantic_categories=len(dataset.specification.semantic_vocabulary),
            instance_categories=len(dataset.specification.instance_vocabulary),
            initialization_seed=initialization_seed,
        )
        parameter_count = sum(parameter.numel() for parameter in model.parameters())
        initializer = save_checkpoint(
            output / "checkpoints" / "initializer.pt",
            kind="random_initializer",
            model=model,
            model_configuration=model_config.json(),
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
        initializer_ancestor = {"path": initializer["path"], "sha256": initializer["sha256"], "kind": initializer["kind"]}
        model = model.to(device)
        optimizer_config = configuration["optimizer"]
        optimizer = torch.optim.AdamW(
            model.parameters(),
            lr=float(optimizer_config["learning_rate"]),
            weight_decay=float(optimizer_config["weight_decay"]),
        )
        scheduler_config = configuration["scheduler"]
        if scheduler_config.get("name") != "CosineAnnealingLR":
                raise ValueError("controlled fit owns only the declared CosineAnnealingLR recipe")
        scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
            optimizer,
            T_max=int(configuration["epochs"]),
            eta_min=float(scheduler_config["minimum_learning_rate"]),
        )
        generator = torch.Generator().manual_seed(training_seed)
        loader = DataLoader(
            dataset,
            batch_size=int(configuration["batch_size"]),
            shuffle=True,
            generator=generator,
            num_workers=0,
        )
        history: list[dict[str, float | int]] = []
        selected_epoch = 0
        selected_loss = float("inf")
        selected_state = copy.deepcopy(model.state_dict())
        selected_optimizer_state = copy.deepcopy(optimizer.state_dict())
        selected_scheduler_state = copy.deepcopy(scheduler.state_dict())
        training_started = time.perf_counter()
        for epoch in range(1, int(configuration["epochs"]) + 1):
            model.train()
            accumulators: dict[str, float] = {}
            batches = 0
            epoch_started = time.perf_counter()
            for batch in loader:
                continuous = batch["continuous"].to(device)
                semantic = batch["semantic"].to(device)
                instance = batch["instance"].to(device)
                controls = batch["global_controls"].to(device)
                target = batch["target"].to(device)
                target_coverage = batch["target_coverage"].to(device)
                optimizer.zero_grad(set_to_none=True)
                result = model(continuous, semantic, instance, controls)
                loss, terms = loss_terms(
                    result,
                    target,
                    semantic,
                    instance,
                    target_coverage,
                    loss_config,
                )
                loss.backward()
                optimizer.step()
                accumulators["loss"] = accumulators.get("loss", 0.0) + float(loss.detach())
                for name, value in terms.items():
                    accumulators[name] = accumulators.get(name, 0.0) + value
                batches += 1
            sync(device)
            record: dict[str, float | int] = {
                "epoch": epoch,
                **{name: value / batches for name, value in accumulators.items()},
                "duration_ms": (time.perf_counter() - epoch_started) * 1000.0,
                "learning_rate": float(optimizer.param_groups[0]["lr"]),
            }
            history.append(record)
            scheduler.step()
            if float(record["loss"]) < selected_loss:
                selected_loss = float(record["loss"])
                selected_epoch = epoch
                selected_state = copy.deepcopy(model.state_dict())
                selected_optimizer_state = copy.deepcopy(optimizer.state_dict())
                selected_scheduler_state = copy.deepcopy(scheduler.state_dict())
            if epoch == 1 or epoch % int(configuration["log_every_epochs"]) == 0 or epoch == int(configuration["epochs"]):
                print(f"epoch={epoch} loss={record['loss']:.8f} duration_ms={record['duration_ms']:.2f}", flush=True)
        training_duration_ms = (time.perf_counter() - training_started) * 1000.0
        model.load_state_dict(selected_state)
        optimizer.load_state_dict(selected_optimizer_state)
        scheduler.load_state_dict(selected_scheduler_state)
        checkpoint = save_checkpoint(
            output / "checkpoints" / "controlled-overfit.pt",
            kind="title_trained_checkpoint",
            model=model,
            model_configuration=model_config.json(),
            dataset_sha256=dataset_sha256,
            initialization_seed=initialization_seed,
            training_seed=training_seed,
            epoch=selected_epoch,
            optimizer=optimizer,
            scheduler=scheduler,
            ancestors=[initializer_ancestor],
            tensor_origin=f"title_checkpoint:{initializer['sha256']}",
        )
        checkpoint_audit = audit_checkpoint(Path(checkpoint["path"]), output / "checkpoints" / "checkpoint-audit.json")
        evaluation_loader = DataLoader(dataset, batch_size=1, shuffle=False, num_workers=0)
        evaluation = evaluate(model, evaluation_loader, device, output / "evaluation" / "samples")
        sample_sheets = sorted((output / "evaluation" / "samples").glob("*.png"))
        if len(sample_sheets) != len(dataset):
            raise ValueError("controlled-fit visual evidence is not complete")
        overview_name = "rf10-d-controlled-overfit-overview.png" if rf10 else "nr5-b-overfit-overview.png"
        overview_path = output / "evaluation" / overview_name
        overview_sheet(overview_path, sample_sheets)
        best_baseline = min(BASELINES, key=lambda name: evaluation["metrics"][name]["linear_hdr_mae"])
        model_metrics = evaluation["metrics"]["model"]
        baseline_metrics = evaluation["metrics"][best_baseline]
        gate_checks = {
            "optimization_descended": float(history[-1]["loss"]) < float(history[0]["loss"]),
            "linear_hdr_beats_best_deterministic_resize": model_metrics["linear_hdr_mae"] < baseline_metrics["linear_hdr_mae"],
            "semantic_boundary_beats_best_deterministic_resize": model_metrics["semantic_boundary_mae"] < baseline_metrics["semantic_boundary_mae"],
            "instance_boundary_beats_best_deterministic_resize": model_metrics["instance_boundary_mae"] < baseline_metrics["instance_boundary_mae"],
            "all_metrics_finite": all(
                np.isfinite(value)
                for owner in evaluation["metrics"].values()
                for value in owner.values()
            ),
            "test_pixels_opened": False,
        }
        evaluation_record = {
            "schema": 1,
            "stage": "RF10-D" if rf10 else "NR5-B",
            "split": "overfit",
            "best_deterministic_baseline": best_baseline,
            "evaluation": evaluation,
            "gate_checks": gate_checks,
            "automated_gate_passed": all(value for name, value in gate_checks.items() if name != "test_pixels_opened")
            and gate_checks["test_pixels_opened"] is False,
            "visual_evidence": {
                "complete_frame_sheets": len(sample_sheets),
                "overview": overview_name,
                "overview_sha256": sha256_file(overview_path),
                "training_eligible": False,
            },
        }
        evaluation_path = output / "evaluation" / "evaluation.json"
        atomic_json(evaluation_path, evaluation_record)

        model_cpu = copy.deepcopy(model).cpu().eval()
        sample = dataset[0]
        trace_inputs = (
            sample["continuous"].unsqueeze(0),
            sample["semantic"].unsqueeze(0),
            sample["instance"].unsqueeze(0),
            sample["global_controls"].unsqueeze(0),
        )
        with torch.inference_mode():
            expected = model_cpu(*trace_inputs)
            traced = torch.jit.trace(model_cpu, trace_inputs, strict=True)
            export_path = output / "export" / "model-torchscript.pt"
            export_path.parent.mkdir(parents=True, exist_ok=True)
            traced.save(str(export_path))
            loaded = torch.jit.load(str(export_path)).eval()
            actual = loaded(*trace_inputs)
            maximum_error = float((expected - actual).abs().max())
            mean_error = float((expected - actual).abs().mean())
        export = {
            "schema": 1,
            "format": "torchscript_trace_candidate_not_runtime_bundle",
            "path": str(export_path),
            "bytes": export_path.stat().st_size,
            "sha256": sha256_file(export_path),
            "mean_absolute_agreement": mean_error,
            "maximum_absolute_agreement": maximum_error,
        }
        export_manifest_path = output / "export" / "export.json"
        atomic_json(export_manifest_path, export)
        environment = package_environment(device)
        environment_path = output / "environment" / "environment.json"
        atomic_json(environment_path, environment)
        source_files = [
            Path(__file__).resolve(),
            Path(__file__).with_name("__init__.py"),
            Path(__file__).with_name("contracts.py"),
            Path(__file__).with_name("io.py"),
            Path(__file__).with_name("dataset.py"),
            Path(__file__).with_name("artifacts.py"),
            Path(__file__).with_name("metrics.py"),
            Path(__file__).with_name("models") / "__init__.py",
            Path(__file__).with_name("models") / "spatial.py",
        ]
        source_snapshot_root = output / "source" / "tools"
        source_records = []
        for path in source_files:
            relative = path.relative_to(repository)
            snapshot = source_snapshot_root / relative
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, snapshot)
            source_records.append(
                {
                    "repository_path": str(relative),
                    "repository_sha256": sha256_file(path),
                    "snapshot_path": str(snapshot.relative_to(output)),
                    "snapshot_sha256": sha256_file(snapshot),
                    "bytes": snapshot.stat().st_size,
                }
            )
        run_phase = "RF10-D" if rf10 else "NR5-B"
        run_experiment = "RF10" if rf10 else "NR-0005"
        run = {
            "schema": 1,
            "experiment": run_experiment,
            "phase": run_phase,
            "status": "pending_visual_review" if evaluation_record["automated_gate_passed"] else "automated_gate_failed",
            "configuration": "configuration.json",
            "configuration_sha256": sha256_file(configuration_snapshot),
            "repository": repository_record(repository),
            "dataset": "dataset/dataset.json",
            "dataset_sha256": dataset_sha256,
            "coverage_acceptance": "dataset/coverage-acceptance.json",
            "coverage_acceptance_sha256": sha256_file(coverage_snapshot),
            "coverage_acceptance_source": str(coverage_acceptance_path),
            "parameter_count": parameter_count,
            "initializer": initializer,
            "checkpoint": checkpoint,
            "checkpoint_audit": checkpoint_audit,
            "evaluation": "evaluation/evaluation.json",
            "evaluation_sha256": sha256_file(evaluation_path),
            "export": "export/export.json",
            "export_manifest_sha256": sha256_file(export_manifest_path),
            "environment": "environment/environment.json",
            "environment_sha256": sha256_file(environment_path),
            "training_duration_ms": training_duration_ms,
            "selected_epoch": selected_epoch,
            "selected_loss": selected_loss,
            "history": history,
            "tool_sources": source_records,
            "learned_origin": "declared random initialization followed only by title-corpus optimization",
            "external_pretrained_weights": False,
            "test_pixels_opened": False,
            "promotion_eligible": False,
        }
        atomic_json(output / "run.json", run)
        atomic_json(
            output / "conclusion.pending.json",
            {
                "schema": 1,
                "phase": run_phase,
                "status": "pending_agent_visual_review" if evaluation_record["automated_gate_passed"] else "automated_gate_failed",
                "run_sha256": sha256_file(output / "run.json"),
                "automated_gate_passed": evaluation_record["automated_gate_passed"],
                "promotion_authorized": False,
            },
        )
    except Exception as error:
        atomic_json(output / "failure.json", {"schema": 1, "phase": "RF10-D", "status": "failed", "error": str(error)})
        raise
    print(
        f"{'RF10_D' if rf10 else 'NR5_B'}_TRAIN_COMPLETE status={run['status']} parameters={parameter_count} "
        f"model_mae={model_metrics['linear_hdr_mae']:.8f} baseline={best_baseline} "
        f"baseline_mae={baseline_metrics['linear_hdr_mae']:.8f} output={output}"
    )


if __name__ == "__main__":
    main()
