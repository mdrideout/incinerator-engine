#!/usr/bin/env python3
"""Export one immutable NR-0001 checkpoint as a fixed-shape Core ML candidate."""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

from nr_common import atomic_json, create_new_directory, require_absolute, sha256_file
from nr_model import checkpoint_model


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--input-width", required=True, type=int)
    parser.add_argument("--input-height", required=True, type=int)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    checkpoint_path = require_absolute(args.checkpoint, "--checkpoint")
    output = create_new_directory(args.output, "--output")
    if args.input_width <= 0 or args.input_height <= 0:
        raise ValueError("input dimensions must be positive")
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    model = checkpoint_model(checkpoint).eval()
    example = torch.rand(1, 3, args.input_height, args.input_width)
    traced = torch.jit.trace(model, example)
    started = time.perf_counter()
    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="low_resolution", shape=example.shape, dtype=np.float16)],
        outputs=[ct.TensorType(name="scene_color", dtype=np.float16)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
    )
    package_path = output / "spatial-upscaler.mlpackage"
    coreml_model.save(str(package_path))
    conversion_ms = (time.perf_counter() - started) * 1000.0

    sample = np.random.default_rng(20260805).random(example.shape, dtype=np.float32)
    with torch.inference_mode():
        torch_output = model(torch.from_numpy(sample)).numpy()
    prediction = coreml_model.predict({"low_resolution": sample.astype(np.float16)})
    coreml_output = np.asarray(prediction["scene_color"], dtype=np.float32)
    absolute = np.abs(torch_output - coreml_output)
    atomic_json(
        output / "export.json",
        {
            "schema": 1,
            "status": "complete",
            "checkpoint": str(checkpoint_path),
            "checkpoint_sha256": sha256_file(checkpoint_path),
            "package": str(package_path),
            "package_file_digests": {
                str(path.relative_to(package_path)): sha256_file(path)
                for path in sorted(package_path.rglob("*"))
                if path.is_file()
            },
            "input_name": "low_resolution",
            "output_name": "scene_color",
            "input_shape_nchw": list(example.shape),
            "output_shape_nchw": list(torch_output.shape),
            "precision": "float16",
            "minimum_deployment_target": "macOS15",
            "conversion_ms": conversion_ms,
            "agreement": {
                "maximum_absolute_error": float(absolute.max()),
                "mean_absolute_error": float(absolute.mean()),
            },
        },
    )
    print(output / "export.json")


if __name__ == "__main__":
    main()
