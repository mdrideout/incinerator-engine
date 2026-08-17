"""Exact native-corpus loader for the from-scratch title renderer."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import Imath
import numpy as np
import OpenEXR
import torch
from torch.utils.data import Dataset

from .contracts import CHANNELS, INPUT_EXTENT, TARGET_EXTENT, inspect_corpus_metadata
from .io import load_json, sha256_file


CONTINUOUS_PLANES = (
    "appearance_linear.r",
    "appearance_linear.g",
    "appearance_linear.b",
    "linear_depth",
    "world_normal.x",
    "world_normal.y",
    "world_normal.z",
    "motion.x",
    "motion.y",
    "history_valid",
    "coverage",
)
GLOBAL_CONTROLS = (
    "sun_strength",
    "world_strength",
    "local_light_strength",
    "emissive_strength",
    "material_palette",
)


def _rgba8(path: Path, extent: tuple[int, int]) -> np.ndarray:
    width, height = extent
    pixels = np.fromfile(path, dtype=np.uint8)
    expected = width * height * 4
    if pixels.size != expected:
        raise ValueError(f"RGBA8 byte count drifted in {path}: {pixels.size} != {expected}")
    return pixels.reshape(height, width, 4)


def _srgb_to_linear(value: np.ndarray) -> np.ndarray:
    value = value.astype(np.float32) / 255.0
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


def _categorical_rgb24(value: np.ndarray) -> np.ndarray:
    value = value.astype(np.int64)
    return value[:, :, 0] | (value[:, :, 1] << 8) | (value[:, :, 2] << 16)


def _map_categories(values: np.ndarray, vocabulary: dict[int, int]) -> np.ndarray:
    output = np.zeros(values.shape, dtype=np.int64)
    for encoded, index in vocabulary.items():
        output[values == encoded] = index
    return output


def _exr_rgb(path: Path, extent: tuple[int, int]) -> np.ndarray:
    source = OpenEXR.InputFile(str(path))
    try:
        header = source.header()
        window = header["dataWindow"]
        width = int(window.max.x - window.min.x + 1)
        height = int(window.max.y - window.min.y + 1)
        if (width, height) != extent:
            raise ValueError(f"EXR extent drifted in {path}: {(width, height)} != {extent}")
        names = header["channels"].keys()
        prefix = "ViewLayer.Combined."
        if not all(prefix + channel in names for channel in "RGB"):
            raise ValueError(f"EXR combined RGB channels are missing: {path}")
        pixel_type = Imath.PixelType(Imath.PixelType.FLOAT)
        channels = [
            np.frombuffer(source.channel(prefix + channel, pixel_type), dtype=np.float32).reshape(height, width)
            for channel in "RGB"
        ]
        rgb = np.stack(channels, axis=2).copy()
    finally:
        source.close()
    if not np.isfinite(rgb).all() or float(rgb.min()) < 0.0:
        raise ValueError(f"EXR target contains non-finite or negative scene color: {path}")
    return rgb


def _identity_coverage(path: Path, extent: tuple[int, int]) -> np.ndarray:
    width, height = extent
    values = np.fromfile(path, dtype="<u4")
    if values.size != width * height:
        raise ValueError(f"target identity byte count drifted: {path}")
    return (values.reshape(height, width) != 0).astype(np.float32)


def _control_values(path: Path) -> tuple[float, float, float, float, float]:
    raw = path.read_bytes()
    if len(raw) != 20:
        raise ValueError(f"global-control payload drifted: {path}")
    values = struct.unpack("<5f", raw)
    if not all(np.isfinite(value) for value in values):
        raise ValueError(f"global-control payload is not finite: {path}")
    return values


@dataclass(frozen=True)
class DatasetSpecification:
    corpus_root: str
    corpus_manifest_sha256: str
    splits: tuple[str, ...]
    frames: int
    input_extent: tuple[int, int]
    target_extent: tuple[int, int]
    continuous_planes: tuple[str, ...]
    semantic_vocabulary: dict[int, int]
    instance_vocabulary: dict[int, int]
    control_minimum: tuple[float, float, float, float, float]
    control_maximum: tuple[float, float, float, float, float]
    target_minimum: float
    target_maximum: float
    test_pixels_opened: bool

    def json(self) -> dict[str, Any]:
        return {
            "schema": 1,
            "corpus_root": self.corpus_root,
            "corpus_manifest_sha256": self.corpus_manifest_sha256,
            "splits": list(self.splits),
            "frames": self.frames,
            "input_extent": list(self.input_extent),
            "target_extent": list(self.target_extent),
            "continuous_planes": list(self.continuous_planes),
            "semantic_vocabulary": {str(key): value for key, value in sorted(self.semantic_vocabulary.items())},
            "instance_vocabulary": {str(key): value for key, value in sorted(self.instance_vocabulary.items())},
            "global_controls": list(GLOBAL_CONTROLS),
            "control_minimum": list(self.control_minimum),
            "control_maximum": list(self.control_maximum),
            "target_minimum": self.target_minimum,
            "target_maximum": self.target_maximum,
            "test_pixels_opened": self.test_pixels_opened,
        }


def _vocabulary(values: Iterable[np.ndarray]) -> dict[int, int]:
    unique = {0}
    for value in values:
        unique.update(int(item) for item in np.unique(value))
    ordered = sorted(unique)
    return {encoded: index for index, encoded in enumerate(ordered)}


class TitleCorpusDataset(Dataset):
    """Eager immutable tensor view over explicitly selected whole splits."""

    def __init__(
        self,
        corpus_root: Path,
        splits: tuple[str, ...],
        *,
        allow_test: bool = False,
        reference_specification: dict[str, Any] | None = None,
    ) -> None:
        if not splits:
            raise ValueError("title-renderer dataset must name splits explicitly")
        if "test" in splits and not allow_test:
            raise ValueError("sealed test pixels require the explicit final-evaluation path")
        inspected = inspect_corpus_metadata(corpus_root, verify_training_artifacts=True)
        self.root: Path = inspected["root"]
        self.records = [record for record in inspected["records"] if record["split"] in splits]
        if not self.records:
            raise ValueError(f"selected title-corpus splits are empty: {splits}")
        unexpected = {record["split"] for record in self.records} - set(splits)
        if unexpected:
            raise ValueError(f"dataset opened undeclared splits: {sorted(unexpected)}")
        semantic_values: list[np.ndarray] = []
        instance_values: list[np.ndarray] = []
        controls: list[tuple[float, float, float, float, float]] = []
        raw_frames: list[dict[str, Any]] = []
        target_minimum = float("inf")
        target_maximum = float("-inf")
        for record in self.records:
            channels = {channel["name"]: channel for channel in record["conditioning"]["channels"]}
            if tuple(channels) != CHANNELS:
                raise ValueError(f"conditioning ABI drifted: {record['frame_id']}")
            arrays = {name: _rgba8(self.root / channels[name]["path"], INPUT_EXTENT) for name in CHANNELS}
            semantic_values.append(_categorical_rgb24(arrays["semantic"]))
            instance_values.append(_categorical_rgb24(arrays["instance"]))
            control = _control_values(self.root / record["conditioning"]["global_controls"]["path"])
            controls.append(control)
            target = _exr_rgb(self.root / record["target"]["linear_hdr"]["path"], TARGET_EXTENT)
            target_minimum = min(target_minimum, float(target.min()))
            target_maximum = max(target_maximum, float(target.max()))
            identity = next(item for item in record["target"]["auxiliary"] if item["kind"] == "identity.u32")
            raw_frames.append({"record": record, "arrays": arrays, "target": target, "identity": identity})
        control_array = np.asarray(controls, dtype=np.float32)
        if reference_specification is None:
            semantic_vocabulary = _vocabulary(semantic_values)
            instance_vocabulary = _vocabulary(instance_values)
            control_minimum = control_array.min(axis=0)
            control_maximum = control_array.max(axis=0)
        else:
            semantic_vocabulary = {
                int(key): int(value)
                for key, value in reference_specification["semantic_vocabulary"].items()
            }
            instance_vocabulary = {
                int(key): int(value)
                for key, value in reference_specification["instance_vocabulary"].items()
            }
            observed_semantic = set().union(*(set(int(item) for item in np.unique(value)) for value in semantic_values))
            observed_instance = set().union(*(set(int(item) for item in np.unique(value)) for value in instance_values))
            if observed_semantic - set(semantic_vocabulary) or observed_instance - set(instance_vocabulary):
                raise ValueError("evaluation corpus contains categories absent from the frozen training vocabulary")
            control_minimum = np.asarray(reference_specification["control_minimum"], dtype=np.float32)
            control_maximum = np.asarray(reference_specification["control_maximum"], dtype=np.float32)
        self.specification = DatasetSpecification(
            corpus_root=str(self.root),
            corpus_manifest_sha256=sha256_file(self.root / "corpus.json"),
            splits=splits,
            frames=len(raw_frames),
            input_extent=INPUT_EXTENT,
            target_extent=TARGET_EXTENT,
            continuous_planes=CONTINUOUS_PLANES,
            semantic_vocabulary=semantic_vocabulary,
            instance_vocabulary=instance_vocabulary,
            control_minimum=tuple(float(value) for value in control_minimum),
            control_maximum=tuple(float(value) for value in control_maximum),
            target_minimum=target_minimum,
            target_maximum=target_maximum,
            test_pixels_opened="test" in splits,
        )
        scale = np.where(control_maximum > control_minimum, control_maximum - control_minimum, 1.0)
        self.frames: list[dict[str, Any]] = []
        for index, raw in enumerate(raw_frames):
            arrays = raw["arrays"]
            appearance = arrays["appearance"]
            continuous = np.concatenate(
                (
                    _srgb_to_linear(appearance[:, :, :3]),
                    arrays["linear-depth"][:, :, 0:1].astype(np.float32) / 255.0,
                    arrays["world-normal"][:, :, :3].astype(np.float32) / 127.5 - 1.0,
                    arrays["motion"][:, :, 0:2].astype(np.float32) / 127.5 - 1.0,
                    arrays["motion"][:, :, 2:3].astype(np.float32) / 255.0,
                    appearance[:, :, 3:4].astype(np.float32) / 255.0,
                ),
                axis=2,
            )
            semantic = _map_categories(semantic_values[index], semantic_vocabulary)
            instance = _map_categories(instance_values[index], instance_vocabulary)
            normalized_controls = (control_array[index] - control_minimum) / scale
            target_coverage = _identity_coverage(self.root / raw["identity"]["path"], TARGET_EXTENT)
            self.frames.append(
                {
                    "frame_id": str(raw["record"]["frame_id"]),
                    "split": str(raw["record"]["split"]),
                    "continuous": torch.from_numpy(continuous).permute(2, 0, 1).contiguous(),
                    "semantic": torch.from_numpy(semantic).long().contiguous(),
                    "instance": torch.from_numpy(instance).long().contiguous(),
                    "global_controls": torch.from_numpy(normalized_controls.copy()).contiguous(),
                    "target": torch.from_numpy(raw["target"]).permute(2, 0, 1).contiguous(),
                    "target_coverage": torch.from_numpy(target_coverage).unsqueeze(0).contiguous(),
                }
            )

    def __len__(self) -> int:
        return len(self.frames)

    def __getitem__(self, index: int) -> dict[str, Any]:
        return self.frames[index]
