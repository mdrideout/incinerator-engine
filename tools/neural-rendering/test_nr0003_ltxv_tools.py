#!/usr/bin/env python3
"""Focused contracts for the NR-0003 LTX input and evidence boundary."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import imageio.v2 as imageio
import numpy as np
from PIL import Image

from prepare_ltxv_sequence import parse_extent, prepare
from run_ltxv_candidate import make_comparison_sheet


class Nr0003LtxvToolTests(unittest.TestCase):
    def make_capture(self, root: Path, frame_count: int = 9) -> Path:
        (root / "frames").mkdir(parents=True)
        (root / "channels" / "appearance").mkdir(parents=True)
        frame_index = []
        for index in range(frame_count):
            pixels = np.zeros((4, 4, 4), dtype=np.uint8)
            pixels[:, :, 0] = index * 10
            pixels[:, :, 1] = 20
            pixels[:, :, 2] = 40
            pixels[:, :, 3] = 255
            raw_path = root / "channels" / "appearance" / f"frame-{index:08d}.rgba8"
            pixels.tofile(raw_path)
            digest = hashlib.sha256(raw_path.read_bytes()).hexdigest()
            manifest_path = root / "frames" / f"frame-{index:08d}.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "frame_id": f"fixture-{index}",
                        "channels": [
                            {
                                "name": "appearance",
                                "raw_path": str(raw_path.relative_to(root)),
                                "raw_sha256": digest,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            frame_index.append(
                {
                    "frame_id": f"fixture-{index}",
                    "authority_tick": index,
                    "presentation_frame": index,
                    "frame_manifest": str(manifest_path.relative_to(root)),
                }
            )
        (root / "frames.ndjson").write_text(
            "".join(json.dumps(record) + "\n" for record in frame_index), encoding="utf-8"
        )
        (root / "capture.json").write_text(
            json.dumps(
                {
                    "schema": 2,
                    "status": "complete",
                    "frame_index": "frames.ndjson",
                    "input_size": [4, 4],
                    "input_schema": {"name": "fixture"},
                    "source_revision": "fixture",
                    "source_dirty_fingerprint": "fixture",
                    "content_digest": "fixture",
                    "sequence": "fixture-sequence",
                    "camera_path": "fixture-camera",
                }
            ),
            encoding="utf-8",
        )
        return root

    def test_extent_requires_ltx_alignment(self) -> None:
        self.assertEqual(parse_extent("512x288"), (512, 288))
        with self.assertRaises(Exception):
            parse_extent("500x281")

    def test_prepare_materializes_exact_sequence_lineage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            capture = self.make_capture(base / "capture")
            output = base / "sequence"
            result = prepare(capture, output, 0, 9, (64, 32), 8)
            self.assertEqual(result["status"], "complete")
            self.assertEqual(len(result["frames"]), 9)
            self.assertEqual(result["frames"][4]["frame_id"], "fixture-4")
            self.assertTrue(Path(result["video"]).is_file())
            self.assertTrue(Path(result["contact_sheet"]).is_file())

    def test_prepare_rejects_non_ltx_frame_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            capture = self.make_capture(base / "capture")
            with self.assertRaisesRegex(ValueError, "8N\\+1"):
                prepare(capture, base / "sequence", 0, 8, (64, 32), 8)

    def test_comparison_sheet_pairs_every_source_and_generated_frame(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = []
            generated = []
            for index in range(3):
                source = np.full((32, 64, 3), (index + 1) * 20, dtype=np.uint8)
                generated_frame = np.full((32, 64, 3), (index + 1) * 60, dtype=np.uint8)
                source_path = root / f"source-{index}.png"
                Image.fromarray(source, mode="RGB").save(source_path)
                sources.append(source_path)
                generated.append(generated_frame)
            video_path = root / "generated.gif"
            imageio.mimsave(video_path, generated, format="GIF", duration=0.125)
            sheet_path = root / "comparison.png"
            make_comparison_sheet(sources, video_path, sheet_path)
            with Image.open(sheet_path) as sheet:
                self.assertEqual(sheet.size, (64 * 3, 32 * 2))


if __name__ == "__main__":
    unittest.main()
