#!/usr/bin/env python3
"""Select RF9 candidates from immutable validation evidence only."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from title_renderer.io import atomic_json, create_absent_absolute, load_json, sha256_file


def candidate(root: Path) -> dict:
    run = load_json(root / "run.json")
    selection = load_json(root / "selection.json")
    validation_path = root / run["validation"]
    validation = load_json(validation_path)
    configuration = load_json(root / run["configuration"])
    if (
        run.get("experiment") != "RF9"
        or run.get("test_pixels_opened") is not False
        or selection.get("test_pixels_opened") is not False
        or validation.get("automated_gate_passed") is not True
    ):
        raise ValueError(f"RF9 selection received an ineligible run: {root}")
    evaluation_metrics = validation["evaluation"]["metrics"]
    metrics = evaluation_metrics["model"]
    return {
        "root": str(root),
        "run_sha256": sha256_file(root / "run.json"),
        "checkpoint_sha256": run["checkpoint"]["sha256"],
        "configuration_sha256": sha256_file(root / run["configuration"]),
        "name": configuration["model"]["name"],
        "architecture": configuration["model"]["reconstruction"],
        "uses_material_palette": configuration["model"]["use_material_palette"],
        "detail_residual": configuration["model"]["detail_residual"],
        "detail_focus": float(configuration["loss"]["detail_focus"]),
        "parameter_count": run["parameter_count"],
        "selected_epoch": run["selected_epoch"],
        "metrics": metrics,
        "no_detail_residual_metrics": evaluation_metrics["no_detail_residual"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = create_absent_absolute(args.output, "--output")
    candidates = [candidate(path.resolve()) for path in args.run]
    by_name = {item["name"]: item for item in candidates}
    required = {
        "rf9_baseline_no_palette",
        "rf9_baseline_full",
        "rf9_learned_pyramid",
        "rf9_capacity_context",
        "rf9_capacity_output_depth",
        "rf9_detail_sampling",
    }
    missing = required - set(by_name)
    if missing:
        raise ValueError(f"RF9 selection is missing controlled candidates: {sorted(missing)}")
    no_palette = by_name["rf9_baseline_no_palette"]
    full = by_name["rf9_baseline_full"]
    pyramid = by_name["rf9_learned_pyramid"]
    capacity_context = by_name["rf9_capacity_context"]
    capacity_output_depth = by_name["rf9_capacity_output_depth"]
    sampling = by_name["rf9_detail_sampling"]
    conditioning_checks = {
        "palette_conditioning_improves_spatial_quality": full["metrics"]["spatial_quality_score"] < no_palette["metrics"]["spatial_quality_score"],
        "palette_conditioning_improves_chroma": full["metrics"]["chroma_mae"] < no_palette["metrics"]["chroma_mae"],
    }
    reconstruction_checks = {
        "learned_pyramid_improves_spatial_quality": pyramid["metrics"]["spatial_quality_score"] < full["metrics"]["spatial_quality_score"],
        "learned_pyramid_improves_laplacian": pyramid["metrics"]["laplacian_mae"] < full["metrics"]["laplacian_mae"],
    }
    accepted_reconstruction = pyramid if all(reconstruction_checks.values()) else full
    checks = conditioning_checks | reconstruction_checks | {"sealed_test_remains_closed": True}
    structural = min(
        (accepted_reconstruction, capacity_context, capacity_output_depth, sampling),
        key=lambda item: item["metrics"]["spatial_quality_score"],
    )
    detail = by_name.get("rf9_detail_residual")
    detail_checks = None
    selected = structural
    if detail is not None:
        detail_checks = {
            "detail_improves_own_structural_output": detail["metrics"]["spatial_quality_score"] < detail["no_detail_residual_metrics"]["spatial_quality_score"],
            "spatial_quality_improves": detail["metrics"]["spatial_quality_score"] < structural["metrics"]["spatial_quality_score"],
            "high_frequency_improves": detail["metrics"]["high_frequency_mae"] < structural["metrics"]["high_frequency_mae"],
            "semantic_boundary_not_degraded": detail["metrics"]["semantic_boundary_mae"] <= structural["metrics"]["semantic_boundary_mae"],
            "instance_boundary_not_degraded": detail["metrics"]["instance_boundary_mae"] <= structural["metrics"]["instance_boundary_mae"],
            "negative_radiance_not_degraded": detail["metrics"]["negative_radiance_fraction"] <= structural["metrics"]["negative_radiance_fraction"],
        }
        if all(detail_checks.values()):
            selected = detail
    accepted = all(conditioning_checks.values())
    report = {
        "schema": 1,
        "phase": "RF9-D/G",
        "status": "selected_pending_sealed_test" if accepted else "rejected",
        "candidates": candidates,
        "checks": checks,
        "conditioning_accepted": all(conditioning_checks.values()),
        "reconstruction_disposition": {
            "checks": reconstruction_checks,
            "accepted": accepted_reconstruction,
            "learned_pyramid_accepted": accepted_reconstruction is pyramid,
            "reason": "learned pyramid advances only when both spatial quality and Laplacian error improve; otherwise the simpler bilinear path remains",
        },
        "one_factor_findings": {
            "conditioning": {"without_palette": no_palette["metrics"], "with_palette": full["metrics"]},
            "reconstruction": {"bilinear": full["metrics"], "learned_pyramid": pyramid["metrics"]},
            "capacity_context": {"reference": accepted_reconstruction["metrics"], "wider_context": capacity_context["metrics"]},
            "capacity_output_depth": {"reference": accepted_reconstruction["metrics"], "deeper_native_output": capacity_output_depth["metrics"]},
            "detail_sampling": {"reference": accepted_reconstruction["metrics"], "detail_focused": sampling["metrics"]},
        },
        "structural_selection": structural,
        "detail_phase": {
            "authorized": accepted and structural["metrics"]["high_frequency_mae"] > 0,
            "reason": "selected structural candidate retains measured high-frequency target residual",
            "candidate_present": detail is not None,
            "checks": detail_checks,
            "accepted": detail is not None and detail_checks is not None and all(detail_checks.values()),
        },
        "selected": selected if accepted else None,
        "sealed_test_pixels_opened": False,
    }
    source = Path(__file__).resolve()
    snapshot = output / "source/rf9_select.py"
    snapshot.parent.mkdir(parents=True)
    shutil.copyfile(source, snapshot)
    report["tool_source"] = {
        "source": str(source),
        "source_sha256": sha256_file(source),
        "snapshot": str(snapshot.relative_to(output)),
        "snapshot_sha256": sha256_file(snapshot),
        "bytes": snapshot.stat().st_size,
    }
    atomic_json(output / "selection.json", report)
    print(f"RF9_SELECTION status={report['status']} selected={selected['name'] if accepted else 'none'} output={output}")


if __name__ == "__main__":
    main()
