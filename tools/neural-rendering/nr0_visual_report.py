#!/usr/bin/env python3
"""Create a dependency-free UI-only sheet for one native input capture."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"P6\n"):
        raise ValueError(f"not a binary PPM: {path}")
    magic, dimensions, maximum, pixels = data.split(b"\n", 3)
    width, height = (int(value) for value in dimensions.split())
    if magic != b"P6" or maximum != b"255" or len(pixels) != width * height * 3:
        raise ValueError(f"invalid PPM: {path}")
    return width, height, pixels


def resize_nearest(
    source_width: int,
    source_height: int,
    pixels: bytes,
    width: int,
    height: int,
) -> bytes:
    output = bytearray(width * height * 3)
    for y in range(height):
        source_y = y * source_height // height
        for x in range(width):
            source_x = x * source_width // width
            source = (source_y * source_width + source_x) * 3
            target = (y * width + x) * 3
            output[target : target + 3] = pixels[source : source + 3]
    return bytes(output)


def paste(
    canvas: bytearray,
    canvas_width: int,
    image: bytes,
    width: int,
    height: int,
    left: int,
    top: int,
) -> None:
    for row in range(height):
        source = row * width * 3
        target = ((top + row) * canvas_width + left) * 3
        canvas[target : target + width * 3] = image[source : source + width * 3]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--frame", type=int)
    args = parser.parse_args()
    capture = args.capture.resolve()
    output = args.output.resolve()
    if output.exists():
        raise ValueError(f"output already exists: {output}")
    if output.suffix.lower() != ".ppm":
        raise ValueError("dependency-free visual reports use a .ppm output path")
    output.parent.mkdir(parents=True, exist_ok=True)
    summaries = [
        json.loads(line)
        for line in (capture / "frames.ndjson").read_text().splitlines()
        if line
    ]
    summary = next(
        (
            item
            for item in summaries
            if args.frame is None or item["presentation_frame"] == args.frame
        ),
        None,
    )
    if summary is None:
        raise ValueError("requested frame is absent")
    frame = json.loads((capture / summary["frame_manifest"]).read_text())
    cards: list[tuple[bytes, int, int]] = []
    for channel in frame["channels"]:
        width, height, pixels = read_ppm(capture / channel["debug_path"])
        cards.append((resize_nearest(width, height, pixels, 400, 225), 400, 225))
    canvas_width, canvas_height = 1200, 450
    canvas = bytearray((28, 30, 34) * (canvas_width * canvas_height))
    positions = ((0, 0), (400, 0), (800, 0), (0, 225), (400, 225), (800, 225))
    for (pixels, width, height), (left, top) in zip(cards, positions, strict=True):
        paste(canvas, canvas_width, pixels, width, height, left, top)
    output.write_bytes(f"P6\n{canvas_width} {canvas_height}\n255\n".encode() + canvas)
    metadata = output.with_suffix(".json")
    metadata.write_text(
        json.dumps(
            {
                "schema": 1,
                "frame_id": frame["frame_id"],
                "layout": [
                    "appearance",
                    "linear-depth",
                    "world-normal",
                    "motion",
                    "semantic",
                    "instance",
                ],
                "positions": positions,
                "display_only": True,
                "source_extent": frame["input_size"],
                "ui_zoom": "nearest 160x90 to 400x225; excluded from training material",
            },
            indent=2,
        )
        + "\n"
    )
    print(output)


if __name__ == "__main__":
    main()
