"""Small dependency-free contracts shared by the NR-0004 target tools."""

from __future__ import annotations

import hashlib
import json
import math
import os
import struct
import tempfile
from pathlib import Path
from typing import Any, Iterable


TARGET_FRAME_SCHEMA = 4
TARGET_FRAME_SCHEMA_NAME = "incinerator.nr4.blender-target-frame.v4"
TARGET_RUN_SCHEMA = 1
CAPTURE_SCHEMA = 4
GLOBAL_CONTROL_SCHEMA = "incinerator.neural-frame-global.v1"
GLOBAL_CONTROL_ENCODING = "float32 little-endian"
GLOBAL_CONTROL_ORDER = (
    "sun_strength",
    "world_strength",
    "local_light_strength",
    "emissive_strength",
)
INPUT_EXTENT = [160, 90]
TARGET_EXTENT = [400, 225]
SAMPLING_MAP = {
    "scale_numerator": 5,
    "scale_denominator": 2,
    "target_center_to_source_index": "((target_index + 0.5) * 2 / 5) - 0.5",
    "border": "clamp",
}
SHAPES = {"box", "wheel_x", "capsule_y"}
MATERIALS = {
    "asphalt",
    "sidewalk",
    "masonry",
    "painted_metal",
    "rubber",
    "glass",
    "emissive",
    "fabric",
    "skin",
    "cardboard",
}
PATTERNS = {"none", "noise", "brick"}
SEQUENCE_SEGMENTS = {
    "still",
    "camera_motion",
    "object_motion",
    "near_edge",
    "wheel_articulation",
    "occlusion_disocclusion",
    "lighting_effect",
}


def require_absolute(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise ValueError(f"{label} must be absolute: {path}")
    return path


def create_absent(path: Path, label: str) -> Path:
    require_absolute(path, label)
    if path.exists():
        raise FileExistsError(f"{label} already exists: {path}")
    path.mkdir(parents=True)
    return path


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as source:
        value = json.load(source)
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, indent=2, sort_keys=True, allow_nan=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_ndjson(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"expected object at {path}:{line_number}")
        records.append(value)
    return records


def numeric_vector(value: object, count: int, label: str) -> list[float]:
    if not isinstance(value, list) or len(value) != count:
        raise ValueError(f"{label} must contain {count} numbers")
    if any(
        isinstance(component, bool)
        or not isinstance(component, (int, float))
        or not math.isfinite(component)
        for component in value
    ):
        raise ValueError(f"{label} contains a non-finite or non-numeric value")
    return [float(component) for component in value]


def positive_extent(value: object, label: str) -> list[int]:
    if not isinstance(value, list) or len(value) != 2 or any(
        isinstance(component, bool) or not isinstance(component, int) or component <= 0
        for component in value
    ):
        raise ValueError(f"{label} is invalid")
    return value


def capture_global_control_values(frame: dict[str, Any], capture_root: Path) -> dict[str, float]:
    controls = frame.get("global_controls")
    if not isinstance(controls, dict):
        raise ValueError("capture frame global controls are missing")
    if (
        controls.get("schema_name") != GLOBAL_CONTROL_SCHEMA
        or controls.get("encoding") != GLOBAL_CONTROL_ENCODING
        or controls.get("order") != list(GLOBAL_CONTROL_ORDER)
        or controls.get("raw_bytes") != len(GLOBAL_CONTROL_ORDER) * 4
    ):
        raise ValueError("capture frame global-control contract drifted")
    values = controls.get("values")
    if not isinstance(values, dict) or tuple(values) != GLOBAL_CONTROL_ORDER:
        raise ValueError("capture frame global-control values drifted")
    ordered = [values[name] for name in GLOBAL_CONTROL_ORDER]
    if any(
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value < 0
        for value in ordered
    ):
        raise ValueError("capture frame global-control value is invalid")
    raw_path = capture_root / str(controls.get("raw_path", ""))
    if not raw_path.is_file() or raw_path.stat().st_size != len(GLOBAL_CONTROL_ORDER) * 4:
        raise ValueError("capture frame global-control artifact is missing")
    if sha256_file(raw_path) != controls.get("raw_sha256"):
        raise ValueError("capture frame global-control artifact digest changed")
    raw = struct.unpack("<4f", raw_path.read_bytes())
    normalized = struct.unpack("<4f", struct.pack("<4f", *ordered))
    if raw != normalized:
        raise ValueError("capture frame global-control JSON/raw values disagree")
    return {name: raw[index] for index, name in enumerate(GLOBAL_CONTROL_ORDER)}


def target_global_control_values(package: dict[str, Any]) -> dict[str, float]:
    controls = package["global_controls"]
    return {
        name: struct.unpack("<f", struct.pack("<f", float(controls[name])))[0]
        for name in GLOBAL_CONTROL_ORDER
    }


def validate_frame_package(package: dict[str, Any]) -> None:
    if package.get("schema") != TARGET_FRAME_SCHEMA:
        raise ValueError("unexpected target-frame schema")
    if package.get("schema_name") != TARGET_FRAME_SCHEMA_NAME:
        raise ValueError("unexpected target-frame schema name")
    if package.get("status") != "complete":
        raise ValueError("target-frame package is incomplete")
    for name in ("frame_id", "sequence", "camera_path", "source_capture_frame"):
        value = package.get(name)
        if not isinstance(value, str) or not value:
            raise ValueError(f"target-frame {name} is required")
    if not Path(package["source_capture_frame"]).is_absolute():
        raise ValueError("target-frame source capture path must be absolute")
    if positive_extent(package.get("input_extent"), "target-frame input extent") != INPUT_EXTENT:
        raise ValueError("target-frame input extent is not native 160x90")
    if positive_extent(package.get("target_extent"), "target-frame target extent") != TARGET_EXTENT:
        raise ValueError("target-frame target extent is not native 400x225")
    if package.get("sampling_map") != SAMPLING_MAP:
        raise ValueError("target-frame sampling map is not the exact 5:2 pixel-center contract")
    coordinates = package.get("coordinate_system")
    if coordinates != {
        "world": "right-handed +Y up -Z forward",
        "matrix_storage": "zmath row-major row-vector",
        "image_origin": "top-left",
        "sample": "pixel-center",
    }:
        raise ValueError("target-frame coordinate convention is invalid")
    source = package.get("source")
    if not isinstance(source, dict) or not isinstance(source.get("dirty"), bool):
        raise ValueError("target-frame source provenance is invalid")
    for name in ("revision", "dirty_fingerprint", "content_sha256", "input_schema", "shader_fingerprint"):
        if not isinstance(source.get(name), str) or not source[name]:
            raise ValueError(f"target-frame source {name} is required")
    for name in ("authority_tick", "presentation_frame", "effect_seed"):
        value = package.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"target-frame {name} is invalid")
    for name in ("interpolation_alpha", "exposure"):
        value = package.get(name)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"target-frame {name} is invalid")
    if package["exposure"] <= 0:
        raise ValueError("target-frame exposure must be positive")
    controls = package.get("global_controls")
    if not isinstance(controls, dict) or controls.get("schema_name") != GLOBAL_CONTROL_SCHEMA:
        raise ValueError("target-frame global controls are missing")
    if set(controls) != {"schema_name", *GLOBAL_CONTROL_ORDER}:
        raise ValueError("target-frame global-control fields drifted")
    for name in GLOBAL_CONTROL_ORDER:
        value = controls.get(name)
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value < 0
        ):
            raise ValueError(f"target-frame global control {name} is invalid")
    event = package.get("sequence_event")
    if not isinstance(event, dict) or event.get("segment") not in SEQUENCE_SEGMENTS:
        raise ValueError("target-frame sequence event is invalid")
    for name in ("segment_index", "sample_index"):
        value = event.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"target-frame sequence event {name} is invalid")
    progress = event.get("progress")
    if (
        isinstance(progress, bool)
        or not isinstance(progress, (int, float))
        or not math.isfinite(progress)
        or not 0 <= progress <= 1
        or not isinstance(event.get("reset"), bool)
        or not isinstance(event.get("controlled_change"), str)
        or not event["controlled_change"]
    ):
        raise ValueError("target-frame sequence event controls are invalid")
    camera = package.get("camera")
    if not isinstance(camera, dict):
        raise ValueError("target-frame camera is missing")
    numeric_vector(camera.get("position"), 3, "target-frame camera position")
    forward = numeric_vector(camera.get("forward"), 3, "target-frame camera forward")
    up = numeric_vector(camera.get("up"), 3, "target-frame camera up")
    if sum(component * component for component in forward) == 0 or sum(
        component * component for component in up
    ) == 0:
        raise ValueError("target-frame camera directions must be nonzero")
    fov = camera.get("vertical_fov_radians")
    near = camera.get("near")
    far = camera.get("far")
    if any(
        isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
        for value in (fov, near, far)
    ) or not (0 < fov < math.pi and 0 < near < far):
        raise ValueError("target-frame camera projection is invalid")
    numeric_vector(camera.get("view"), 16, "target-frame camera view matrix")
    numeric_vector(camera.get("view_projection"), 16, "target-frame camera view-projection matrix")
    scene = package.get("scene")
    if not isinstance(scene, dict):
        raise ValueError("target-frame scene is missing")
    for name in ("id", "fingerprint"):
        if not isinstance(scene.get(name), str) or not scene[name]:
            raise ValueError(f"target-frame scene {name} is required")
    numeric_vector(scene.get("sun_direction"), 3, "target-frame sun direction")
    numeric_vector(scene.get("sun_color"), 3, "target-frame sun color")
    numeric_vector(scene.get("world_color"), 3, "target-frame world color")
    numeric_vector(scene.get("local_light_position"), 3, "target-frame local light position")
    numeric_vector(scene.get("local_light_color"), 3, "target-frame local light color")
    for name in (
        "sun_strength",
        "sun_angle_radians",
        "world_strength",
        "local_light_strength",
        "local_light_radius",
    ):
        value = scene.get(name)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"target-frame scene {name} is invalid")
    if (
        scene["sun_strength"] <= 0
        or scene["sun_angle_radians"] <= 0
        or scene["world_strength"] < 0
        or scene["local_light_strength"] < 0
        or scene["local_light_radius"] <= 0
    ):
        raise ValueError("target-frame scene lighting is invalid")
    for name in ("sun_strength", "world_strength", "local_light_strength"):
        if float(controls[name]) != float(scene[name]):
            raise ValueError(f"target-frame global control {name} disagrees with scene intent")
    draws = package.get("draws")
    if not isinstance(draws, list) or not draws:
        raise ValueError("target-frame package has no draws")
    stable_keys: set[str] = set()
    compact_codes: set[int] = set()
    labels: set[str] = set()
    for draw in draws:
        if not isinstance(draw, dict):
            raise ValueError("target draw must be an object")
        label = draw.get("label")
        stable_key = draw.get("stable_key")
        compact = draw.get("compact_rgb24")
        if not isinstance(label, str) or not label or label in labels:
            raise ValueError("target draw labels must be unique and non-empty")
        if not isinstance(stable_key, str) or len(stable_key) != 16 or stable_key in stable_keys:
            raise ValueError("target draw stable keys must be unique hex16 strings")
        try:
            int(stable_key, 16)
        except ValueError as error:
            raise ValueError("target draw stable keys must be unique hex16 strings") from error
        if not isinstance(compact, int) or compact <= 0 or compact > 0xFFFFFF:
            raise ValueError("target draw compact identity is invalid")
        if compact in compact_codes:
            raise ValueError("target draw compact identities collide")
        transform = draw.get("transform")
        if not isinstance(transform, dict):
            raise ValueError("target draw transform is missing")
        scale = numeric_vector(transform.get("scale"), 3, "target draw scale")
        if any(value <= 0 for value in scale):
            raise ValueError("target draw scale must be positive")
        numeric_vector(transform.get("rotation_xyz"), 3, "target draw rotation")
        numeric_vector(transform.get("translation"), 3, "target draw translation")
        numeric_vector(draw.get("model_matrix"), 16, "target draw model matrix")
        numeric_vector(draw.get("base_color"), 4, "target draw base color")
        if draw.get("shape") not in SHAPES or draw.get("material") not in MATERIALS:
            raise ValueError("target draw shape or material is unsupported")
        response = draw.get("material_response")
        if not isinstance(response, dict) or response.get("pattern") not in PATTERNS:
            raise ValueError("target draw material response is missing")
        response_values = {
            name: response.get(name)
            for name in (
                "roughness",
                "metallic",
                "transmission",
                "ior",
                "emission_strength",
                "sheen",
                "subsurface",
                "pattern_scale",
                "pattern_detail",
                "bump_strength",
                "bump_distance",
            )
        }
        if any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            for value in response_values.values()
        ):
            raise ValueError("target draw material response contains invalid values")
        if (
            not 0 <= response_values["roughness"] <= 1
            or not 0 <= response_values["metallic"] <= 1
            or not 0 <= response_values["transmission"] <= 1
            or response_values["ior"] < 1
            or response_values["emission_strength"] < 0
            or not 0 <= response_values["sheen"] <= 1
            or not 0 <= response_values["subsurface"] <= 1
            or response_values["pattern_scale"] <= 0
            or response_values["pattern_detail"] < 0
            or response_values["bump_strength"] < 0
            or response_values["bump_distance"] < 0
        ):
            raise ValueError("target draw material response is outside its declared domain")
        if not isinstance(draw.get("semantic"), str) or not isinstance(draw.get("part"), str):
            raise ValueError("target draw semantic identity is missing")
        ordinal = draw.get("ordinal")
        if isinstance(ordinal, bool) or not isinstance(ordinal, int) or ordinal < 0:
            raise ValueError("target draw ordinal is invalid")
        identity = draw.get("identity")
        if not isinstance(identity, dict) or not isinstance(identity.get("kind"), str):
            raise ValueError("target draw source identity is missing")
        stable_keys.add(stable_key)
        compact_codes.add(compact)
        labels.add(label)
    emissive_strengths = [
        float(draw["material_response"]["emission_strength"])
        for draw in draws
        if draw["material"] == "emissive"
    ]
    expected_emissive = max(emissive_strengths, default=0.0)
    if float(controls["emissive_strength"]) != expected_emissive:
        raise ValueError("target-frame global emissive control disagrees with material intent")


def artifact(path: Path, root: Path) -> dict[str, Any]:
    return {
        "path": str(path.relative_to(root)),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def verify_artifacts(root: Path, records: Iterable[dict[str, Any]]) -> None:
    for record in records:
        path = root / str(record["path"])
        if not path.is_file():
            raise ValueError(f"artifact is missing: {path}")
        if path.stat().st_size != int(record["bytes"]):
            raise ValueError(f"artifact byte count changed: {path}")
        if sha256_file(path) != record["sha256"]:
            raise ValueError(f"artifact digest changed: {path}")


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"P6\n"):
        raise ValueError(f"not a binary PPM: {path}")
    magic, dimensions, maximum, pixels = data.split(b"\n", 3)
    width, height = (int(value) for value in dimensions.split())
    if magic != b"P6" or maximum != b"255" or len(pixels) != width * height * 3:
        raise ValueError(f"invalid binary PPM: {path}")
    return width, height, pixels


def write_ppm(path: Path, width: int, height: int, pixels: bytes | bytearray) -> None:
    if len(pixels) != width * height * 3:
        raise ValueError("PPM byte count does not match extent")
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + bytes(pixels))
