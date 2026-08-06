#!/usr/bin/env python3
"""Measure fixed-shape Core ML prediction independently of the game runtime."""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import coremltools as ct
import numpy as np

from nr_common import atomic_json, require_absolute


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
    parser.add_argument("--input-width", required=True, type=int)
    parser.add_argument("--input-height", required=True, type=int)
    parser.add_argument("--compute-units", choices=COMPUTE_UNITS, default="all")
    return parser.parse_args()


def main() -> None:
    args = arguments()
    model_path = require_absolute(args.model, "--model")
    output = require_absolute(args.output, "--output")
    if output.exists():
        raise FileExistsError(f"--output already exists: {output}")
    if min(args.iterations, args.warmup, args.input_width, args.input_height) < 0:
        raise ValueError("iteration and dimension arguments cannot be negative")
    if args.iterations == 0 or args.input_width == 0 or args.input_height == 0:
        raise ValueError("iterations and dimensions must be positive")
    load_started = time.perf_counter()
    model = ct.models.MLModel(str(model_path), compute_units=COMPUTE_UNITS[args.compute_units])
    load_ms = (time.perf_counter() - load_started) * 1000.0
    sample = np.random.default_rng(20260805).random(
        (1, 3, args.input_height, args.input_width), dtype=np.float32
    ).astype(np.float16)
    for _ in range(args.warmup):
        model.predict({"low_resolution": sample})
    timings = []
    for _ in range(args.iterations):
        started = time.perf_counter()
        model.predict({"low_resolution": sample})
        timings.append((time.perf_counter() - started) * 1000.0)
    atomic_json(
        output,
        {
            "schema": 1,
            "status": "complete",
            "model": str(model_path),
            "compute_units": args.compute_units,
            "input_shape_nchw": [1, 3, args.input_height, args.input_width],
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
        },
    )
    print(output)


if __name__ == "__main__":
    main()
