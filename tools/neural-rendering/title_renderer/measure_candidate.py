#!/usr/bin/env python3
"""Append read-only NR5-D stress/export measurements to a concluded candidate."""

from __future__ import annotations

import argparse
import platform
import resource
import shutil
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

from title_renderer.artifacts import load_checkpoint
from title_renderer.dataset import TitleCorpusDataset
from title_renderer.evaluation import model_output, synchronize
from title_renderer.io import atomic_json, load_json, sha256_file
from title_renderer.models import SpatialTitleRendererConfig, create_spatial_model


def peak_rss_bytes() -> int:
    value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return value if platform.system() == "Darwin" else value * 1024


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--stress-corpus", required=True, type=Path)
    args = parser.parse_args()
    root = args.run.resolve()
    corpus = args.stress_corpus.resolve()
    output = root / "nr5-d-measurements.json"
    if output.exists():
        raise ValueError("NR5-D supplemental measurements are immutable and already exist")
    run = load_json(root / "run.json")
    rf9 = run.get("phase") == "RF9-D/F"
    rf10 = run.get("phase") == "RF10-D/E"
    conclusion_path = root / "conclusion.json"
    conclusion = load_json(conclusion_path)
    expected_next = "RF10 external native-720p playable trial" if rf10 else ("RF9 external playable trial" if rf9 else "NR6")
    if conclusion.get("status") != "accepted" or conclusion.get("next_phase_authorized") != expected_next:
        raise ValueError("measurements require an accepted NR5-D conclusion")
    training_spec = load_json(root / run["train_dataset"])
    dataset = TitleCorpusDataset(
        corpus,
        ("stress",),
        reference_specification=training_spec,
    )
    if dataset.specification.corpus_manifest_sha256 != conclusion["stress_corpus_manifest_sha256"]:
        raise ValueError("measurement corpus differs from the concluded fresh stress cohort")
    if (
        dataset.specification.semantic_vocabulary
        != {int(key): value for key, value in training_spec["semantic_vocabulary"].items()}
        or dataset.specification.instance_vocabulary
        != {int(key): value for key, value in training_spec["instance_vocabulary"].items()}
    ):
        raise ValueError("measurement preprocessing vocabulary differs from training")
    configuration = load_json(root / run["configuration"])
    model = create_spatial_model(
        SpatialTitleRendererConfig(**configuration["model"]),
        semantic_categories=len(dataset.specification.semantic_vocabulary),
        instance_categories=len(dataset.specification.instance_vocabulary),
        initialization_seed=int(configuration["initialization_seed"]),
    )
    checkpoint = load_checkpoint(Path(run["checkpoint"]["path"]))
    model.load_state_dict(checkpoint["state_dict"])
    model.eval()
    exported = torch.jit.load(load_json(root / run["export"])["path"]).eval()
    loader = DataLoader(dataset, batch_size=1, shuffle=False, num_workers=0)
    export_maximum = 0.0
    export_total = 0.0
    export_values = 0
    with torch.inference_mode():
        for batch in loader:
            inputs = tuple(batch[name] for name in ("continuous", "semantic", "instance", "global_controls"))
            expected = model(*inputs)
            actual = exported(*inputs)
            delta = (expected - actual).abs()
            export_maximum = max(export_maximum, float(delta.max()))
            export_total += float(delta.sum())
            export_values += delta.numel()
    if not torch.backends.mps.is_available():
        raise ValueError("NR5-D measurements require the declared Apple MPS host")
    device = torch.device("mps")
    model = model.to(device)
    timings = []
    with torch.inference_mode():
        for batch in loader:
            synchronize(device)
            started = time.perf_counter()
            model_output(model, batch, device, "model")
            synchronize(device)
            timings.append((time.perf_counter() - started) * 1000.0)
    sample = next(iter(loader))
    model.train()
    prediction = model_output(model, sample, device, "model")
    sample["target"].to(device).sub(prediction).abs().mean().backward()
    synchronize(device)
    source = Path(__file__).resolve()
    snapshot = root / "source" / "post-conclusion" / source.name
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, snapshot)
    atomic_json(
        output,
        {
            "schema": 1,
            "experiment": "RF10" if rf10 else ("RF9" if rf9 else "NR-0005"),
            "phase": "RF10-H" if rf10 else ("RF9-H" if rf9 else "NR5-D"),
            "kind": "append_only_post_conclusion_measurements",
            "conclusion_sha256": sha256_file(conclusion_path),
            "checkpoint_sha256": run["checkpoint"]["sha256"],
            "stress_corpus_manifest_sha256": dataset.specification.corpus_manifest_sha256,
            "frames": len(dataset),
            "export_all_stress_frames": {
                "maximum_absolute_agreement": export_maximum,
                "mean_absolute_agreement": export_total / export_values,
            },
            "mps_full_frame_inference_ms": {
                "minimum": min(timings),
                "median": float(np.percentile(timings, 50)),
                "p95": float(np.percentile(timings, 95)),
                "maximum": max(timings),
                "scope": "offline PyTorch full-frame batch; cold compilation outliers retained; not installed runtime",
            },
            "representative_forward_backward_process_peak_rss_bytes": peak_rss_bytes(),
            "recorded_training_run_peak_process_rss_bytes": None,
            "memory_limit": "the canonical training process ended before RSS instrumentation; no retrospective value is invented",
            "tool_source": {
                "source": str(source),
                "source_sha256": sha256_file(source),
                "snapshot": str(snapshot.relative_to(root)),
                "snapshot_sha256": sha256_file(snapshot),
                "bytes": snapshot.stat().st_size,
            },
            "promotion_authorized": False,
        },
    )
    print(f"NR5_D_MEASUREMENTS_COMPLETE frames={len(dataset)} root={root}")


if __name__ == "__main__":
    main()
