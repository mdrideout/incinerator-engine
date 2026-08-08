#!/usr/bin/env python3
"""Export one immutable NR0-C checkpoint as a fixed-shape Core ML candidate."""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

from nr0_dataset import MODEL_PLANES, Nr0Dataset
from nr0_model import checkpoint_model
from nr_common import atomic_json, create_new_directory, environment_record, require_absolute, sha256_file


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = arguments()
    checkpoint_path = require_absolute(args.checkpoint, "--checkpoint")
    dataset_path = require_absolute(args.dataset, "--dataset")
    output = create_new_directory(args.output, "--output")
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    model = checkpoint_model(checkpoint).eval()
    dataset = Nr0Dataset(dataset_path, "test")
    sample, _target, frame_id = dataset[0]
    example = sample.unsqueeze(0)
    if example.shape[1] != len(MODEL_PLANES):
        raise ValueError("dataset input ABI does not match the model")
    traced = torch.jit.trace(model, example)
    started = time.perf_counter()
    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="neural_inputs", shape=example.shape, dtype=np.float16)],
        outputs=[ct.TensorType(name="scene_color", dtype=np.float16)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
    )
    package_path = output / "nr0-spatial.mlpackage"
    coreml_model.save(str(package_path))
    conversion_ms = (time.perf_counter() - started) * 1000.0

    input_array = example.numpy().astype(np.float16)
    with torch.inference_mode():
        torch_output = model(torch.from_numpy(input_array.astype(np.float32))).numpy()
    prediction = coreml_model.predict({"neural_inputs": input_array})
    coreml_output = np.asarray(prediction["scene_color"], dtype=np.float32)
    absolute = np.abs(torch_output - coreml_output)
    repo_root = Path(__file__).resolve().parents[2]
    atomic_json(
        output / "export.json",
        {
            "schema": 2,
            "status": "candidate_unpromoted",
            "experiment": "nr-0002-multichannel-spatial-baseline",
            "checkpoint": str(checkpoint_path),
            "checkpoint_sha256": sha256_file(checkpoint_path),
            "dataset_manifest": str(dataset_path),
            "dataset_sha256": sha256_file(dataset_path),
            "agreement_frame_id": frame_id,
            "package": str(package_path),
            "package_file_digests": {
                str(path.relative_to(package_path)): sha256_file(path)
                for path in sorted(package_path.rglob("*"))
                if path.is_file()
            },
            "input_name": "neural_inputs",
            "input_planes": list(MODEL_PLANES),
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
            "promotion": "not selected; NR0-E owns promotion",
            "tool_sources": {
                str(path.relative_to(repo_root)): sha256_file(path)
                for path in (
                    Path(__file__).resolve(),
                    repo_root / "tools/neural-rendering/nr0_dataset.py",
                    repo_root / "tools/neural-rendering/nr0_model.py",
                    repo_root / "tools/neural-rendering/nr_common.py",
                )
            },
            "environment": environment_record(repo_root),
        },
    )
    print(output / "export.json")


if __name__ == "__main__":
    main()
