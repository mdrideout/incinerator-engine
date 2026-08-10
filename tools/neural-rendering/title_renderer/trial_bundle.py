"""NR5-E Core ML trial-bundle contracts shared by exporter and inspector."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from title_renderer.io import load_json, sha256_file


TRIAL_BUNDLE_SCHEMA = 1
TRIAL_BUNDLE_KIND = "incinerator.nr5-e.coreml-trial-bundle"
MODEL_PACKAGE = "model.mlpackage"
INPUT_SCHEMA = "incinerator.neural-input.v3"
INPUT_EXTENT = [160, 90]
TARGET_EXTENT = [400, 225]
CONTINUOUS_PLANES = [
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
]
CHANNELS = ["appearance", "linear-depth", "world-normal", "motion", "semantic", "instance"]
GLOBAL_CONTROLS = ["sun_strength", "world_strength", "local_light_strength", "emissive_strength"]


def package_files(package: Path) -> list[dict[str, Any]]:
    return [
        {
            "path": str(path.relative_to(package)),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        for path in sorted(package.rglob("*"))
        if path.is_file()
    ]


def inspect(root: Path) -> dict[str, Any]:
    root = root.resolve()
    manifest_path = root / "bundle.json"
    manifest = load_json(manifest_path)
    if (
        manifest.get("schema") != TRIAL_BUNDLE_SCHEMA
        or manifest.get("kind") != TRIAL_BUNDLE_KIND
        or manifest.get("status") != "trial_only_unpromoted"
        or manifest.get("promotion_authorized") is not False
    ):
        raise ValueError("unsupported or promotion-ambiguous NR5-E trial bundle")
    model = manifest.get("model", {})
    package = root / str(model.get("package", ""))
    if not package.is_dir() or model.get("package") != MODEL_PACKAGE:
        raise ValueError("NR5-E Core ML package is missing or renamed")
    declared = model.get("files")
    if not isinstance(declared, list) or not declared:
        raise ValueError("NR5-E Core ML package has no file inventory")
    actual_paths: set[str] = set()
    for record in declared:
        relative = str(record.get("path", ""))
        path = package / relative
        if (
            not relative
            or relative.startswith("/")
            or ".." in Path(relative).parts
            or not path.is_file()
            or path.stat().st_size != int(record.get("bytes", -1))
            or sha256_file(path) != record.get("sha256")
        ):
            raise ValueError(f"NR5-E Core ML package file drifted: {relative}")
        actual_paths.add(relative)
    discovered = {
        str(path.relative_to(package))
        for path in package.rglob("*")
        if path.is_file()
    }
    if actual_paths != discovered:
        raise ValueError("NR5-E Core ML package inventory is incomplete")
    input_contract = manifest.get("input", {})
    if (
        input_contract.get("schema_name") != INPUT_SCHEMA
        or input_contract.get("schema_version") != 3
        or input_contract.get("extent") != INPUT_EXTENT
        or input_contract.get("channels") != CHANNELS
        or input_contract.get("continuous_planes") != CONTINUOUS_PLANES
        or input_contract.get("global_controls") != GLOBAL_CONTROLS
    ):
        raise ValueError("NR5-E input ABI drifted")
    output = manifest.get("output", {})
    if output.get("extent") != TARGET_EXTENT or output.get("name") != "scene_color":
        raise ValueError("NR5-E output ABI drifted")
    preprocessing = manifest.get("preprocessing", {})
    for name in ("semantic_vocabulary", "instance_vocabulary"):
        vocabulary = preprocessing.get(name)
        if not isinstance(vocabulary, list) or not vocabulary or vocabulary[0] != {"encoded": 0, "index": 0}:
            raise ValueError(f"NR5-E {name} has no exact background entry")
        if [entry.get("index") for entry in vocabulary] != list(range(len(vocabulary))):
            raise ValueError(f"NR5-E {name} indices are not dense")
    for name in ("control_minimum", "control_maximum"):
        if not isinstance(preprocessing.get(name), list) or len(preprocessing[name]) != 4:
            raise ValueError(f"NR5-E {name} drifted")
    source = manifest.get("source_candidate", {})
    for name in ("run", "run_sha256", "checkpoint_sha256", "conclusion_sha256"):
        if not source.get(name):
            raise ValueError(f"NR5-E source candidate is missing {name}")
    tool_sources = manifest.get("tool_sources")
    if not isinstance(tool_sources, list) or not tool_sources:
        raise ValueError("NR5-E trial bundle has no executing tool-source snapshots")
    for record in tool_sources:
        relative = str(record.get("snapshot", ""))
        snapshot = root / relative
        digest = record.get("snapshot_sha256")
        if (
            not relative
            or relative.startswith("/")
            or ".." in Path(relative).parts
            or not snapshot.is_file()
            or snapshot.stat().st_size != int(record.get("bytes", -1))
            or sha256_file(snapshot) != digest
            or record.get("repository_sha256") != digest
        ):
            raise ValueError(f"NR5-E tool-source snapshot drifted: {relative}")
    agreement = manifest.get("agreement", {})
    if agreement.get("export_wrapper_maximum_absolute_error") != 0.0:
        raise ValueError("NR5-E export wrapper is not equivalent to the accepted checkpoint")
    if float(agreement.get("coreml_maximum_absolute_error", float("inf"))) > 0.0001:
        raise ValueError("NR5-E Core ML conversion exceeds the admitted agreement tolerance")
    return {
        "root": str(root),
        "manifest_sha256": sha256_file(manifest_path),
        "package_files": len(declared),
        "tool_sources": len(tool_sources),
        "checkpoint_sha256": source["checkpoint_sha256"],
        "coreml_maximum_absolute_error": agreement["coreml_maximum_absolute_error"],
        "status": manifest["status"],
    }
