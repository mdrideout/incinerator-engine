"""Fail-closed contracts for the active RF10 title-renderer cohort."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .io import load_json, read_ndjson, sha256_file


CORPUS_SCHEMA = 1
FRAME_SCHEMA = 1
CAPTURE_SCHEMA = 7
TARGET_FRAME_SCHEMA = "incinerator.nr4.blender-target-frame.v8"
INPUT_SCHEMA_VERSION = 7
INPUT_SCHEMA_NAME = "incinerator.neural-input.v7"
INPUT_EXTENT = (256, 144)
TARGET_EXTENT = (1280, 720)
GLOBAL_CONTROL_SCHEMA = "incinerator.neural-frame-global.v2"
CHANNELS = (
    "appearance",
    "linear-depth",
    "world-normal",
    "motion",
    "semantic",
    "instance",
)
SPLITS = frozenset(("overfit", "train", "validation", "test", "stress"))


def require_sealed_training_authorization(
    authorization: dict[str, Any],
    *,
    allowed_scopes: tuple[str, ...],
    corpus_manifest_sha256: str,
) -> None:
    """Fail closed unless an authorization owns this still-sealed corpus."""

    if (
        authorization.get("status") != "accepted"
        or authorization.get("authorization_scope") not in allowed_scopes
        or authorization.get("sealed_test_pixels_opened") is not False
        or authorization.get("corpus_manifest_sha256") != corpus_manifest_sha256
    ):
        raise ValueError("NR5-C requires the exact sealed held-out authorization")


def _require_artifact(root: Path, record: dict[str, Any], label: str) -> Path:
    path = root / str(record.get("path", ""))
    if not path.is_file():
        raise ValueError(f"{label} is missing: {path}")
    expected_bytes = int(record.get("bytes", -1))
    if path.stat().st_size != expected_bytes:
        raise ValueError(f"{label} byte count drifted: {path}")
    expected_digest = str(record.get("sha256", ""))
    if len(expected_digest) != 64 or sha256_file(path) != expected_digest:
        raise ValueError(f"{label} digest drifted: {path}")
    return path


def inspect_corpus_metadata(root: Path, *, verify_training_artifacts: bool) -> dict[str, Any]:
    """Validate the accepted native corpus without opening sealed-test pixels.

    When ``verify_training_artifacts`` is true, non-test raw channels and HDR
    targets are hashed. Test records are always limited to manifest/package
    metadata so an NR4-E coverage pass cannot accidentally unseal the cohort.
    The existing NR4-D inspector remains the exhaustive machine-integrity gate.
    """

    root = root.resolve()
    manifest_path = root / "corpus.json"
    manifest = load_json(manifest_path)
    if manifest.get("schema") != CORPUS_SCHEMA or manifest.get("status") != "complete":
        raise ValueError("title corpus is incomplete or has an unsupported schema")
    role = manifest.get("corpus_role", "primary")
    expected_purpose = (
        "self-contained native 256x144 to direct 1280x720 post-selection stress corpus"
        if role == "post_selection_stress"
        else "self-contained native 256x144 to direct 1280x720 paired corpus"
    )
    if role not in ("primary", "post_selection_stress") or manifest.get("purpose") != expected_purpose:
        raise ValueError("title corpus purpose drifted")
    rights = manifest.get("rights")
    if not isinstance(rights, dict) or any(
        bool(rights.get(name)) for name in ("external_art", "learned_denoiser", "pretrained_weights")
    ):
        raise ValueError("title corpus is not rights-clean under ADR-026")
    sequences = manifest.get("sequences")
    if not isinstance(sequences, list) or len(sequences) != int(manifest.get("sequence_count", -1)):
        raise ValueError("title corpus sequence index drifted")
    split_by_sequence: dict[str, str] = {}
    for sequence in sequences:
        name = str(sequence.get("sequence", ""))
        split = str(sequence.get("split", ""))
        if not name or split not in SPLITS or name in split_by_sequence:
            raise ValueError("title corpus sequence ownership drifted")
        split_by_sequence[name] = split
        run_path = root / str(sequence.get("root", "")) / "run.json"
        if not run_path.is_file() or sha256_file(run_path) != sequence.get("run_manifest_sha256"):
            raise ValueError(f"title corpus sequence manifest drifted: {name}")
    expected_splits = {"stress"} if role == "post_selection_stress" else SPLITS
    if set(split_by_sequence.values()) != expected_splits:
        raise ValueError("title corpus does not own the splits required by its role")
    split_manifest = manifest.get("splits")
    if not isinstance(split_manifest, dict) or split_manifest.get("test", {}).get("policy") != "sealed_until_final_evaluation":
        raise ValueError("title corpus test split is not sealed")

    records = read_ndjson(root / str(manifest.get("frame_index", "")))
    if len(records) != int(manifest.get("frame_count", -1)):
        raise ValueError("title corpus frame index drifted")
    frame_ids: set[str] = set()
    for record in records:
        if record.get("schema") != FRAME_SCHEMA:
            raise ValueError("title corpus frame schema drifted")
        sequence = str(record.get("sequence", ""))
        split = str(record.get("split", ""))
        if split_by_sequence.get(sequence) != split:
            raise ValueError("title corpus frame escaped whole-sequence ownership")
        frame_id = str(record.get("frame_id", ""))
        if not frame_id or frame_id in frame_ids:
            raise ValueError("title corpus frame identity is missing or duplicated")
        frame_ids.add(frame_id)
        package_path = _require_artifact(root, record["target_frame_package"], "target frame package")
        package = load_json(package_path)
        if package.get("schema_name") != TARGET_FRAME_SCHEMA:
            raise ValueError(f"target frame schema drifted: {frame_id}")
        if tuple(package.get("input_extent", ())) != INPUT_EXTENT or tuple(package.get("target_extent", ())) != TARGET_EXTENT:
            raise ValueError(f"working extent drifted: {frame_id}")
        if split == "test":
            continue
        if verify_training_artifacts:
            _require_artifact(root, record["capture_frame"], "capture frame")
            channel_names = tuple(channel.get("name") for channel in record["conditioning"]["channels"])
            if channel_names != CHANNELS:
                raise ValueError(f"conditioning channel ABI drifted: {frame_id}")
            for channel in record["conditioning"]["channels"]:
                _require_artifact(root, channel, f"conditioning channel {channel['name']}")
            controls = record["conditioning"]["global_controls"]
            if controls.get("schema_name") != GLOBAL_CONTROL_SCHEMA:
                raise ValueError(f"global-control schema drifted: {frame_id}")
            _require_artifact(root, controls, "global controls")
            _require_artifact(root, record["target"]["linear_hdr"], "linear HDR target")

    review = manifest.get("review")
    if not isinstance(review, dict) or review.get("training_eligible") is not False:
        raise ValueError("corpus review derivative became training eligible")
    review_manifest = load_json(root / str(review.get("manifest", "")))
    if review_manifest.get("test_frames_included") is not False:
        raise ValueError("sealed test pixels entered corpus review")
    return {
        "root": root,
        "manifest_path": manifest_path,
        "manifest": manifest,
        "records": records,
        "split_by_sequence": split_by_sequence,
        "sealed_test_pixels_opened": False,
    }
