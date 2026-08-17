#!/usr/bin/env python3
"""Execute RF9 coverage, ablation, reconstruction, selection, and conclusion."""

from __future__ import annotations

import argparse
import copy
import os
import subprocess
import sys
from pathlib import Path

from title_renderer.io import atomic_json, load_json, sha256_file


FOUNDATION_CONFIGURATIONS = (
    "baseline-no-palette",
    "baseline-full",
    "learned-pyramid",
)
DERIVED_CONFIGURATIONS = (
    "capacity-context",
    "capacity-output-depth",
    "detail-sampling",
)


def run(command: list[str], *, repo: Path, log: Path, expect_success: bool = True) -> None:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=repo, stdout=output, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != expect_success:
        raise subprocess.CalledProcessError(result.returncode, command)


def complete_run(root: Path) -> bool:
    return (root / "run.json").is_file() and (root / "selection.json").is_file()


def complete_selection(root: Path) -> bool:
    path = root / "selection.json"
    return path.is_file() and load_json(path).get("status") == "selected_pending_sealed_test"


def quarantine_partial(root: Path, campaign: Path, reason: str = "interrupted-before-accepted-reconstruction") -> None:
    if not root.exists():
        return
    rejected = campaign / "rejected" / f"{root.name}-{reason}"
    if rejected.exists():
        raise ValueError(f"RF9 rejected-run evidence already exists: {rejected}")
    rejected.parent.mkdir(parents=True, exist_ok=True)
    root.rename(rejected)


def validation_metrics(root: Path) -> dict:
    run_record = load_json(root / "run.json")
    return load_json(root / run_record["validation"])["evaluation"]["metrics"]["model"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    corpus = args.corpus.resolve()
    repo = args.repository.resolve()
    root = args.output.resolve()
    if root.exists() and not args.resume:
        raise ValueError(f"RF9 campaign root must be absent: {root}")
    if not root.exists():
        root.mkdir(parents=True)
    configuration_root = repo / "experiments/neural-rendering/rf9-spatial-quality-expansion"
    module_root = repo / "tools/neural-rendering"
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(module_root)
    # subprocess.run inherits this explicitly through the current process.
    os.environ.update(environment)
    campaign_path = root / "campaign.json"
    corpus_digest = sha256_file(corpus / "corpus.json")
    if campaign_path.is_file():
        campaign = load_json(campaign_path)
        if not args.resume or campaign.get("corpus_manifest_sha256") != corpus_digest:
            raise ValueError("RF9 resume received a different campaign or corpus")
        if campaign.get("status") in ("pending_implementing_agent_visual_review", "complete"):
            print(f"RF9_CAMPAIGN_ALREADY_COMPLETE selected={campaign.get('selected_run')} root={root}")
            return
    else:
        atomic_json(campaign_path, {
            "schema": 1,
            "phase": "RF9-C/H",
            "status": "partial",
            "corpus": str(corpus),
            "corpus_manifest_sha256": corpus_digest,
            "configurations": list(FOUNDATION_CONFIGURATIONS + DERIVED_CONFIGURATIONS),
            "sealed_test_opened": False,
            "trial_promoted": False,
        })

    coverage = root / "coverage"
    if not (coverage / "acceptance.json").is_file():
        run(
            [sys.executable, str(module_root / "title_renderer/coverage.py"), "--corpus", str(corpus), "--output", str(coverage), "--repository", str(repo), "--product-approval", "rf9_a_b_implementing_agent_target_audit_accepted_2026_08_12"],
            repo=repo,
            log=root / "logs/coverage.log",
        )
    authorization = coverage / "acceptance.json"
    runs = []
    for name in FOUNDATION_CONFIGURATIONS:
        destination = root / "runs" / name
        if not complete_run(destination):
            quarantine_partial(destination, root)
            run(
                [sys.executable, str(module_root / "title_renderer/train_held_out.py"), "--corpus", str(corpus), "--authorization", str(authorization), "--configuration", str(configuration_root / f"{name}.json"), "--repository", str(repo), "--output", str(destination)],
                repo=repo,
                log=root / f"logs/train-{name}.log",
            )
        runs.append(destination)

    full = runs[1]
    pyramid = runs[2]
    full_metrics = validation_metrics(full)
    pyramid_metrics = validation_metrics(pyramid)
    pyramid_accepted = (
        pyramid_metrics["spatial_quality_score"] < full_metrics["spatial_quality_score"]
        and pyramid_metrics["laplacian_mae"] < full_metrics["laplacian_mae"]
    )
    accepted_reconstruction = pyramid if pyramid_accepted else full
    accepted_configuration = load_json(accepted_reconstruction / "configuration.json")
    derived_root = root / "configurations"
    for name in DERIVED_CONFIGURATIONS:
        derived = copy.deepcopy(accepted_configuration)
        derived["initialization_seed"] = 2026081303
        derived["training_seed"] = 2026081304
        if name == "capacity-context":
            derived["experiment"] = "RF9-F-capacity-context"
            derived["model"]["name"] = "rf9_capacity_context"
            derived["model"]["features"] += 16
        elif name == "capacity-output-depth":
            derived["experiment"] = "RF9-F-capacity-output-depth"
            derived["model"]["name"] = "rf9_capacity_output_depth"
            derived["model"]["output_blocks"] += 2
        else:
            derived["experiment"] = "RF9-F-sampling"
            derived["model"]["name"] = "rf9_detail_sampling"
            derived["loss"]["detail_focus"] = 0.75
        configuration = derived_root / f"{name}.json"
        atomic_json(configuration, derived)
        destination = root / "runs" / name
        if not complete_run(destination):
            quarantine_partial(destination, root)
            run(
                [sys.executable, str(module_root / "title_renderer/train_held_out.py"), "--corpus", str(corpus), "--authorization", str(authorization), "--configuration", str(configuration), "--repository", str(repo), "--output", str(destination)],
                repo=repo,
                log=root / f"logs/train-{name}.log",
            )
        runs.append(destination)

    pre_detail = root / "selection-pre-detail"
    if not complete_selection(pre_detail):
        quarantine_partial(pre_detail, root, "interrupted-selection")
        command = [sys.executable, str(module_root / "title_renderer/rf9_select.py"), "--output", str(pre_detail)]
        for candidate in runs:
            command.extend(("--run", str(candidate)))
        run(command, repo=repo, log=root / "logs/selection-pre-detail.log")
    selection = load_json(pre_detail / "selection.json")
    if selection["status"] != "selected_pending_sealed_test":
        raise ValueError("RF9 structural selection failed")

    if selection["detail_phase"]["authorized"]:
        structural_root = Path(selection["selected"]["root"])
        detail_configuration = copy.deepcopy(load_json(structural_root / "configuration.json"))
        detail_configuration["experiment"] = "RF9-G"
        detail_configuration["initialization_seed"] = 2026081307
        detail_configuration["training_seed"] = 2026081308
        detail_configuration["model"]["name"] = "rf9_detail_residual"
        detail_configuration["model"]["detail_residual"] = True
        detail_configuration["loss"]["detail_focus"] = max(
            0.75,
            float(detail_configuration["loss"].get("detail_focus", 0.0)),
        )
        detail_configuration["loss"]["structural_supervision"] = 0.5
        detail_configuration_path = root / "configurations/detail-residual.json"
        atomic_json(detail_configuration_path, detail_configuration)
        detail = root / "runs/detail-residual"
        if not complete_run(detail):
            quarantine_partial(detail, root, "interrupted-detail-training")
            run(
                [sys.executable, str(module_root / "title_renderer/train_held_out.py"), "--corpus", str(corpus), "--authorization", str(authorization), "--configuration", str(detail_configuration_path), "--repository", str(repo), "--output", str(detail)],
                repo=repo,
                log=root / "logs/train-detail-residual.log",
            )
        runs.append(detail)

    final_selection = root / "selection"
    if not complete_selection(final_selection):
        quarantine_partial(final_selection, root, "interrupted-selection")
        command = [sys.executable, str(module_root / "title_renderer/rf9_select.py"), "--output", str(final_selection)]
        for candidate in runs:
            command.extend(("--run", str(candidate)))
        run(command, repo=repo, log=root / "logs/selection.log")
    selection_path = final_selection / "selection.json"
    selected = Path(load_json(selection_path)["selected"]["root"])

    evaluate = str(module_root / "title_renderer/evaluate_selected.py")
    test_opening = selected / "test-opening.json"
    if not test_opening.is_file() or load_json(test_opening).get("status") != "complete":
        run([sys.executable, evaluate, "--run", str(selected), "--corpus", str(corpus), "--split", "test", "--campaign-selection", str(selection_path)], repo=repo, log=root / "logs/test.log")
    reopen_rejection = selected / "test-reopen-rejection.json"
    if not reopen_rejection.is_file():
        run([sys.executable, evaluate, "--run", str(selected), "--corpus", str(corpus), "--split", "test", "--campaign-selection", str(selection_path)], repo=repo, log=root / "logs/test-reopen-rejection.log", expect_success=False)
    stress_evaluation = selected / "stress-evaluation.json"
    if not stress_evaluation.is_file() or load_json(stress_evaluation).get("status") != "complete":
        run([sys.executable, evaluate, "--run", str(selected), "--corpus", str(corpus), "--split", "stress", "--campaign-selection", str(selection_path)], repo=repo, log=root / "logs/stress.log")
    atomic_json(campaign_path, {
        "schema": 1,
        "phase": "RF9-C/H",
        "status": "pending_implementing_agent_visual_review",
        "corpus": str(corpus),
        "corpus_manifest_sha256": sha256_file(corpus / "corpus.json"),
        "coverage_authorization": str(authorization),
        "selection": str(selection_path),
        "selection_sha256": sha256_file(selection_path),
        "selected_run": str(selected),
        "selected_run_sha256": sha256_file(selected / "run.json"),
        "sealed_test_opened": True,
        "sealed_test_reopen_rejected": True,
        "stress_evaluated": True,
        "trial_promoted": False,
        "product_owner_review": "pending",
    })
    print(f"RF9_CAMPAIGN_EVIDENCE_COMPLETE selected={selected} root={root}")


if __name__ == "__main__":
    main()
