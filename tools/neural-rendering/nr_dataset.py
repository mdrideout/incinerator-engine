"""Manifest-backed paired-frame dataset for spatial experiments."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from torch.utils.data import Dataset

from nr_common import image_to_tensor, load_json


class PairedFrameDataset(Dataset):
    def __init__(self, manifest_path: Path, split: str) -> None:
        manifest = load_json(manifest_path)
        if manifest.get("schema") != 1:
            raise ValueError(f"unsupported dataset schema in {manifest_path}")
        frames = manifest.get("frames")
        if not isinstance(frames, list):
            raise ValueError(f"dataset manifest has no frames: {manifest_path}")
        self.frames: list[dict[str, Any]] = [
            frame for frame in frames if frame.get("split") == split
        ]
        if not self.frames:
            raise ValueError(f"dataset split is empty: {split}")
        self.root = manifest_path.parent

    def __len__(self) -> int:
        return len(self.frames)

    def __getitem__(self, index: int):
        frame = self.frames[index]
        low = image_to_tensor(self.root / str(frame["input_path"]))
        target = image_to_tensor(self.root / str(frame["target_path"]))
        return low, target, str(frame["frame_id"])
