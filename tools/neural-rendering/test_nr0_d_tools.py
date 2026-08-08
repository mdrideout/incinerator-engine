#!/usr/bin/env python3
"""Focused contracts for NR0-D boundary and temporal measurements."""

from __future__ import annotations

import unittest

import torch

from evaluate_nr0_d import aggregate_spatial
from nr0_d_metrics import (
    categorical_boundary,
    decode_instance,
    metrics,
    temporal_reprojection,
)


class Nr0DToolTests(unittest.TestCase):
    def test_categorical_boundaries_and_rgb24_identity_are_exact(self) -> None:
        values = torch.zeros(3, 3, 4, dtype=torch.uint8)
        values[:, :, 2:] = torch.tensor([17, 34, 51], dtype=torch.uint8)[:, None, None]
        coverage = torch.ones(3, 4, dtype=torch.bool)
        boundary = categorical_boundary(values, coverage)
        self.assertEqual(int(boundary.sum()), 6)
        decoded = decode_instance(values)
        self.assertEqual(int(decoded[0, 0]), 0)
        self.assertEqual(int(decoded[0, 3]), 0x332211)

    def test_zero_motion_reprojection_retains_semantic_instance_history(self) -> None:
        previous = torch.arange(4 * 6, dtype=torch.float32).reshape(1, 1, 4, 6).repeat(1, 3, 1, 1) / 24
        motion = torch.zeros(3, 2, 3)
        motion[0:2] = 0.5
        motion[2] = 1
        semantic = torch.ones(3, 2, 3, dtype=torch.uint8)
        instance = torch.ones(2, 3, dtype=torch.int64) * 99
        coverage = torch.ones(2, 3, dtype=torch.bool)
        warped, valid, disoccluded = temporal_reprojection(
            previous, motion, semantic, semantic, instance, instance, coverage, (4, 6)
        )
        self.assertTrue(torch.allclose(previous, warped, atol=1e-6))
        self.assertEqual(int(valid.sum()), 24)
        self.assertEqual(int(disoccluded.sum()), 0)

    def test_identity_change_rejects_history_as_disocclusion(self) -> None:
        image = torch.zeros(1, 3, 4, 4)
        motion = torch.zeros(3, 2, 2)
        motion[0:2] = 0.5
        motion[2] = 1
        semantic = torch.ones(3, 2, 2, dtype=torch.uint8)
        previous_instance = torch.ones(2, 2, dtype=torch.int64)
        current_instance = previous_instance.clone()
        current_instance[0, 0] = 2
        coverage = torch.ones(2, 2, dtype=torch.bool)
        _, valid, disoccluded = temporal_reprojection(
            image, motion, semantic, semantic, previous_instance, current_instance, coverage, (4, 4)
        )
        self.assertEqual(int(valid.sum()), 12)
        self.assertEqual(int(disoccluded.sum()), 4)

    def test_aggregate_preserves_all_pixels_and_recomputes_error(self) -> None:
        target = torch.zeros(1, 3, 2, 2)
        methods = {
            "nearest": torch.zeros_like(target),
            "bilinear": torch.zeros_like(target),
            "bicubic": torch.zeros_like(target),
            "model": torch.ones_like(target) * 0.25,
        }
        scopes = {
            name: {
                scope: metrics(value, target)
                for scope in ("full", "coverage", "semantic_boundary", "instance_boundary")
            }
            for name, value in methods.items()
        }
        aggregate = aggregate_spatial([{"metrics": scopes}, {"metrics": scopes}])
        self.assertEqual(aggregate["model"]["full"]["pixels"], 8)
        self.assertAlmostEqual(aggregate["model"]["full"]["mae"], 0.25)
        self.assertEqual(aggregate["nearest"]["full"]["psnr_db"], None)


if __name__ == "__main__":
    unittest.main()
