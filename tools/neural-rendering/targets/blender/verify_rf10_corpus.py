#!/usr/bin/env python3
"""Manufacture the fresh RF10 native 256x144 to 1280x720 corpus."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from inspect_sequence import inspect as inspect_sequence
from nr4_common import atomic_json, create_absent, load_json, sha256_file


SEQUENCES = (
    ("overfit", "rf10-overfit-urban-day-0001", "nr4-sequence", "urban-day", "controlled fit"),
    ("train", "rf10-train-urban-day-0001", "nr4-corpus-train", "urban-day", "baseline layout and material response"),
    ("train", "rf10-train-urban-copper-material-0001", "nr4-corpus-train", "urban-copper-material", "controlled copper material ambiguity"),
    ("train", "rf10-train-urban-wet-material-0001", "nr4-corpus-train", "urban-wet-material", "controlled wet material ambiguity"),
    ("train", "rf10-train-copper-evening-0001", "orbit-wide", "copper-evening", "independent layout and reflective evening surfaces"),
    ("train", "rf10-train-wet-night-0001", "elevated-sweep", "wet-night", "independent wet-night layout"),
    ("validation", "rf10-validation-urban-day-0001", "nr4-corpus-validation", "urban-day", "held-out camera and causal state"),
    ("validation", "rf10-validation-urban-copper-material-0001", "nr4-corpus-validation", "urban-copper-material", "held-out copper ambiguity"),
    ("validation", "rf10-validation-urban-wet-material-0001", "nr4-corpus-validation", "urban-wet-material", "held-out wet ambiguity"),
    ("validation", "rf10-validation-copper-evening-0001", "top-down", "copper-evening", "held-out elevated composition"),
    ("validation", "rf10-validation-wet-night-0001", "nr4-corpus-test", "wet-night", "held-out wet-night camera"),
    ("test", "rf10-test-urban-day-sealed-0001", "camera-cut", "urban-day", "sealed camera reset"),
    ("test", "rf10-test-copper-evening-sealed-0001", "fast-orbit", "copper-evening", "sealed fast view change"),
    ("test", "rf10-test-wet-night-sealed-0001", "resize-cycle", "wet-night", "sealed resize event"),
    ("stress", "rf10-stress-urban-day-near-0001", "nr4-corpus-stress-near", "urban-day", "near-edge geometry"),
    ("stress", "rf10-stress-copper-evening-high-0001", "nr4-corpus-stress-high", "copper-evening", "high-angle reflective response"),
    ("stress", "rf10-stress-wet-night-high-0001", "nr4-corpus-stress-high", "wet-night", "high-angle wet and emissive response"),
)


def verify_material_ambiguity(reference: Path, candidate: Path) -> dict[str, object]:
    reference_frames = sorted((reference / "source/capture/frames").glob("frame-*.json"))
    candidate_frames = sorted((candidate / "source/capture/frames").glob("frame-*.json"))
    if not reference_frames or [path.name for path in reference_frames] != [path.name for path in candidate_frames]:
        raise ValueError("RF10 material ambiguity cohorts do not own identical frame selections")
    target_differences = 0
    for reference_path, candidate_path in zip(reference_frames, candidate_frames, strict=True):
        reference_frame = load_json(reference_path)
        candidate_frame = load_json(candidate_path)
        reference_channels = {channel["name"]: channel["raw_sha256"] for channel in reference_frame["channels"]}
        candidate_channels = {channel["name"]: channel["raw_sha256"] for channel in candidate_frame["channels"]}
        if reference_channels != candidate_channels:
            raise ValueError(f"RF10 material ambiguity changed a cheap raster: {candidate_path.name}")
        for name in ("input_size", "paired_target_size", "camera", "effects"):
            if reference_frame[name] != candidate_frame[name]:
                raise ValueError(f"RF10 material ambiguity changed {name}: {candidate_path.name}")
        reference_controls = reference_frame["global_controls"]["values"]
        candidate_controls = candidate_frame["global_controls"]["values"]
        for name in ("sun_strength", "world_strength", "local_light_strength", "emissive_strength"):
            if reference_controls[name] != candidate_controls[name]:
                raise ValueError(f"RF10 material ambiguity changed {name}: {candidate_path.name}")
        if reference_controls["material_palette"] == candidate_controls["material_palette"]:
            raise ValueError(f"RF10 material ambiguity did not change its palette: {candidate_path.name}")
        reference_target = reference / "targets" / reference_path.stem / "target.exr"
        candidate_target = candidate / "targets" / candidate_path.stem / "target.exr"
        target_differences += sha256_file(reference_target) != sha256_file(candidate_target)
    if target_differences != len(reference_frames):
        raise ValueError("RF10 material ambiguity did not change every rich target")
    return {
        "reference": reference.name,
        "candidate": candidate.name,
        "frames": len(reference_frames),
        "cheap_rasters_identical": True,
        "camera_lighting_geometry_identical": True,
        "material_palette_changed": True,
        "rich_targets_changed": target_differences,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--blender", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output.resolve()
    if args.resume:
        if not output.is_dir() or load_json(output / "acceptance.json").get("status") != "partial":
            raise ValueError("RF10 resume requires an existing partial root")
    else:
        output = create_absent(output, "RF10 corpus root")
    runs = output / "runs"
    runs.mkdir(exist_ok=args.resume)
    acceptance = output / "acceptance.json"
    if not args.resume:
        atomic_json(acceptance, {
            "schema": 1,
            "status": "partial",
            "phase": "RF10-C",
            "purpose": "fresh multi-cause native 256x144 to 1280x720 whole-sequence corpus",
            "preexisting_pixels_reused": False,
        })

    tools = repo / "tools/neural-rendering/targets/blender"
    sequence_arguments: list[str] = []
    run_records = []
    for split, sequence, camera_path, variant, reason in SEQUENCES:
        run_root = runs / sequence
        if run_root.exists():
            if not args.resume:
                raise FileExistsError(f"RF10 run already exists: {run_root}")
            inspect_sequence(run_root, "NR4-D")
        else:
            subprocess.run([
                sys.executable, str(tools / "run_nr4_c.py"),
                "--validation", str(args.validation.resolve()),
                "--content-root", str(args.content_root.resolve()),
                "--repo", str(repo), "--blender", str(args.blender.resolve()),
                "--output", str(run_root), "--phase", "NR4-D", "--cohort", split,
                "--sequence", sequence, "--camera-path", camera_path,
                "--fixture-variant", variant,
            ], cwd=repo, check=True)
        sequence_arguments.extend(["--sequence", f"{split}={run_root}"])
        run_records.append({
            "split": split, "sequence": sequence, "camera_path": camera_path,
            "fixture_variant": variant, "cause": reason,
            "root": str(run_root.relative_to(output)),
            "run_manifest_sha256": sha256_file(run_root / "run.json"),
        })

    ambiguity = []
    for split in ("train", "validation"):
        reference = runs / f"rf10-{split}-urban-day-0001"
        for material in ("copper", "wet"):
            ambiguity.append(verify_material_ambiguity(
                reference, runs / f"rf10-{split}-urban-{material}-material-0001"
            ))
    corpus = output / "corpus"
    subprocess.run([
        sys.executable, str(tools / "assemble_nr4_d_corpus.py"),
        *sequence_arguments, "--output", str(corpus),
    ], cwd=repo, check=True)
    subprocess.run([
        sys.executable, str(tools / "inspect_nr4_d_corpus.py"), str(corpus)
    ], cwd=repo, check=True)
    manifest = load_json(corpus / "corpus.json")
    atomic_json(acceptance, {
        "schema": 1, "status": "complete", "phase": "RF10-C",
        "purpose": "fresh multi-cause native 256x144 to 1280x720 whole-sequence corpus",
        "runs": run_records, "material_ambiguity": ambiguity,
        "corpus": "corpus/corpus.json", "corpus_sha256": sha256_file(corpus / "corpus.json"),
        "frame_count": manifest["frame_count"], "sequence_count": manifest["sequence_count"],
        "splits": manifest["splits"], "review": "corpus/review/nr4-d-corpus-review.png",
        "test_pixels_in_review": False, "preexisting_pixels_reused": False,
        "model_training": False,
    })
    print(output)


if __name__ == "__main__":
    main()
