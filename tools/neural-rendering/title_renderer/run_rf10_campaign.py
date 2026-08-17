#!/usr/bin/env python3
"""Execute the fresh RF10 controlled-fit, held-out, sealed-test, and stress gates."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from title_renderer.io import atomic_json, load_json, sha256_file


def run(command: list[str], *, repository: Path, log: Path, expect_success: bool = True) -> None:
    log.parent.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(repository / "tools/neural-rendering")
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(
            command,
            cwd=repository,
            env=environment,
            stdout=output,
            stderr=subprocess.STDOUT,
        )
    if (result.returncode == 0) != expect_success:
        raise subprocess.CalledProcessError(result.returncode, command)


def complete(root: Path, *names: str) -> bool:
    return all((root / name).is_file() for name in names)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--blender", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    corpus = args.corpus.resolve()
    repository = args.repository.resolve()
    output = args.output.resolve()
    if output.exists() and not args.resume:
        raise ValueError(f"RF10 campaign root must be absent: {output}")
    output.mkdir(parents=True, exist_ok=args.resume)
    manifest_path = output / "campaign.json"
    corpus_sha256 = sha256_file(corpus / "corpus.json")
    if manifest_path.exists():
        manifest = load_json(manifest_path)
        if manifest.get("corpus_manifest_sha256") != corpus_sha256:
            raise ValueError("RF10 resume received a different corpus")
        if manifest.get("status") in ("pending_technical_visual_review", "complete"):
            print(f"RF10_CAMPAIGN_ALREADY_READY root={output}")
            return
    else:
        atomic_json(manifest_path, {
            "schema": 1,
            "phase": "RF10-D/G",
            "status": "partial",
            "corpus": str(corpus),
            "corpus_manifest_sha256": corpus_sha256,
            "sealed_test_opened": False,
            "trial_promoted": False,
        })

    module = repository / "tools/neural-rendering/title_renderer"
    configuration = repository / "experiments/neural-rendering/rf10-native-720p-spatial"
    coverage = output / "coverage"
    if not (coverage / "acceptance.json").is_file():
        run([
            sys.executable, str(module / "coverage.py"),
            "--corpus", str(corpus), "--output", str(coverage),
            "--repository", str(repository),
            "--product-approval", "rf10_a_b_native_720p_target_audit_accepted_2026_08_13",
        ], repository=repository, log=output / "logs/coverage.log")
    authorization = coverage / "acceptance.json"

    controlled = output / "controlled-fit"
    if not complete(controlled, "run.json", "evaluation/evaluation.json"):
        if controlled.exists():
            raise ValueError("RF10 controlled-fit root is partial; preserve it and resume manually")
        run([
            sys.executable, str(module / "train.py"),
            "--corpus", str(corpus), "--coverage-acceptance", str(authorization),
            "--configuration", str(configuration / "controlled-overfit.json"),
            "--repository", str(repository), "--output", str(controlled),
        ], repository=repository, log=output / "logs/controlled-fit.log")
    controlled_evaluation = load_json(controlled / "evaluation/evaluation.json")
    if controlled_evaluation.get("automated_gate_passed") is not True:
        raise ValueError("RF10 controlled fit did not clear its automated gate")

    held_out = output / "held-out"
    if not complete(held_out, "run.json", "selection.json"):
        if held_out.exists():
            raise ValueError("RF10 held-out root is partial; preserve it and resume manually")
        run([
            sys.executable, str(module / "train_held_out.py"),
            "--corpus", str(corpus), "--authorization", str(authorization),
            "--configuration", str(configuration / "held-out.json"),
            "--repository", str(repository), "--output", str(held_out),
        ], repository=repository, log=output / "logs/held-out.log")
    selection = load_json(held_out / "selection.json")
    if selection.get("status") != "selected_for_single_test_open":
        raise ValueError("RF10 held-out candidate did not clear validation selection")

    post_selection_stress = output / "post-selection-stress"
    stress_acceptance_path = post_selection_stress / "acceptance.json"
    stress_acceptance = load_json(stress_acceptance_path) if stress_acceptance_path.is_file() else None
    if stress_acceptance is None or stress_acceptance.get("status") != "complete":
        run([
            sys.executable,
            str(repository / "tools/neural-rendering/targets/blender/verify_rf10_post_selection_stress.py"),
            "--base-corpus", str(corpus),
            "--selection", str(held_out / "selection.json"),
            "--validation", str(args.validation.resolve()),
            "--content-root", str(args.content_root.resolve()),
            "--repository", str(repository),
            "--blender", str(args.blender.resolve()),
            "--output", str(post_selection_stress),
        ], repository=repository, log=output / "logs/post-selection-stress.log")
    post_selection_acceptance = load_json(stress_acceptance_path)
    if post_selection_acceptance.get("status") != "complete" or post_selection_acceptance.get("stress_pixels_existed_before_selection") is not False:
        raise ValueError("RF10 post-selection stress manufacture is incomplete")
    stress_corpus = post_selection_stress / "corpus"

    evaluator = str(module / "evaluate_selected.py")
    if not (held_out / "test-opening.json").is_file():
        run([
            sys.executable, evaluator, "--run", str(held_out),
            "--corpus", str(corpus), "--split", "test",
        ], repository=repository, log=output / "logs/test.log")
    if not (held_out / "test-reopen-rejection.json").is_file():
        run([
            sys.executable, evaluator, "--run", str(held_out),
            "--corpus", str(corpus), "--split", "test",
        ], repository=repository, log=output / "logs/test-reopen-rejection.log", expect_success=False)
    if not (held_out / "stress-evaluation.json").is_file():
        run([
            sys.executable, evaluator, "--run", str(held_out),
            "--corpus", str(stress_corpus), "--split", "stress",
        ], repository=repository, log=output / "logs/stress.log")

    atomic_json(manifest_path, {
        "schema": 1,
        "phase": "RF10-D/G",
        "status": "pending_technical_visual_review",
        "corpus": str(corpus),
        "corpus_manifest_sha256": corpus_sha256,
        "coverage_authorization": str(authorization),
        "controlled_fit": str(controlled),
        "held_out": str(held_out),
        "held_out_run_sha256": sha256_file(held_out / "run.json"),
        "selection_sha256": sha256_file(held_out / "selection.json"),
        "sealed_test_opened": True,
        "sealed_test_reopen_rejected": True,
        "stress_evaluated": True,
        "post_selection_stress": str(post_selection_stress),
        "post_selection_stress_acceptance_sha256": sha256_file(post_selection_stress / "acceptance.json"),
        "stress_corpus": str(stress_corpus),
        "trial_promoted": False,
    })
    print(f"RF10_CAMPAIGN_EVIDENCE_COMPLETE candidate={held_out} root={output}")


if __name__ == "__main__":
    main()
