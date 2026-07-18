#!/usr/bin/env python3
"""Create read-only PNG contact sheets from an Incinerator incident bundle."""

from __future__ import annotations

import argparse
import binascii
import json
import math
from pathlib import Path
import struct
import zlib


FONT = {
    " ": ("000",) * 5,
    "+": ("000", "010", "111", "010", "000"),
    "-": ("000", "000", "111", "000", "000"),
    "0": ("111", "101", "101", "101", "111"),
    "1": ("010", "110", "010", "010", "111"),
    "2": ("111", "001", "111", "100", "111"),
    "3": ("111", "001", "111", "001", "111"),
    "4": ("101", "101", "111", "001", "001"),
    "5": ("111", "100", "111", "001", "111"),
    "6": ("111", "100", "111", "101", "111"),
    "7": ("111", "001", "010", "010", "010"),
    "8": ("111", "101", "111", "101", "111"),
    "9": ("111", "101", "111", "001", "111"),
    "f": ("011", "010", "111", "010", "010"),
    "m": ("000", "110", "111", "101", "101"),
    "s": ("011", "100", "010", "001", "110"),
}


def read_ndjson(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def ppm_pixels(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    index = 0

    def token() -> bytes:
        nonlocal index
        while index < len(data):
            if data[index:index + 1] == b"#":
                index = data.find(b"\n", index) + 1
            elif data[index:index + 1].isspace():
                index += 1
            else:
                break
        end = index
        while end < len(data) and not data[end:end + 1].isspace():
            end += 1
        value = data[index:end]
        index = end
        return value

    if token() != b"P6":
        raise ValueError(f"not a P6 PPM: {path}")
    width, height, maximum = int(token()), int(token()), int(token())
    if maximum != 255:
        raise ValueError(f"unsupported PPM maximum in {path}")
    if data[index:index + 2] == b"\r\n":
        index += 2
    elif index < len(data) and data[index:index + 1].isspace():
        index += 1
    else:
        raise ValueError(f"missing PPM header separator: {path}")
    pixels = data[index:]
    if len(pixels) != width * height * 3:
        raise ValueError(f"invalid PPM pixel length: {path}")
    return width, height, pixels


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(
        ">I", binascii.crc32(kind + payload) & 0xFFFFFFFF
    )


def write_png(path: Path, width: int, height: int, pixels: bytearray) -> None:
    scanlines = bytearray()
    stride = width * 3
    for row in range(height):
        scanlines.append(0)
        scanlines.extend(pixels[row * stride:(row + 1) * stride])
    encoded = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(bytes(scanlines), 6))
        + png_chunk(b"IEND", b"")
    )
    path.write_bytes(encoded)


def draw_text(pixels: bytearray, width: int, x: int, y: int, value: str) -> None:
    for char in value:
        glyph = FONT.get(char, FONT[" "])
        for row, bits in enumerate(glyph):
            for column, bit in enumerate(bits):
                if bit == "1":
                    offset = ((y + row) * width + x + column) * 3
                    pixels[offset:offset + 3] = b"\xff\xff\xff"
        x += 4


def render_sheet(root: Path, output: Path, anomaly: Path) -> tuple[Path, int]:
    frames = [
        value for value in read_ndjson(anomaly / "visual-index.ndjson")
        if value.get("source") == "product_trail"
    ]
    frames.sort(key=lambda value: (int(value["actual_offset_ms"]), int(value["capture_sequence"])))
    if not frames:
        raise ValueError(f"no product trail in {anomaly}")

    thumb_width, thumb_height, label_height, columns = 160, 90, 14, 5
    rows = math.ceil(len(frames) / columns)
    sheet_width, sheet_height = thumb_width * columns, (thumb_height + label_height) * rows
    sheet = bytearray(sheet_width * sheet_height * 3)
    mapping = ["| Cell | Offset | Tick | Frame | Source artifact |", "|---:|---:|---:|---:|---|"]

    for index, frame in enumerate(frames):
        source = root / str(frame["path"])
        width, height, pixels = ppm_pixels(source)
        column, row = index % columns, index // columns
        base_x, base_y = column * thumb_width, row * (thumb_height + label_height)
        for y in range(thumb_height):
            source_y = min(height - 1, y * height // thumb_height)
            for x in range(thumb_width):
                source_x = min(width - 1, x * width // thumb_width)
                source_offset = (source_y * width + source_x) * 3
                target_offset = ((base_y + y) * sheet_width + base_x + x) * 3
                sheet[target_offset:target_offset + 3] = pixels[source_offset:source_offset + 3]
        offset_ms = int(frame["actual_offset_ms"])
        draw_text(
            sheet,
            sheet_width,
            base_x + 3,
            base_y + thumb_height + 4,
            f"{offset_ms:+d}ms f{int(frame['presentation_frame'])}",
        )
        mapping.append(
            f"| {index + 1} | {offset_ms:+d} ms | {frame['authority_tick']} | "
            f"{frame['presentation_frame']} | `{frame['path']}` |"
        )

    name = anomaly.name + "-contact-sheet.png"
    sheet_path = output / name
    write_png(sheet_path, sheet_width, sheet_height, sheet)
    (output / (anomaly.name + "-frames.md")).write_text("\n".join(mapping) + "\n", encoding="utf-8")
    return sheet_path, len(frames)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_folder", type=Path)
    parser.add_argument("output_folder", type=Path)
    args = parser.parse_args()
    root = args.run_folder.expanduser().resolve()
    output = args.output_folder.expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"run folder does not exist: {root}")
    if output == root or root in output.parents:
        raise ValueError("visual reports must be written outside the original run folder")
    output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    report = [
        "# Incinerator incident visual report",
        "",
        f"Source bundle (read-only): `{root}`",
        "",
        f"Evidence capabilities: `{json.dumps(manifest.get('evidence_capabilities'), sort_keys=True)}`",
        "",
    ]
    for anomaly in sorted((root / "anomalies").glob("anomaly-*")):
        if not (anomaly / "visual-index.ndjson").is_file():
            continue
        sheet, count = render_sheet(root, output, anomaly)
        report.extend(
            [
                f"## {anomaly.name}",
                "",
                f"{count} product-trail frames in chronological order at recorded actual offsets.",
                "",
                f"![{anomaly.name}]({sheet.name})",
                "",
                f"Frame map: [{anomaly.name}-frames.md]({anomaly.name}-frames.md)",
                "",
            ]
        )
    (output / "report.md").write_text("\n".join(report), encoding="utf-8")
    print(output / "report.md")


if __name__ == "__main__":
    main()
