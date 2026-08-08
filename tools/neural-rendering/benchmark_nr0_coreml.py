#!/usr/bin/env python3
"""Benchmark the fixed-shape NR0-C Core ML candidate independently of runtime."""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import coremltools as ct
import numpy as np

from nr0_dataset import MODEL_PLANES
from nr_common import atomic_json, environment_record, require_absolute, sha256_file


COMPUTE_UNITS = {
    "all": ct.ComputeUnit.ALL,
    "cpu_and_gpu": ct.ComputeUnit.CPU_AND_GPU,
    "cpu_and_ne": ct.ComputeUnit.CPU_AND_NE,
    "cpu_only": ct.ComputeUnit.CPU_ONLY,
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--iterations", required=True, type=int)
    parser.add_argument("--warmup", required=True, type=int)
    parser.add_argument("--compute-units", choices=COMPUTE_UNITS, default="all")
    return parser.parse_args()


def main() -> None:
    args = arguments()
    model_path = require_absolute(args.model, "--model")
    output = require_absolute(args.output, "--output")
    if output.exists():
        raise FileExistsError(f"--output already exists: {output}")
    if args.iterations <= 0 or args.warmup < 0:
        raise ValueError("iterations must be positive and warmup cannot be negative")
    load_started = time.perf_counter()
    model = ct.models.MLModel(str(model_path), compute_units=COMPUTE_UNITS[args.compute_units])
    load_ms = (time.perf_counter() - load_started) * 1000.0
    description = model.get_spec().description
    input_feature = next(feature for feature in description.input if feature.name == "neural_inputs")
    shape = tuple(int(value) for value in input_feature.type.multiArrayType.shape)
    if shape != (1, len(MODEL_PLANES), 225, 400):
        raise ValueError(f"unexpected candidate input shape: {shape}")
    sample = np.random.default_rng(20260806).random(shape, dtype=np.float32).astype(np.float16)
    for _ in range(args.warmup):
        model.predict({"neural_inputs": sample})
    timings = []
    for _ in range(args.iterations):
        started = time.perf_counter()
        model.predict({"neural_inputs": sample})
        timings.append((time.perf_counter() - started) * 1000.0)
    atomic_json(
        output,
        {
            "schema": 2,
            "status": "complete",
            "model": str(model_path),
            "model_manifest_sha256": sha256_file(model_path / "Manifest.json"),
            "compute_units": args.compute_units,
            "input_shape_nchw": list(shape),
            "load_ms": load_ms,
            "warmup": args.warmup,
            "iterations": args.iterations,
            "prediction_ms": {
                "minimum": float(np.min(timings)),
                "p50": float(np.percentile(timings, 50)),
                "p95": float(np.percentile(timings, 95)),
                "p99": float(np.percentile(timings, 99)),
                "maximum": float(np.max(timings)),
                "mean": float(np.mean(timings)),
            },
            "environment": environment_record(Path(__file__).resolve().parents[2]),
        },
    )
    print(output)


if __name__ == "__main__":
    main()
