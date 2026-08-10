#!/usr/bin/env python3
"""Build strict native 160x90 -> 400x225 display baselines for one NR4-C pair."""

from __future__ import annotations

import argparse
import math
import time
from pathlib import Path

import PIL
from PIL import Image, ImageDraw

from nr4_common import (
    CAPTURE_SCHEMA,
    INPUT_EXTENT,
    TARGET_EXTENT,
    artifact,
    atomic_json,
    create_absent,
    load_json,
    read_ppm,
)


RESAMPLERS = {
    "nearest": Image.Resampling.NEAREST,
    "bilinear": Image.Resampling.BILINEAR,
    "bicubic": Image.Resampling.BICUBIC,
}


def ppm_image(path: Path) -> Image.Image:
    width, height, pixels = read_ppm(path)
    return Image.frombytes("RGB", (width, height), pixels)


def linear(value: int) -> float:
    encoded = value / 255.0
    return encoded / 12.92 if encoded <= 0.04045 else ((encoded + 0.055) / 1.055) ** 2.4


def metrics(candidate: Image.Image, target: Image.Image) -> dict[str, float | None]:
    if candidate.size != tuple(TARGET_EXTENT) or target.size != tuple(TARGET_EXTENT):
        raise ValueError("native baseline metrics received a foreign extent")
    squared = 0.0
    absolute = 0.0
    maximum = 0.0
    count = TARGET_EXTENT[0] * TARGET_EXTENT[1] * 3
    for left, right in zip(candidate.tobytes(), target.tobytes(), strict=True):
        delta = abs(linear(left) - linear(right))
        absolute += delta
        squared += delta * delta
        maximum = max(maximum, delta)
    mse = squared / count
    return {
        "linear_rgb_mae": absolute / count,
        "linear_rgb_rmse": math.sqrt(mse),
        "linear_rgb_psnr_db": None if mse == 0 else 10.0 * math.log10(1.0 / mse),
        "linear_rgb_max_error": maximum,
    }


def card(image: Image.Image, title: str, *, native: bool = False) -> Image.Image:
    width, height = TARGET_EXTENT
    canvas = Image.new("RGB", (width, height + 34), (19, 22, 27))
    if native:
        x = (width - image.width) // 2
        y = 34 + (height - image.height) // 2
        canvas.paste(image, (x, y))
    else:
        if image.size != (width, height):
            raise ValueError("report card would implicitly resize a non-native image")
        canvas.paste(image, (0, 34))
    ImageDraw.Draw(canvas).text((9, 9), title, fill=(240, 242, 246))
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-frame", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    capture_path = args.capture_frame.resolve()
    target_root = args.target.resolve()
    output = create_absent(args.output.resolve(), "NR4-C native baseline root")
    capture = load_json(capture_path)
    target_manifest = load_json(target_root / "target-run.json")
    if capture.get("schema") != CAPTURE_SCHEMA:
        raise ValueError(f"NR4-C baselines require capture schema {CAPTURE_SCHEMA}")
    if capture.get("input_size") != INPUT_EXTENT:
        raise ValueError("NR4-C baseline input is not native 160x90")
    if capture.get("paired_target_size") != TARGET_EXTENT:
        raise ValueError("NR4-C capture does not declare a native 400x225 target")
    if target_manifest.get("extent") != TARGET_EXTENT:
        raise ValueError("NR4-C direct target is not native 400x225")

    capture_root = capture_path.parent.parent
    appearance = next(
        channel for channel in capture["channels"] if channel["name"] == "appearance"
    )
    decode_started = time.perf_counter_ns()
    source = ppm_image(capture_root / appearance["debug_path"])
    target = Image.open(target_root / "target-display.png").convert("RGB")
    decode_ns = time.perf_counter_ns() - decode_started
    if source.size != tuple(INPUT_EXTENT) or target.size != tuple(TARGET_EXTENT):
        raise ValueError("NR4-C baseline material contains a foreign extent")

    source.save(output / "input-native-160x90.png")
    artifacts = [artifact(output / "input-native-160x90.png", output)]
    baseline_images: dict[str, Image.Image] = {}
    baseline_records = []
    for name, resampler in RESAMPLERS.items():
        started = time.perf_counter_ns()
        image = source.resize(tuple(TARGET_EXTENT), resampler)
        resize_ns = time.perf_counter_ns() - started
        path = output / f"baseline-{name}-400x225.png"
        image.save(path)
        artifacts.append(artifact(path, output))
        baseline_images[name] = image
        baseline_records.append(
            {
                "name": name,
                "extent": TARGET_EXTENT,
                "resize_ns": resize_ns,
                "display_comparison_only": True,
                "metrics": metrics(image, target),
                "artifact": artifact(path, output),
            }
        )

    cards = [
        card(source, "INPUT native 160x90 (centered, no resize)", native=True),
        card(baseline_images["nearest"], "INPUT UI zoom 2.5x nearest (not training material)"),
        card(target, "TARGET direct Cycles 400x225"),
        card(baseline_images["nearest"], "BASELINE nearest 160x90 -> 400x225"),
        card(baseline_images["bilinear"], "BASELINE bilinear 160x90 -> 400x225"),
        card(baseline_images["bicubic"], "BASELINE bicubic 160x90 -> 400x225"),
    ]
    card_width, card_height = cards[0].size
    report = Image.new("RGB", (card_width * 3, card_height * 2), (10, 12, 16))
    for index, image in enumerate(cards):
        report.paste(image, ((index % 3) * card_width, (index // 3) * card_height))
    report_path = output / "native-160x90-to-400x225-review.png"
    report.save(report_path)
    artifacts.append(artifact(report_path, output))
    atomic_json(
        output / "baselines.json",
        {
            "schema": 1,
            "status": "complete",
            "phase": "NR4-C",
            "frame_id": capture["frame_id"],
            "input_extent": INPUT_EXTENT,
            "target_extent": TARGET_EXTENT,
            "training_material": {
                "input": "capture appearance channel at native 160x90",
                "target": "direct Cycles OpenEXR at native 400x225",
                "ui_zoom_and_baselines_excluded": True,
            },
            "model_output": "absent until NR5",
            "display_metrics": "sRGB display derivatives decoded to linear RGB; not canonical HDR training loss",
            "pillow_version": PIL.__version__,
            "decode_ns": decode_ns,
            "baselines": baseline_records,
            "report": artifact(report_path, output),
            "artifacts": artifacts,
        },
    )
    print(output / "baselines.json")


if __name__ == "__main__":
    main()
