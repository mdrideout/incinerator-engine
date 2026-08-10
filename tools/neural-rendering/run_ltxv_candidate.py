#!/usr/bin/env python3
"""Run and measure one immutable stock LTX-Video 2B MPS candidate."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable

import imageio.v2 as imageio
import psutil
import torch
import yaml
from huggingface_hub import hf_hub_download
from PIL import Image

from nr_common import atomic_json, create_new_directory, environment_record, load_json, sha256_file


CANDIDATE_SCHEMA = 2


def upstream_revision(path: Path) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=path, check=True, capture_output=True, text=True
    )
    return result.stdout.strip()


def install_timing_probe(records: list[dict[str, Any]]) -> None:
    from ltx_video.pipelines.pipeline_ltx_video import LTXMultiScalePipeline, LTXVideoPipeline

    def wrap(owner: type[Any], label: str) -> None:
        original: Callable[..., Any] = owner.__call__

        def timed(self: Any, *args: Any, **kwargs: Any) -> Any:
            if torch.backends.mps.is_available():
                torch.mps.synchronize()
            started = time.perf_counter()
            result = original(self, *args, **kwargs)
            if torch.backends.mps.is_available():
                torch.mps.synchronize()
            records.append({"label": label, "seconds": time.perf_counter() - started})
            return result

        owner.__call__ = timed

    wrap(LTXVideoPipeline, "ltx_video_pipeline")
    wrap(LTXMultiScalePipeline, "ltx_multiscale_pipeline")


class MemorySampler:
    def __init__(self) -> None:
        self.process = psutil.Process()
        self.peak_rss = self.process.memory_info().rss
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._sample, daemon=True)

    def _sample(self) -> None:
        while not self.stop_event.wait(0.02):
            self.peak_rss = max(self.peak_rss, self.process.memory_info().rss)

    def __enter__(self) -> "MemorySampler":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.stop_event.set()
        self.thread.join()
        self.peak_rss = max(self.peak_rss, self.process.memory_info().rss)


def make_contact_sheet(video_path: Path, output_path: Path) -> None:
    reader = imageio.get_reader(video_path)
    frames = [Image.fromarray(frame).convert("RGB") for frame in reader]
    reader.close()
    columns = min(3, len(frames))
    rows = (len(frames) + columns - 1) // columns
    width, height = frames[0].size
    sheet = Image.new("RGB", (columns * width, rows * height))
    for index, frame in enumerate(frames):
        sheet.paste(frame, ((index % columns) * width, (index // columns) * height))
    sheet.save(output_path)


def make_comparison_sheet(
    source_frames: list[Path], video_path: Path, output_path: Path
) -> None:
    reader = imageio.get_reader(video_path)
    generated = [Image.fromarray(frame).convert("RGB") for frame in reader]
    reader.close()
    if len(source_frames) != len(generated):
        raise RuntimeError(
            f"source/generated frame count mismatch: {len(source_frames)} != {len(generated)}"
        )
    sources = [Image.open(path).convert("RGB") for path in source_frames]
    try:
        width, height = generated[0].size
        if any(frame.size != (width, height) for frame in sources):
            raise RuntimeError("source/generated frame extent mismatch")
        columns = min(3, len(generated))
        rows = (len(generated) + columns - 1) // columns
        sheet = Image.new("RGB", (columns * width, rows * height * 2))
        for index, (source, output) in enumerate(zip(sources, generated, strict=True)):
            x = (index % columns) * width
            y = (index // columns) * height * 2
            sheet.paste(source, (x, y))
            sheet.paste(output, (x, y + height))
        sheet.save(output_path)
    finally:
        for source in sources:
            source.close()


def run(args: argparse.Namespace) -> dict[str, Any]:
    if not torch.backends.mps.is_available():
        raise RuntimeError("NR-0003 requires Apple MPS")
    repo_root = args.repo.resolve()
    upstream = args.upstream.resolve()
    sequence_path = args.sequence.resolve()
    config_path = args.config.resolve()
    prompt_path = args.prompt.resolve()
    sequence = load_json(sequence_path)
    if sequence.get("schema") != 1 or sequence.get("status") != "complete":
        raise ValueError("candidate input must be a complete LTX sequence schema 1")
    input_video = Path(str(sequence["video"]))
    if sha256_file(input_video) != sequence.get("video_sha256"):
        raise ValueError("candidate input video digest mismatch")
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if config.get("checkpoint_path") != "ltxv-2b-0.9.8-distilled.safetensors":
        raise ValueError("NR-0003 accepts only the declared LTX-Video 2B distilled checkpoint")
    if config.get("prompt_enhancement_words_threshold") != 0:
        raise ValueError("NR-0003 forbids ambient prompt enhancement")
    prompt = " ".join(prompt_path.read_text(encoding="utf-8").split())
    output_root = create_new_directory(args.output, "LTX candidate output")
    inputs_dir = output_root / "inputs"
    inputs_dir.mkdir()
    config_snapshot = inputs_dir / "pipeline.yaml"
    prompt_snapshot = inputs_dir / "style-prompt.txt"
    shutil.copy2(config_path, config_snapshot)
    shutil.copy2(prompt_path, prompt_snapshot)
    generated_dir = output_root / "generated"
    generated_dir.mkdir()

    checkpoint_path = Path(
        hf_hub_download(repo_id="Lightricks/LTX-Video", filename=config["checkpoint_path"])
    )
    license_path = Path(
        hf_hub_download(
            repo_id="Lightricks/LTX-Video", filename="LTX-Video-Open-Weights-License-0.X.txt"
        )
    )
    upscaler_name = config.get("spatial_upscaler_model_path")
    upscaler_path = (
        Path(hf_hub_download(repo_id="Lightricks/LTX-Video", filename=upscaler_name))
        if upscaler_name
        else None
    )
    partial = {
        "schema": CANDIDATE_SCHEMA,
        "status": "running",
        "purpose": "stock RGB video-to-video capability/performance baseline before Incinerator dense-control training",
        "not_promotion_eligible": True,
        "limitations": [
            "stock LTX consumes appearance RGB rather than the full Incinerator G-buffer ABI",
            "the existing conventional renderer is not a high-fidelity training target",
            "cold load includes the stock text encoder; title-fixed embedding extraction remains follow-up work",
        ],
        "sequence_manifest": str(sequence_path),
        "sequence_manifest_sha256": sha256_file(sequence_path),
        "configuration": {
            "source": str(config_path),
            "source_sha256": sha256_file(config_path),
            "snapshot": str(config_snapshot),
            "snapshot_sha256": sha256_file(config_snapshot),
        },
        "prompt": {
            "source": str(prompt_path),
            "source_sha256": sha256_file(prompt_path),
            "snapshot": str(prompt_snapshot),
            "snapshot_sha256": sha256_file(prompt_snapshot),
        },
        "upstream": {"path": str(upstream), "revision": upstream_revision(upstream)},
        "model": {
            "repository": "Lightricks/LTX-Video",
            "checkpoint": str(checkpoint_path),
            "checkpoint_sha256": sha256_file(checkpoint_path),
            "spatial_upscaler": str(upscaler_path) if upscaler_path else None,
            "spatial_upscaler_sha256": sha256_file(upscaler_path) if upscaler_path else None,
            "license": {
                "name": "LTXV Open Weights License 0.X",
                "artifact": str(license_path),
                "artifact_sha256": sha256_file(license_path),
                "promotion_and_distribution_review_required": True,
            },
        },
        "environment": environment_record(repo_root),
        "invocation": {
            "seed": args.seed,
            "extent": sequence["extent"],
            "frames": sequence["selection"]["frame_count"],
            "fps": sequence["fps"],
            "input_media_path": str(input_video),
            "image_cond_noise_scale": args.image_cond_noise_scale,
        },
    }
    atomic_json(output_root / "candidate.json", partial)

    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    from ltx_video.inference import InferenceConfig, infer

    timing_records: list[dict[str, Any]] = []
    install_timing_probe(timing_records)
    started = time.perf_counter()
    try:
        with MemorySampler() as memory:
            infer(
                InferenceConfig(
                    prompt=prompt,
                    output_path=generated_dir,
                    pipeline_config=str(config_snapshot),
                    seed=args.seed,
                    height=int(sequence["extent"][1]),
                    width=int(sequence["extent"][0]),
                    num_frames=int(sequence["selection"]["frame_count"]),
                    frame_rate=int(sequence["fps"]),
                    input_media_path=str(input_video),
                    image_cond_noise_scale=args.image_cond_noise_scale,
                )
            )
    except BaseException as error:
        failed = dict(partial)
        failed.update(
            {
                "status": "failed",
                "failure": {"type": type(error).__name__, "message": str(error)},
                "cold_end_to_end_seconds": time.perf_counter() - started,
            }
        )
        atomic_json(output_root / "candidate.json", failed)
        raise
    cold_seconds = time.perf_counter() - started
    try:
        outputs = list(generated_dir.glob("*.mp4"))
        if len(outputs) != 1:
            raise RuntimeError(f"expected one generated video, found {len(outputs)}")
        output_video = outputs[0]
        contact_sheet_path = output_root / "contact-sheet.png"
        make_contact_sheet(output_video, contact_sheet_path)
        comparison_sheet_path = output_root / "comparison-sheet.png"
        source_frames = [
            Path(str(frame["materialized_frame"])) for frame in sequence["frames"]
        ]
        make_comparison_sheet(source_frames, output_video, comparison_sheet_path)
        multiscale = [
            value for value in timing_records if value["label"] == "ltx_multiscale_pipeline"
        ]
        base = [value for value in timing_records if value["label"] == "ltx_video_pipeline"]
        if multiscale:
            if len(multiscale) != 1:
                raise RuntimeError("expected at most one measured multiscale pipeline invocation")
            warm_seconds = float(multiscale[0]["seconds"])
        elif len(base) == 1:
            warm_seconds = float(base[0]["seconds"])
        else:
            raise RuntimeError("expected one measured top-level LTX pipeline invocation")
        frames = int(sequence["selection"]["frame_count"])
        complete = dict(partial)
        complete.update(
            {
                "status": "complete",
                "result": "baseline",
                "generated_video": str(output_video),
                "generated_video_sha256": sha256_file(output_video),
                "contact_sheet": str(contact_sheet_path),
                "contact_sheet_sha256": sha256_file(contact_sheet_path),
                "comparison_sheet": str(comparison_sheet_path),
                "comparison_sheet_sha256": sha256_file(comparison_sheet_path),
                "measurements": {
                    "cold_end_to_end_seconds": cold_seconds,
                    "warm_pipeline_seconds": warm_seconds,
                    "warm_effective_fps": frames / warm_seconds,
                    "peak_process_rss_bytes": memory.peak_rss,
                    "pipeline_calls": timing_records,
                },
            }
        )
        atomic_json(output_root / "candidate.json", complete)
        return complete
    except BaseException as error:
        failed = dict(partial)
        failed.update(
            {
                "status": "failed",
                "failure": {"type": type(error).__name__, "message": str(error)},
                "cold_end_to_end_seconds": cold_seconds,
            }
        )
        atomic_json(output_root / "candidate.json", failed)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--upstream", required=True, type=Path)
    parser.add_argument("--sequence", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--prompt", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=1783)
    parser.add_argument("--image-cond-noise-scale", type=float, default=0.35)
    args = parser.parse_args()
    result = run(args)
    measurements = result["measurements"]
    print(
        "NR0003_LTX_CANDIDATE_PASS "
        f"warm_fps={measurements['warm_effective_fps']:.3f} "
        f"warm_seconds={measurements['warm_pipeline_seconds']:.3f} "
        f"cold_seconds={measurements['cold_end_to_end_seconds']:.3f}"
    )


if __name__ == "__main__":
    main()
