#!/usr/bin/env python3
"""Materialize one immutable Incinerator capture sequence for LTX video-to-video."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import imageio.v2 as imageio
import numpy as np
from PIL import Image

from nr_common import atomic_json, create_new_directory, load_json, sha256_file


SEQUENCE_SCHEMA = 1


def parse_extent(value: str) -> tuple[int, int]:
    try:
        width_text, height_text = value.lower().split("x", 1)
        width, height = int(width_text), int(height_text)
    except (ValueError, AttributeError) as error:
        raise argparse.ArgumentTypeError("extent must be WIDTHxHEIGHT") from error
    if width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError("extent dimensions must be positive")
    if width % 32 != 0 or height % 32 != 0:
        raise argparse.ArgumentTypeError("LTX extent dimensions must be divisible by 32")
    return width, height


def read_frame_index(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            if not line.strip():
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError(f"frame index line {line_number} is not an object")
            records.append(value)
    return records


def appearance_record(manifest: dict[str, Any]) -> dict[str, Any]:
    channels = manifest.get("channels")
    if not isinstance(channels, list):
        raise ValueError("frame manifest has no channel list")
    for channel in channels:
        if isinstance(channel, dict) and channel.get("name") == "appearance":
            return channel
    raise ValueError("frame manifest has no appearance channel")


def contact_sheet(frames: list[np.ndarray]) -> Image.Image:
    columns = min(3, len(frames))
    rows = math.ceil(len(frames) / columns)
    height, width = frames[0].shape[:2]
    sheet = Image.new("RGB", (columns * width, rows * height))
    for index, frame in enumerate(frames):
        sheet.paste(Image.fromarray(frame, mode="RGB"), ((index % columns) * width, (index // columns) * height))
    return sheet


def prepare(
    capture_root: Path,
    output_root: Path,
    start_index: int,
    frame_count: int,
    extent: tuple[int, int],
    fps: int,
) -> dict[str, Any]:
    capture_root = capture_root.resolve()
    capture = load_json(capture_root / "capture.json")
    if capture.get("schema") != 2 or capture.get("status") != "complete":
        raise ValueError("LTX input requires one complete Incinerator capture schema 2 root")
    if frame_count < 1 or (frame_count - 1) % 8 != 0:
        raise ValueError("LTX frame count must be 8N+1")
    if start_index < 0:
        raise ValueError("start index must be non-negative")
    records = read_frame_index(capture_root / str(capture["frame_index"]))
    selected = records[start_index : start_index + frame_count]
    if len(selected) != frame_count:
        raise ValueError("selected frame range exceeds the capture")

    output_root = create_new_directory(output_root, "LTX sequence output")
    frame_dir = output_root / "frames"
    frame_dir.mkdir()
    width, height = extent
    source_width, source_height = map(int, capture["input_size"])
    frames: list[np.ndarray] = []
    frame_records: list[dict[str, Any]] = []
    for ordinal, record in enumerate(selected):
        manifest_path = capture_root / str(record["frame_manifest"])
        manifest = load_json(manifest_path)
        if manifest.get("frame_id") != record.get("frame_id"):
            raise ValueError(f"frame identity mismatch in {manifest_path}")
        channel = appearance_record(manifest)
        raw_path = capture_root / str(channel["raw_path"])
        if sha256_file(raw_path) != channel.get("raw_sha256"):
            raise ValueError(f"appearance digest mismatch: {raw_path}")
        raw = np.fromfile(raw_path, dtype=np.uint8)
        expected = source_width * source_height * 4
        if raw.size != expected:
            raise ValueError(f"appearance byte count mismatch: {raw_path}")
        rgba = raw.reshape(source_height, source_width, 4)
        image = Image.fromarray(rgba[:, :, :3], mode="RGB").resize((width, height), Image.Resampling.NEAREST)
        pixels = np.asarray(image, dtype=np.uint8)
        frame_path = frame_dir / f"frame-{ordinal:04d}.png"
        image.save(frame_path)
        frames.append(pixels)
        frame_records.append(
            {
                "ordinal": ordinal,
                "frame_id": record["frame_id"],
                "authority_tick": record["authority_tick"],
                "presentation_frame": record["presentation_frame"],
                "source_manifest": str(manifest_path),
                "source_appearance": str(raw_path),
                "source_appearance_sha256": channel["raw_sha256"],
                "materialized_frame": str(frame_path),
                "materialized_frame_sha256": sha256_file(frame_path),
            }
        )

    video_path = output_root / "appearance.mp4"
    with imageio.get_writer(
        video_path,
        fps=fps,
        codec="libx264",
        pixelformat="yuv444p",
        macro_block_size=None,
        ffmpeg_params=["-crf", "0"],
    ) as writer:
        for frame in frames:
            writer.append_data(frame)
    sheet_path = output_root / "contact-sheet.png"
    contact_sheet(frames).save(sheet_path)
    result = {
        "schema": SEQUENCE_SCHEMA,
        "status": "complete",
        "purpose": "stock LTX-Video RGB video-to-video feasibility input; dense G-buffer conditioning remains separate",
        "capture_root": str(capture_root),
        "capture_schema": capture["schema"],
        "capture_input_schema": capture["input_schema"],
        "capture_source_revision": capture["source_revision"],
        "capture_source_dirty_fingerprint": capture["source_dirty_fingerprint"],
        "capture_content_digest": capture["content_digest"],
        "sequence": capture["sequence"],
        "camera_path": capture["camera_path"],
        "selection": {"start_index": start_index, "frame_count": frame_count},
        "extent": [width, height],
        "fps": fps,
        "video": str(video_path),
        "video_sha256": sha256_file(video_path),
        "contact_sheet": str(sheet_path),
        "contact_sheet_sha256": sha256_file(sheet_path),
        "frames": frame_records,
    }
    atomic_json(output_root / "sequence.json", result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--frames", type=int, default=9)
    parser.add_argument("--extent", type=parse_extent, default=parse_extent("512x288"))
    parser.add_argument("--fps", type=int, default=8)
    args = parser.parse_args()
    result = prepare(args.capture, args.output, args.start_index, args.frames, args.extent, args.fps)
    print(
        "NR0003_LTX_SEQUENCE_PASS "
        f"frames={len(result['frames'])} extent={result['extent'][0]}x{result['extent'][1]} "
        f"sequence={result['sequence']}"
    )


if __name__ == "__main__":
    main()
