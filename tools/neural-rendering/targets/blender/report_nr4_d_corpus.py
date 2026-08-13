#!/usr/bin/env python3
"""Build a compact, display-only review sheet for an NR4-D corpus."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

from nr4_common import TARGET_EXTENT, artifact, atomic_json, create_absent, read_ndjson


def build_report(corpus_root: Path, output: Path) -> dict:
    records = read_ndjson(corpus_root / "frames.ndjson")
    by_sequence: dict[str, list[dict]] = {}
    for record in records:
        by_sequence.setdefault(record["sequence"], []).append(record)
    if not by_sequence:
        raise ValueError("NR4-D report has no frames")

    selections: list[dict] = []
    for sequence, frames in sorted(by_sequence.items()):
        ordered = sorted(frames, key=lambda frame: frame["presentation_frame"])
        if ordered[0]["split"] == "test":
            continue
        for frame in (ordered[0], ordered[len(ordered) // 2], ordered[-1]):
            selections.append(frame)

    panel_width, panel_height = TARGET_EXTENT
    label_height = 24
    row_height = panel_height + label_height
    sheet = Image.new("RGB", (panel_width * 2, row_height * len(selections)), (16, 20, 26))
    draw = ImageDraw.Draw(sheet)
    for row, frame in enumerate(selections):
        y = row * row_height
        cheap = Image.open(corpus_root / frame["review"]["appearance_debug"]).convert("RGB")
        target = Image.open(corpus_root / frame["review"]["target_display"]).convert("RGB")
        cheap = cheap.resize((panel_width, panel_height), Image.Resampling.NEAREST)
        if target.size != (panel_width, panel_height):
            raise ValueError("NR4-D target display has a foreign extent")
        sheet.paste(cheap, (0, y + label_height))
        sheet.paste(target, (panel_width, y + label_height))
        label = (
            f"{frame['split']} | {frame['sequence']} | frame "
            f"{frame['presentation_frame']} | cheap"
        )
        draw.text((6, y + 5), label, fill=(235, 238, 244))
        draw.text((panel_width + 6, y + 5), label[:-5] + "target", fill=(235, 238, 244))

    output = create_absent(output.resolve(), "NR4-D report root")
    image_path = output / "nr4-d-corpus-review.png"
    sheet.save(image_path, format="PNG", optimize=False)
    manifest = {
        "schema": 1,
        "status": "complete",
        "purpose": "display-only corpus review; never training material",
        "sequences": len(by_sequence),
        "reviewed_sequences": len({frame["sequence"] for frame in selections}),
        "test_frames_included": False,
        "selected_frames": len(selections),
        "artifacts": [artifact(image_path, output)],
    }
    atomic_json(output / "report.json", manifest)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build_report(args.corpus.resolve(), args.output.resolve())
    print(args.output.resolve())


if __name__ == "__main__":
    main()
