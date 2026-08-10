#!/usr/bin/env python3
"""Create synchronized NR4-C native source/target/alignment contact sheets."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

from nr4_common import artifact, atomic_json, create_absent, load_json, read_ppm
from sequence_contract import SEGMENTS, SAMPLES_PER_SEGMENT


def ppm_image(path: Path) -> Image.Image:
    width, height, pixels = read_ppm(path)
    return Image.frombytes("RGB", (width, height), pixels)


def labeled(
    image: Image.Image,
    label: str,
    extent: tuple[int, int],
    resampler: Image.Resampling = Image.Resampling.NEAREST,
) -> Image.Image:
    canvas = Image.new("RGB", (extent[0], extent[1] + 30), (20, 22, 26))
    if image.size == extent:
        content = image.convert("RGB")
    else:
        content = image.convert("RGB").resize(extent, resampler)
    canvas.paste(content, (0, 30))
    ImageDraw.Draw(canvas).text((9, 8), label, fill=(238, 240, 244))
    return canvas


def frame_images(run_root: Path, frame: dict) -> dict[str, Image.Image]:
    capture_path = run_root / frame["capture_frame"]
    capture = load_json(capture_path)
    capture_root = capture_path.parent.parent
    target_root = run_root / frame["target_root"]
    alignment_root = run_root / frame["alignment_root"]
    return {
        "cheap": ppm_image(
            capture_root
            / next(
                channel for channel in capture["channels"] if channel["name"] == "appearance"
            )["debug_path"]
        ),
        "target": Image.open(target_root / "target-display.png").convert("RGB"),
        "source_identity": ppm_image(
            capture_root
            / next(
                channel for channel in capture["channels"] if channel["name"] == "instance"
            )["debug_path"]
        ),
        "alignment": ppm_image(alignment_root / "identity-alignment.ppm"),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True, type=Path)
    parser.add_argument("--sequence", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    run_root = args.run_root.resolve()
    sequence_path = args.sequence.resolve()
    output = create_absent(args.output.resolve(), "NR4-C report root")
    sequence = load_json(sequence_path)
    frames = sequence["frames"]
    if len(frames) != len(SEGMENTS) * SAMPLES_PER_SEGMENT:
        raise ValueError("NR4-C report received an unexpected frame count")

    artifacts = []
    overview_cell = (400, 225)
    overview = Image.new(
        "RGB",
        (overview_cell[0] * SAMPLES_PER_SEGMENT * 2, (overview_cell[1] + 30) * len(SEGMENTS)),
        (12, 14, 18),
    )
    for segment_index, segment in enumerate(SEGMENTS):
        detail_cell = (400, 225)
        detail = Image.new(
            "RGB",
            (detail_cell[0] * SAMPLES_PER_SEGMENT, (detail_cell[1] + 30) * 4),
            (12, 14, 18),
        )
        for sample_index in range(SAMPLES_PER_SEGMENT):
            frame = frames[segment_index * SAMPLES_PER_SEGMENT + sample_index]
            images = frame_images(run_root, frame)
            cheap = labeled(
                images["cheap"], f"{segment} s{sample_index} cheap", overview_cell
            )
            target = labeled(
                images["target"], f"{segment} s{sample_index} target", overview_cell
            )
            overview.paste(
                cheap,
                (
                    sample_index * overview_cell[0] * 2,
                    segment_index * (overview_cell[1] + 30),
                ),
            )
            overview.paste(
                target,
                (
                    sample_index * overview_cell[0] * 2 + overview_cell[0],
                    segment_index * (overview_cell[1] + 30),
                ),
            )
            for row, name in enumerate(("cheap", "target", "source_identity", "alignment")):
                detail.paste(
                    labeled(images[name], f"s{sample_index} {name}", detail_cell),
                    (sample_index * detail_cell[0], row * (detail_cell[1] + 30)),
                )
        detail_path = output / f"segment-{segment_index:02d}-{segment}.png"
        detail.save(detail_path)
        artifacts.append(artifact(detail_path, output))
    overview_path = output / "nr4-c-native-sequence-review.png"
    overview.save(overview_path)
    artifacts.insert(0, artifact(overview_path, output))
    manifest = {
        "schema": 1,
        "status": "complete",
        "phase": "NR4-C",
        "sequence_manifest": str(sequence_path),
        "frame_count": len(frames),
        "segments": list(SEGMENTS),
        "layout": "UI-only overview: six causal rows, three samples, 160x90 appearance nearest-zoomed to 400x225 beside the direct native 400x225 target; detail: appearance, target, source identity, alignment",
        "training_material_policy": "reports and resized UI cells are excluded; only native 160x90 captured channels and direct native 400x225 target artifacts are eligible",
        "artifacts": artifacts,
    }
    atomic_json(output / "report.json", manifest)
    print(output / "report.json")


if __name__ == "__main__":
    main()
