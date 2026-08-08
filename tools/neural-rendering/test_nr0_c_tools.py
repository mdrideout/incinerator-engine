#!/usr/bin/env python3
"""Focused offline tests for the NR0-C data/model boundary."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from nr0_dataset import CHANNELS, MODEL_PLANES, Nr0Dataset
from nr0_model import Nr0SpatialResidualUpscaler, checkpoint_model


class Nr0CToolTests(unittest.TestCase):
    def make_dataset(self, root: Path) -> Path:
        input_width, input_height, scale = 4, 3, 4
        target_width, target_height = input_width * scale, input_height * scale
        channel_paths = {}
        for channel_index, name in enumerate(CHANNELS):
            pixels = np.zeros((input_height, input_width, 4), dtype=np.uint8)
            pixels[:, :, 0] = 10 + channel_index
            pixels[:, :, 1] = 20 + channel_index
            pixels[:, :, 2] = 30 + channel_index
            pixels[:, :, 3] = 255
            path = root / f"{name}.rgba8"
            pixels.tofile(path)
            channel_paths[name] = str(path)
        target = np.arange(target_width * target_height * 4, dtype=np.uint8).reshape(target_height, target_width, 4)
        target_path = root / "target.rgba8"
        target.tofile(target_path)
        manifest = {
            "schema": 2,
            "dimensions": {"input": [input_width, input_height], "target": [target_width, target_height], "scale": scale},
            "model_planes": list(MODEL_PLANES),
            "frames": [
                {"frame_id": f"frame-{split}", "split": split, "channel_paths": channel_paths, "target_path": str(target_path)}
                for split in ("overfit", "train", "validation", "test")
            ],
        }
        path = root / "dataset.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return path

    def test_dataset_packs_exact_17_plane_abi(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            dataset = Nr0Dataset(self.make_dataset(Path(directory)), "train")
            inputs, target, frame_id = dataset[0]
            self.assertEqual(tuple(inputs.shape), (17, 3, 4))
            self.assertEqual(tuple(target.shape), (3, 12, 16))
            self.assertEqual(frame_id, "frame-train")
            self.assertAlmostEqual(float(inputs[0, 0, 0]), 10 / 255)
            self.assertAlmostEqual(float(inputs[3, 0, 0]), 11 / 255)
            self.assertAlmostEqual(float(inputs[-1, 0, 0]), 1.0)

    def test_patch_crop_is_deterministic_and_scale_aligned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.make_dataset(Path(directory))
            first = Nr0Dataset(path, "train", patch_size=2, seed=9)
            second = Nr0Dataset(path, "train", patch_size=2, seed=9)
            first.set_epoch(4)
            second.set_epoch(4)
            first_inputs, first_target, _ = first[0]
            second_inputs, second_target, _ = second[0]
            self.assertTrue(torch.equal(first_inputs, second_inputs))
            self.assertTrue(torch.equal(first_target, second_target))
            self.assertEqual(tuple(first_inputs.shape), (17, 2, 2))
            self.assertEqual(tuple(first_target.shape), (3, 8, 8))

    def test_model_and_checkpoint_preserve_fixed_shape_contract(self) -> None:
        model = Nr0SpatialResidualUpscaler(scale=4, features=8, blocks=1)
        example = torch.rand(1, len(MODEL_PLANES), 3, 4)
        self.assertEqual(tuple(model(example).shape), (1, 3, 12, 16))
        restored = checkpoint_model(
            {
                "schema": 2,
                "model": {"name": "nr0_multichannel_spatial_residual", "scale": 4, "features": 8, "blocks": 1},
                "state_dict": model.state_dict(),
            }
        )
        self.assertTrue(torch.equal(model(example), restored(example)))


if __name__ == "__main__":
    unittest.main()
