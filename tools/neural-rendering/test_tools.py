#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import torch
from PIL import Image

from nr_common import atomic_json, image_to_tensor, psnr_from_mse, tensor_to_image
from nr_dataset import PairedFrameDataset
from nr_model import SpatialResidualUpscaler, checkpoint_model


class NeuralRenderingToolsTest(unittest.TestCase):
    def test_model_shape_gradient_and_checkpoint_round_trip(self) -> None:
        model = SpatialResidualUpscaler(scale=4, features=8)
        low = torch.rand(2, 3, 9, 16, requires_grad=True)
        output = model(low)
        self.assertEqual((2, 3, 36, 64), tuple(output.shape))
        output.mean().backward()
        self.assertIsNotNone(low.grad)
        restored = checkpoint_model(
            {
                "model": {"scale": 4, "features": 8},
                "state_dict": model.state_dict(),
            }
        )
        with torch.inference_mode():
            torch.testing.assert_close(model(low), restored(low))

    def test_manifest_dataset_and_image_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            low_path = root / "low.png"
            target_path = root / "target.png"
            Image.new("RGB", (4, 3), (16, 32, 64)).save(low_path)
            Image.new("RGB", (16, 12), (16, 32, 64)).save(target_path)
            atomic_json(
                root / "dataset.json",
                {
                    "schema": 1,
                    "frames": [
                        {
                            "split": "train",
                            "frame_id": "frame-1",
                            "input_path": "low.png",
                            "target_path": "target.png",
                        }
                    ],
                },
            )
            dataset = PairedFrameDataset(root / "dataset.json", "train")
            low, target, frame_id = dataset[0]
            self.assertEqual((3, 3, 4), tuple(low.shape))
            self.assertEqual((3, 12, 16), tuple(target.shape))
            self.assertEqual("frame-1", frame_id)
            restored = tensor_to_image(image_to_tensor(low_path))
            self.assertEqual((4, 3), restored.size)

    def test_psnr(self) -> None:
        self.assertEqual(float("inf"), psnr_from_mse(0.0))
        self.assertAlmostEqual(20.0, psnr_from_mse(0.01))


if __name__ == "__main__":
    unittest.main()
