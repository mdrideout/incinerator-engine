#!/usr/bin/env python3
"""Freeze RF8 failure evidence and audit native RF9 target readiness."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import Imath
import numpy as np
import OpenEXR
from PIL import Image, ImageDraw

from title_renderer.io import atomic_json, create_absent_absolute, load_json, sha256_file


RANK_METRICS = (
    "spatial_quality_score",
    "gradient_mae",
    "high_frequency_mae",
    "laplacian_mae",
    "local_contrast_mae",
    "semantic_boundary_mae",
    "instance_boundary_mae",
    "chroma_mae",
)


def exr_rgb(path: Path) -> np.ndarray:
    source = OpenEXR.InputFile(str(path))
    try:
        header = source.header()
        window = header["dataWindow"]
        width = int(window.max.x - window.min.x + 1)
        height = int(window.max.y - window.min.y + 1)
        pixel_type = Imath.PixelType(Imath.PixelType.FLOAT)
        prefix = "ViewLayer.Combined."
        return np.stack(
            [
                np.frombuffer(source.channel(prefix + name, pixel_type), dtype=np.float32).reshape(height, width)
                for name in "RGB"
            ],
            axis=2,
        ).copy()
    finally:
        source.close()


def target_metrics(value: np.ndarray) -> dict[str, float]:
    horizontal = np.abs(value[:, 1:] - value[:, :-1]).mean(axis=2)
    vertical = np.abs(value[1:] - value[:-1]).mean(axis=2)
    center = value[1:-1, 1:-1]
    laplacian = np.abs(
        4.0 * center
        - value[1:-1, :-2]
        - value[1:-1, 2:]
        - value[:-2, 1:-1]
        - value[2:, 1:-1]
    ).mean(axis=2)
    return {
        "horizontal_gradient_mean": float(horizontal.mean()),
        "vertical_gradient_mean": float(vertical.mean()),
        "gradient_p99": float(np.percentile(np.concatenate((horizontal.ravel(), vertical.ravel())), 99)),
        "laplacian_mean": float(laplacian.mean()),
        "laplacian_p99": float(np.percentile(laplacian, 99)),
        "radiance_maximum": float(value.max()),
        "nonfinite_pixels": int((~np.isfinite(value)).any(axis=2).sum()),
        "negative_pixels": int((value < 0).any(axis=2).sum()),
    }


def sample_path(run: Path, split: str, frame_id: str) -> Path:
    matches = list((run / "evaluation" / split / "samples").glob(f"*-{frame_id}.png"))
    if len(matches) != 1:
        raise ValueError(f"RF8 sample evidence is missing or ambiguous: {split}/{frame_id}")
    return matches[0]


def worst_crop(sheet: Image.Image, panel_count: int) -> tuple[int, int, int, int]:
    width = sheet.width // panel_count
    height = sheet.height - 28
    model = np.asarray(sheet.crop(((panel_count - 2) * width, 28, (panel_count - 1) * width, 28 + height)), dtype=np.int16)
    target = np.asarray(sheet.crop(((panel_count - 1) * width, 28, panel_count * width, 28 + height)), dtype=np.int16)
    error = np.abs(model - target).mean(axis=2)
    integral = np.pad(error, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    crop = 96
    sums = integral[crop:, crop:] - integral[:-crop, crop:] - integral[crop:, :-crop] + integral[:-crop, :-crop]
    y, x = np.unravel_index(np.argmax(sums), sums.shape)
    return int(x), int(y), crop, crop


def atlas_sheet(run: Path, ranked: list[dict], output: Path) -> None:
    rows = []
    for record in ranked:
        source_path = sample_path(run, record["split"], record["frame_id"])
        source = Image.open(source_path).convert("RGB")
        panel_count = source.width // 640
        x, y, width, height = worst_crop(source, panel_count)
        model = source.crop(((panel_count - 2) * 640 + x, 28 + y, (panel_count - 2) * 640 + x + width, 28 + y + height))
        target = source.crop(((panel_count - 1) * 640 + x, 28 + y, (panel_count - 1) * 640 + x + width, 28 + y + height))
        model_pixels = np.asarray(model, dtype=np.int16)
        target_pixels = np.asarray(target, dtype=np.int16)
        error = np.abs(model_pixels - target_pixels).clip(0, 255).astype(np.uint8)
        error_image = Image.fromarray(error, mode="RGB")
        scale = 3
        rows.append((record, model.resize((width * scale, height * scale), Image.Resampling.NEAREST), target.resize((width * scale, height * scale), Image.Resampling.NEAREST), error_image.resize((width * scale, height * scale), Image.Resampling.NEAREST)))
        source.close()
    row_height = 28 + 96 * 3
    sheet = Image.new("RGB", (96 * 3 * 3, row_height * len(rows)), "#10151d")
    draw = ImageDraw.Draw(sheet)
    for index, (record, model, target, error) in enumerate(rows):
        top = index * row_height
        draw.text((6, top + 6), f"{record['split']} {record['frame_id']} | model / target / display error", fill="white")
        for panel_index, panel in enumerate((model, target, error)):
            sheet.paste(panel, (panel_index * 96 * 3, top + 28))
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-run", required=True, type=Path)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    run = args.baseline_run.resolve()
    corpus = args.corpus.resolve()
    output = create_absent_absolute(args.output, "--output")
    if not (run / "run.json").is_file() or not (corpus / "corpus.json").is_file():
        raise ValueError("RF9 audit requires complete absolute RF8 run and corpus roots")

    ranked = []
    split_summaries = {}
    for split in ("validation", "stress"):
        evaluation_path = run / "evaluation" / split / "evaluation.json"
        evaluation = load_json(evaluation_path)["evaluation"]
        split_summaries[split] = {
            "evaluation": str(evaluation_path),
            "evaluation_sha256": sha256_file(evaluation_path),
            "model": evaluation["metrics"]["model"],
        }
        for frame in evaluation["per_frame"]:
            model = frame["metrics"]["model"]
            ranked.append(
                {
                    "split": split,
                    "frame_id": frame["frame_id"],
                    "metrics": {name: float(model[name]) for name in RANK_METRICS},
                    "likely_owner": "coverage_or_reconstruction",
                }
            )
    ranked.sort(key=lambda value: value["metrics"]["spatial_quality_score"], reverse=True)
    selected = ranked[:12]
    atlas = output / "rf9-a-failure-atlas.png"
    atlas_sheet(run, selected, atlas)

    manifest = load_json(corpus / "corpus.json")
    records = [json.loads(line) for line in (corpus / manifest["frame_index"]).read_text().splitlines() if line]
    target_records = []
    for record in records:
        if record["split"] not in {"validation", "stress"}:
            continue
        target_path = corpus / record["target"]["linear_hdr"]["path"]
        target_records.append({"frame_id": record["frame_id"], "split": record["split"], "sha256": sha256_file(target_path), "metrics": target_metrics(exr_rgb(target_path))})
    target_summary = {
        name: float(np.mean([record["metrics"][name] for record in target_records]))
        for name in ("horizontal_gradient_mean", "vertical_gradient_mean", "gradient_p99", "laplacian_mean", "laplacian_p99")
    }
    target_gate = all(record["metrics"]["nonfinite_pixels"] == 0 and record["metrics"]["negative_pixels"] == 0 for record in target_records) and target_summary["gradient_p99"] > 0 and target_summary["laplacian_p99"] > 0
    report = {
        "schema": 1,
        "phase": "RF9-A/B",
        "status": "accepted" if target_gate else "rejected",
        "sealed_test_pixels_opened": False,
        "baseline": {
            "root": str(run),
            "run_sha256": sha256_file(run / "run.json"),
            "checkpoint_sha256": sha256_file(run / "checkpoints" / "validation-selected.pt"),
            "splits": split_summaries,
        },
        "failure_atlas": {"ranked_frames": selected, "image": str(atlas), "sha256": sha256_file(atlas)},
        "target_audit": {"frames": target_records, "summary": target_summary, "gate_passed": target_gate},
        "decision": {
            "target_is_natively_detailed": target_gate,
            "primary_pressure": "coverage_then_reconstruction",
            "model_capacity_change_authorized": False,
            "rf9_coverage_work_authorized": target_gate,
        },
    }
    atomic_json(output / "audit.json", report)
    (output / "README.md").write_text(
        "# RF9-A/B Failure and Target Audit\n\n"
        f"- RF8 run: `{run}`\n"
        f"- RF8 checkpoint SHA-256: `{report['baseline']['checkpoint_sha256']}`\n"
        f"- Native target gate: **{'pass' if target_gate else 'fail'}**\n"
        "- Sealed test pixels opened: **no**\n"
        "- Disposition: expand independent coverage, resolve the controlled material-palette ambiguity, then compare learned reconstruction.\n",
        encoding="utf-8",
    )
    print(f"RF9_A_B_AUDIT status={report['status']} output={output}")


if __name__ == "__main__":
    main()
