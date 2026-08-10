#!/usr/bin/env python3
"""Read-only integrity inspector for NR5-A/B external runs."""

from __future__ import annotations

import argparse
from pathlib import Path

from title_renderer.io import load_json, sha256_file


def inspect(root: Path) -> dict:
    root = root.resolve()
    run_path = root / "run.json"
    run = load_json(run_path)
    if run.get("schema") != 1 or run.get("experiment") != "NR-0005":
        raise ValueError("unsupported NR-0005 run")
    if run.get("test_pixels_opened") is not False or run.get("external_pretrained_weights") is not False:
        raise ValueError("NR-0005 run violated test/origin policy")
    for path_key, digest_key in (
        ("configuration", "configuration_sha256"),
        ("dataset", "dataset_sha256"),
        ("coverage_acceptance", "coverage_acceptance_sha256"),
        ("evaluation", "evaluation_sha256"),
        ("export", "export_manifest_sha256"),
        ("environment", "environment_sha256"),
    ):
        path = root / run[path_key]
        if not path.is_file():
            raise ValueError(f"NR-0005 run artifact is missing: {path}")
        if digest_key is not None and sha256_file(path) != run[digest_key]:
            raise ValueError(f"NR-0005 run artifact digest drifted: {path}")
    authorization = load_json(root / run["coverage_acceptance"])
    dataset = load_json(root / run["dataset"])
    if (
        authorization.get("status") != "accepted"
        or authorization.get("model_training_authorized") is not True
        or authorization.get("authorization_scope")
        != "NR5-A framework and NR5-B controlled spatial overfit"
        or authorization.get("sealed_test_pixels_opened") is not False
        or authorization.get("corpus_manifest_sha256") != dataset.get("corpus_manifest_sha256")
    ):
        raise ValueError("NR-0005 coverage authorization is invalid")
    tool_sources = run.get("tool_sources")
    if not isinstance(tool_sources, list) or not tool_sources:
        raise ValueError("NR-0005 run has no immutable tool-source evidence")
    for source in tool_sources:
        snapshot = root / source["snapshot_path"]
        if (
            not snapshot.is_file()
            or snapshot.stat().st_size != source["bytes"]
            or sha256_file(snapshot) != source["snapshot_sha256"]
            or source["repository_sha256"] != source["snapshot_sha256"]
        ):
            raise ValueError(f"NR-0005 tool-source snapshot drifted: {snapshot}")
    for name in ("initializer", "checkpoint"):
        artifact = run[name]
        path = Path(artifact["path"])
        if path.parent.parent.resolve() != root.resolve():
            raise ValueError(f"NR-0005 checkpoint escaped its run: {path}")
        if not path.is_file() or path.stat().st_size != artifact["bytes"] or sha256_file(path) != artifact["sha256"]:
            raise ValueError(f"NR-0005 checkpoint drifted: {path}")
    evaluation = load_json(root / run["evaluation"])
    visual = evaluation.get("visual_evidence")
    if not isinstance(visual, dict) or visual.get("complete_frame_sheets") != evaluation["evaluation"]["frames"]:
        raise ValueError("NR-0005 visual evidence is incomplete")
    overview = root / "evaluation" / visual["overview"]
    if not overview.is_file() or sha256_file(overview) != visual["overview_sha256"]:
        raise ValueError("NR-0005 overview evidence drifted")
    export = load_json(root / run["export"])
    export_path = Path(export["path"])
    if not export_path.is_file() or export_path.stat().st_size != export["bytes"] or sha256_file(export_path) != export["sha256"]:
        raise ValueError("NR-0005 export drifted")
    pending = load_json(root / "conclusion.pending.json")
    if pending["run_sha256"] != sha256_file(run_path):
        raise ValueError("NR-0005 pending conclusion lost run identity")
    conclusion = None
    if (root / "conclusion.json").is_file():
        conclusion = load_json(root / "conclusion.json")
        if conclusion["run_sha256"] != sha256_file(run_path):
            raise ValueError("NR-0005 final conclusion lost run identity")
    return {
        "root": str(root),
        "phase": run["phase"],
        "status": conclusion["status"] if conclusion else pending["status"],
        "parameters": run["parameter_count"],
        "automated_gate_passed": evaluation["automated_gate_passed"],
        "model_mae": evaluation["evaluation"]["metrics"]["model"]["linear_hdr_mae"],
        "export_maximum_error": export["maximum_absolute_agreement"],
        "test_pixels_opened": False,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    result = inspect(args.root)
    print(
        f"NR5_RUN_INSPECT_PASS phase={result['phase']} status={result['status']} "
        f"parameters={result['parameters']} model_mae={result['model_mae']:.8f} "
        f"export_max_error={result['export_maximum_error']:.9f} root={result['root']}"
    )


if __name__ == "__main__":
    main()
