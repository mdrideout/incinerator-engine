#!/usr/bin/env python3
"""Export an accepted NR5-D checkpoint as an immutable NR5-E Core ML trial bundle."""

from __future__ import annotations

import argparse
import copy
import shutil
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.nn import functional

from title_renderer.artifacts import load_checkpoint
from title_renderer.dataset import TitleCorpusDataset
from title_renderer.inspect_candidate import inspect as inspect_candidate
from title_renderer.io import atomic_json, create_absent_absolute, environment_record, load_json, repository_record, require_existing_absolute, sha256_file
from title_renderer.models import SpatialTitleRendererConfig, create_spatial_model
from title_renderer.trial_bundle import CHANNELS, CONTINUOUS_PLANES, GLOBAL_CONTROLS, INPUT_EXTENT, INPUT_SCHEMA, MODEL_PACKAGE, TARGET_EXTENT, TRIAL_BUNDLE_KIND, TRIAL_BUNDLE_SCHEMA, inspect, package_files


class CoreMLExportModel(nn.Module):
    """Fixed-shape, numerically identical direct native model lowering."""

    def __init__(self, source: nn.Module) -> None:
        super().__init__()
        self.source = source

    def forward(
        self,
        continuous: torch.Tensor,
        semantic: torch.Tensor,
        instance: torch.Tensor,
        global_controls: torch.Tensor,
    ) -> torch.Tensor:
        model = self.source
        semantic_features = model.semantic_embedding(semantic).permute(0, 3, 1, 2)
        instance_features = model.instance_embedding(instance).permute(0, 3, 1, 2)
        controls = global_controls[:, :, None, None] * torch.ones_like(continuous[:, :1])
        low = torch.cat((continuous, semantic_features, instance_features, controls), dim=1)
        low = functional.silu(model.low_encoder(low))
        for block in model.context_blocks:
            low = block(low)
        structural = model.structural_encoder(
            torch.cat(
                (
                    continuous[:, 3:4],
                    continuous[:, 4:7],
                    continuous[:, 10:11],
                    semantic_features,
                    instance_features,
                ),
                dim=1,
            )
        )
        fused = functional.silu(model.fusion(torch.cat((low, structural), dim=1)))
        output_size = (TARGET_EXTENT[1], TARGET_EXTENT[0])
        appearance_features = functional.interpolate(
            model.direct_projection(fused),
            size=output_size,
            mode="bilinear",
            align_corners=False,
        )
        structural_features = functional.interpolate(
            model.output_structural_projection(structural),
            size=output_size,
            mode="nearest",
        )
        fused = functional.silu(
            model.output_fusion(torch.cat((appearance_features, structural_features), dim=1))
        )
        for block in model.output_blocks:
            fused = block(fused)
        base = functional.interpolate(continuous[:, :3], size=output_size, mode="bilinear", align_corners=False)
        return base + model.output(fused)


def vocabulary(value: dict[str, int]) -> list[dict[str, int]]:
    return [
        {"encoded": int(encoded), "index": int(index)}
        for encoded, index in sorted(value.items(), key=lambda item: int(item[1]))
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    run_root = require_existing_absolute(args.run, "--run")
    repository = require_existing_absolute(args.repository, "--repository")
    candidate = inspect_candidate(run_root)
    conclusion_path = run_root / "conclusion.json"
    conclusion = load_json(conclusion_path)
    if candidate.get("phase") != "NR5-D" or candidate.get("status") != "accepted":
        raise ValueError("NR5-E export requires the accepted NR5-D candidate")
    if conclusion.get("promotion_authorized") is not False:
        raise ValueError("NR5-E cannot export a promotion-ambiguous candidate")
    output = create_absent_absolute(args.output, "--output")
    try:
        run = load_json(run_root / "run.json")
        train_specification = load_json(run_root / run["train_dataset"])
        checkpoint_path = Path(run["checkpoint"]["path"])
        checkpoint = load_checkpoint(checkpoint_path)
        configuration = SpatialTitleRendererConfig(**checkpoint["model_configuration"])
        model = create_spatial_model(
            configuration,
            semantic_categories=len(train_specification["semantic_vocabulary"]),
            instance_categories=len(train_specification["instance_vocabulary"]),
            initialization_seed=int(checkpoint["initialization_seed"]),
        )
        model.load_state_dict(checkpoint["state_dict"])
        model.eval()
        export_model = CoreMLExportModel(copy.deepcopy(model)).eval()
        validation = TitleCorpusDataset(Path(train_specification["corpus_root"]), ("validation",))
        sample = validation[0]
        inputs = tuple(
            sample[name].unsqueeze(0)
            for name in ("continuous", "semantic", "instance", "global_controls")
        )
        with torch.inference_mode():
            accepted_output = model(*inputs)
            export_output = export_model(*inputs)
        wrapper_absolute = (accepted_output - export_output).abs()
        wrapper_maximum = float(wrapper_absolute.max())
        wrapper_mean = float(wrapper_absolute.mean())
        if wrapper_maximum != 0.0 or wrapper_mean != 0.0:
            raise ValueError("Core ML export wrapper changed accepted checkpoint output")
        traced = torch.jit.trace(export_model, inputs, strict=True)
        started = time.perf_counter()
        coreml_model = ct.convert(
            traced,
            convert_to="mlprogram",
            inputs=[
                ct.TensorType(name="continuous", shape=inputs[0].shape, dtype=np.float32),
                ct.TensorType(name="semantic", shape=inputs[1].shape, dtype=np.int32),
                ct.TensorType(name="instance", shape=inputs[2].shape, dtype=np.int32),
                ct.TensorType(name="global_controls", shape=inputs[3].shape, dtype=np.float32),
            ],
            outputs=[ct.TensorType(name="scene_color", dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS15,
            compute_precision=ct.precision.FLOAT32,
        )
        package = output / MODEL_PACKAGE
        coreml_model.save(str(package))
        conversion_ms = (time.perf_counter() - started) * 1000.0
        prediction = coreml_model.predict(
            {
                "continuous": inputs[0].numpy().astype(np.float32),
                "semantic": inputs[1].numpy().astype(np.int32),
                "instance": inputs[2].numpy().astype(np.int32),
                "global_controls": inputs[3].numpy().astype(np.float32),
            }
        )["scene_color"]
        coreml_absolute = np.abs(export_output.numpy() - np.asarray(prediction, dtype=np.float32))
        coreml_maximum = float(coreml_absolute.max())
        coreml_mean = float(coreml_absolute.mean())
        if coreml_maximum > 0.0001:
            raise ValueError(f"Core ML conversion agreement failed: {coreml_maximum}")
        source_root = output / "source"
        tool_sources = []
        title_renderer_root = Path(__file__).resolve().parent
        for source in (
            Path(__file__).resolve(),
            title_renderer_root / "trial_bundle.py",
            title_renderer_root / "artifacts.py",
            title_renderer_root / "dataset.py",
            title_renderer_root / "inspect_candidate.py",
            title_renderer_root / "io.py",
            title_renderer_root / "models" / "__init__.py",
            title_renderer_root / "models" / "spatial.py",
        ):
            relative = source.relative_to(repository)
            snapshot = source_root / relative
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, snapshot)
            tool_sources.append(
                {
                    "repository_path": str(relative),
                    "repository_sha256": sha256_file(source),
                    "snapshot": str(snapshot.relative_to(output)),
                    "snapshot_sha256": sha256_file(snapshot),
                    "bytes": snapshot.stat().st_size,
                }
            )
        manifest = {
            "schema": TRIAL_BUNDLE_SCHEMA,
            "kind": TRIAL_BUNDLE_KIND,
            "phase": "NR5-E",
            "status": "trial_only_unpromoted",
            "promotion_authorized": False,
            "purpose": "interactive spatial-candidate evaluation; never runtime game content",
            "source_candidate": {
                "run": str(run_root),
                "run_sha256": sha256_file(run_root / "run.json"),
                "checkpoint_sha256": sha256_file(checkpoint_path),
                "conclusion_sha256": sha256_file(conclusion_path),
                "external_pretrained_weights": False,
            },
            "model": {
                "format": "coreml_mlprogram_float32",
                "package": MODEL_PACKAGE,
                "files": package_files(package),
                "input_names": ["continuous", "semantic", "instance", "global_controls"],
                "output_name": "scene_color",
                "minimum_deployment_target": "macOS15",
                "compute_precision": "float32",
                "conversion_ms": conversion_ms,
            },
            "input": {
                "schema_name": INPUT_SCHEMA,
                "schema_version": 5,
                "extent": INPUT_EXTENT,
                "channels": CHANNELS,
                "continuous_planes": CONTINUOUS_PLANES,
                "global_controls": GLOBAL_CONTROLS,
            },
            "output": {
                "name": "scene_color",
                "extent": TARGET_EXTENT,
                "color_space": "linear_hdr_rgb",
                "developer_display_transform": "reinhard_then_linear_to_srgb",
            },
            "preprocessing": {
                "appearance": "rgba8_srgb_to_linear_piecewise; alpha_is_coverage",
                "linear_depth": "r_unorm8",
                "world_normal": "rgb_unorm8_times_2_minus_1",
                "motion": "rg_unorm8_times_2_minus_1; b_is_history_valid",
                "categorical_encoding": "rgb24_little_endian; undeclared_codes_map_to_background_and_are_counted",
                "semantic_vocabulary": vocabulary(train_specification["semantic_vocabulary"]),
                "instance_vocabulary": vocabulary(train_specification["instance_vocabulary"]),
                "control_minimum": train_specification["control_minimum"],
                "control_maximum": train_specification["control_maximum"],
            },
            "agreement": {
                "frame_id": sample["frame_id"],
                "export_wrapper_maximum_absolute_error": wrapper_maximum,
                "export_wrapper_mean_absolute_error": wrapper_mean,
                "coreml_maximum_absolute_error": coreml_maximum,
                "coreml_mean_absolute_error": coreml_mean,
                "admitted_coreml_maximum_absolute_error": 0.0001,
            },
            "repository": repository_record(repository),
            "environment": environment_record()
            | {"torch": torch.__version__, "coremltools": ct.__version__, "numpy": np.__version__},
            "tool_sources": tool_sources,
        }
        atomic_json(output / "bundle.json", manifest)
        inspected = inspect(output)
        atomic_json(output / "inspection.json", inspected)
    except Exception as error:
        atomic_json(output / "failure.json", {"schema": 1, "phase": "NR5-E", "error": str(error)})
        raise
    print(
        "NR5_E_TRIAL_BUNDLE_PASS "
        f"root={output} coreml_max_error={coreml_maximum:.8f} "
        f"coreml_mean_error={coreml_mean:.8f}"
    )


if __name__ == "__main__":
    main()
