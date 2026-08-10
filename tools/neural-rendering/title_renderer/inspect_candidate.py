#!/usr/bin/env python3
"""Read-only NR5-C/D candidate integrity and phase inspector."""

from __future__ import annotations

import argparse
from pathlib import Path

from title_renderer.io import load_json, sha256_file


def verify(root: Path, relative: str, digest: str) -> Path:
    path = root / relative
    if not path.is_file() or sha256_file(path) != digest:
        raise ValueError(f"candidate artifact drifted: {path}")
    return path


def verify_visual_evidence(root: Path, evaluation: dict) -> None:
    evidence = evaluation.get("evaluation", {}).get("visual_evidence")
    if not isinstance(evidence, dict):
        raise ValueError("candidate evaluation lacks visual evidence")
    overview = Path(evidence["overview"])
    sample_root = overview.parent / "samples"
    if not overview.is_file() or len(list(sample_root.glob("*.png"))) != evidence["frame_sheets"]:
        raise ValueError(f"candidate visual evidence is incomplete: {overview.parent}")


def inspect(root: Path) -> dict:
    root = root.resolve()
    run_path = root / "run.json"
    run = load_json(run_path)
    if run.get("schema") != 2 or run.get("phase") != "NR5-C" or run.get("external_pretrained_weights") is not False:
        raise ValueError("unsupported or foreign NR5-C candidate")
    for path_key, digest_key in (
        ("configuration", "configuration_sha256"), ("authorization", "authorization_sha256"),
        ("train_dataset", "train_dataset_sha256"), ("validation_dataset", "validation_dataset_sha256"),
        ("validation", "validation_sha256"), ("export", "export_sha256"), ("environment", "environment_sha256"),
    ):
        verify(root, run[path_key], run[digest_key])
    for source in run.get("tool_sources", []):
        snapshot = verify(root, source["snapshot_path"], source["snapshot_sha256"])
        if snapshot.stat().st_size != source["bytes"] or source["snapshot_sha256"] != source["repository_sha256"]:
            raise ValueError(f"candidate tool-source record drifted: {snapshot}")
    for artifact in (run["initializer"], run["checkpoint"]):
        path = Path(artifact["path"])
        if not path.is_file() or path.stat().st_size != artifact["bytes"] or sha256_file(path) != artifact["sha256"]:
            raise ValueError(f"candidate checkpoint drifted: {path}")
    validation = load_json(root / run["validation"])
    if validation.get("automated_gate_passed") is not True:
        raise ValueError("candidate validation gate failed")
    verify_visual_evidence(root, validation)
    result = {"phase": "NR5-C", "status": run["status"], "validation_mae": validation["evaluation"]["metrics"]["model"]["linear_hdr_mae"], "test_opened": False}
    if (root / "test-opening.json").is_file():
        opening = load_json(root / "test-opening.json")
        test_path = verify(root, opening["evaluation"], opening["evaluation_sha256"])
        test = load_json(test_path)
        guard_installed = opening.get("reopen_guard_installed") is True or opening.get("second_open_rejected") is True
        if not guard_installed or test.get("automated_gate_passed") is not True:
            raise ValueError("candidate test-opening contract failed")
        verify_visual_evidence(root, test)
        result.update({"test_opened": True, "test_mae": test["evaluation"]["metrics"]["model"]["linear_hdr_mae"]})
    if (root / "stress-evaluation.json").is_file():
        owner = load_json(root / "stress-evaluation.json")
        stress = load_json(verify(root, owner["evaluation"], owner["evaluation_sha256"]))
        if stress.get("automated_gate_passed") is not True:
            raise ValueError("candidate stress gate failed")
        verify_visual_evidence(root, stress)
        result.update({"phase": "NR5-D", "stress_mae": stress["evaluation"]["metrics"]["model"]["linear_hdr_mae"]})
    if (root / "conclusion.json").is_file():
        conclusion = load_json(root / "conclusion.json")
        rejection_path = root / "test-reopen-rejection.json"
        if (
            conclusion.get("run_sha256") != sha256_file(run_path)
            or conclusion.get("promotion_authorized") is not False
            or conclusion.get("complete_visual_review") is not True
            or conclusion.get("test_reopen_rejection_sha256") != sha256_file(rejection_path)
        ):
            raise ValueError("candidate conclusion drifted")
        rejection = load_json(rejection_path)
        if rejection.get("status") != "rejected" or rejection.get("pixels_opened_by_rejected_attempt") is not False:
            raise ValueError("candidate does not prove the single-open test contract")
        for source in conclusion.get("post_selection_tool_sources", []):
            snapshot = verify(root, source["snapshot"], source["snapshot_sha256"])
            if snapshot.stat().st_size != source["bytes"] or source["source_sha256"] != source["snapshot_sha256"]:
                raise ValueError(f"post-selection tool-source record drifted: {snapshot}")
        result["status"] = conclusion["status"]
    if (root / "nr5-d-measurements.json").is_file():
        measurements = load_json(root / "nr5-d-measurements.json")
        conclusion_path = root / "conclusion.json"
        if (
            measurements.get("conclusion_sha256") != sha256_file(conclusion_path)
            or measurements.get("promotion_authorized") is not False
            or measurements.get("export_all_stress_frames", {}).get("maximum_absolute_agreement") != 0.0
        ):
            raise ValueError("candidate supplemental measurements drifted")
        source = measurements["tool_source"]
        snapshot = verify(root, source["snapshot"], source["snapshot_sha256"])
        if snapshot.stat().st_size != source["bytes"] or source["source_sha256"] != source["snapshot_sha256"]:
            raise ValueError(f"measurement tool-source record drifted: {snapshot}")
        result["stress_export_maximum_error"] = measurements["export_all_stress_frames"]["maximum_absolute_agreement"]
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    value = inspect(args.root)
    print("NR5_CANDIDATE_INSPECT_PASS " + " ".join(f"{key}={value[key]}" for key in sorted(value)))


if __name__ == "__main__":
    main()
