"""Schema-2 multi-channel capture dataset for NR0-C spatial experiments."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch.utils.data import Dataset

from nr_common import load_json


DATASET_SCHEMA = 2
CAPTURE_SCHEMA = 2
CHANNELS = (
    "appearance",
    "linear-depth",
    "world-normal",
    "motion",
    "semantic",
    "instance",
)
MODEL_PLANES = (
    "appearance.r",
    "appearance.g",
    "appearance.b",
    "linear-depth.r",
    "world-normal.r",
    "world-normal.g",
    "world-normal.b",
    "motion.r",
    "motion.g",
    "motion.b_history_valid",
    "semantic.r",
    "semantic.g",
    "semantic.b",
    "instance.r",
    "instance.g",
    "instance.b",
    "appearance.a_coverage",
)


def _rgba8(path: Path, width: int, height: int) -> np.ndarray:
    expected = width * height * 4
    pixels = np.fromfile(path, dtype=np.uint8)
    if pixels.size != expected:
        raise ValueError(f"unexpected RGBA8 byte count in {path}: {pixels.size} != {expected}")
    return pixels.reshape(height, width, 4)


def load_frame(frame: dict[str, Any], input_size: tuple[int, int], target_size: tuple[int, int]) -> tuple[torch.Tensor, torch.Tensor]:
    input_width, input_height = input_size
    target_width, target_height = target_size
    channel_paths = frame.get("channel_paths")
    if not isinstance(channel_paths, dict) or set(channel_paths) != set(CHANNELS):
        raise ValueError(f"frame {frame.get('frame_id')} has a different channel ABI")
    channels = {
        name: _rgba8(Path(str(channel_paths[name])), input_width, input_height)
        for name in CHANNELS
    }
    appearance = channels["appearance"]
    packed = np.concatenate(
        (
            appearance[:, :, :3],
            channels["linear-depth"][:, :, 0:1],
            channels["world-normal"][:, :, :3],
            channels["motion"][:, :, :3],
            channels["semantic"][:, :, :3],
            channels["instance"][:, :, :3],
            appearance[:, :, 3:4],
        ),
        axis=2,
    )
    target = _rgba8(Path(str(frame["target_path"])), target_width, target_height)[:, :, :3]
    input_tensor = torch.from_numpy(packed.astype(np.float32) / 255.0).permute(2, 0, 1).contiguous()
    target_tensor = torch.from_numpy(target.astype(np.float32) / 255.0).permute(2, 0, 1).contiguous()
    return input_tensor, target_tensor


class Nr0Dataset(Dataset):
    """Whole-frame evaluator or deterministic aligned-patch training view."""

    def __init__(
        self,
        manifest_path: Path,
        split: str,
        *,
        patch_size: int | None = None,
        seed: int = 0,
    ) -> None:
        manifest = load_json(manifest_path)
        if manifest.get("schema") != DATASET_SCHEMA:
            raise ValueError(f"unsupported NR0 dataset schema in {manifest_path}")
        if tuple(manifest.get("model_planes", ())) != MODEL_PLANES:
            raise ValueError(f"model plane ABI drift in {manifest_path}")
        frames = manifest.get("frames")
        if not isinstance(frames, list):
            raise ValueError(f"dataset manifest has no frames: {manifest_path}")
        self.frames: list[dict[str, Any]] = [frame for frame in frames if frame.get("split") == split]
        if not self.frames:
            raise ValueError(f"dataset split is empty: {split}")
        dimensions = manifest["dimensions"]
        self.input_size = tuple(int(value) for value in dimensions["input"])
        self.target_size = tuple(int(value) for value in dimensions["target"])
        self.scale = int(dimensions["scale"])
        if self.target_size != tuple(value * self.scale for value in self.input_size):
            raise ValueError("dataset target is not an integer scale of its input")
        if patch_size is not None and (patch_size <= 0 or patch_size > min(self.input_size)):
            raise ValueError("patch size must fit the low-resolution input")
        self.patch_size = patch_size
        self.seed = seed
        self.epoch = 0

    def set_epoch(self, epoch: int) -> None:
        self.epoch = epoch

    def __len__(self) -> int:
        return len(self.frames)

    def __getitem__(self, index: int):
        frame = self.frames[index]
        inputs, target = load_frame(frame, self.input_size, self.target_size)
        if self.patch_size is not None:
            crop_seed = f"{self.seed}:{self.epoch}:{index}:{frame['frame_id']}".encode()
            digest = hashlib.sha256(crop_seed).digest()
            max_x = self.input_size[0] - self.patch_size
            max_y = self.input_size[1] - self.patch_size
            x = int.from_bytes(digest[:8], "little") % (max_x + 1)
            y = int.from_bytes(digest[8:16], "little") % (max_y + 1)
            size = self.patch_size
            inputs = inputs[:, y : y + size, x : x + size]
            output_x, output_y, output_size = x * self.scale, y * self.scale, size * self.scale
            target = target[:, output_y : output_y + output_size, output_x : output_x + output_size]
        return inputs, target, str(frame["frame_id"])
