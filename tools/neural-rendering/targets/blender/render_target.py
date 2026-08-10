#!/usr/bin/env python3
"""Render one exact Incinerator target-frame package with pinned Cycles."""

from __future__ import annotations

import argparse
import json
import math
import platform
import resource
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy
import OpenImageIO as oiio
from mathutils import Matrix, Vector

from nr4_common import (
    artifact,
    atomic_json,
    create_absent,
    load_json,
    sha256_file,
    validate_frame_package,
    write_ppm,
)


def parse_args() -> argparse.Namespace:
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--frame-package", required=True, type=Path)
    parser.add_argument("--environment", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(arguments)


def socket(node: bpy.types.Node, name: str) -> bpy.types.NodeSocket:
    value = node.inputs.get(name)
    if value is None:
        raise RuntimeError(f"Blender node {node.bl_idname} has no input {name!r}")
    return value


def make_material(
    name: str, kind: str, color: list[float], response: dict
) -> bpy.types.Material:
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    principled = nodes.new("ShaderNodeBsdfPrincipled")
    links.new(principled.outputs["BSDF"], output.inputs["Surface"])
    rgba = tuple(float(value) for value in color[:3]) + (1.0,)
    socket(principled, "Base Color").default_value = rgba
    socket(principled, "Roughness").default_value = float(response["roughness"])
    socket(principled, "Metallic").default_value = float(response["metallic"])
    socket(principled, "Transmission Weight").default_value = float(response["transmission"])
    socket(principled, "IOR").default_value = float(response["ior"])
    socket(principled, "Sheen Weight").default_value = float(response["sheen"])
    socket(principled, "Subsurface Weight").default_value = float(response["subsurface"])
    if float(response["emission_strength"]) > 0:
        socket(principled, "Emission Color").default_value = rgba
        socket(principled, "Emission Strength").default_value = float(
            response["emission_strength"]
        )

    if kind == "asphalt":
        noise = nodes.new("ShaderNodeTexNoise")
        socket(noise, "Scale").default_value = float(response["pattern_scale"])
        socket(noise, "Detail").default_value = float(response["pattern_detail"])
        ramp = nodes.new("ShaderNodeValToRGB")
        ramp.color_ramp.elements[0].color = (0.018, 0.022, 0.027, 1)
        ramp.color_ramp.elements[1].color = (0.16, 0.18, 0.20, 1)
        bump = nodes.new("ShaderNodeBump")
        socket(bump, "Strength").default_value = float(response["bump_strength"])
        socket(bump, "Distance").default_value = float(response["bump_distance"])
        links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
        links.new(ramp.outputs["Color"], socket(principled, "Base Color"))
        links.new(noise.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], socket(principled, "Normal"))
    elif kind == "sidewalk":
        noise = nodes.new("ShaderNodeTexNoise")
        socket(noise, "Scale").default_value = float(response["pattern_scale"])
        socket(noise, "Detail").default_value = float(response["pattern_detail"])
        bump = nodes.new("ShaderNodeBump")
        socket(bump, "Strength").default_value = float(response["bump_strength"])
        socket(bump, "Distance").default_value = float(response["bump_distance"])
        links.new(noise.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], socket(principled, "Normal"))
    elif kind == "masonry":
        brick = nodes.new("ShaderNodeTexBrick")
        socket(brick, "Color1").default_value = (0.32, 0.055, 0.025, 1)
        socket(brick, "Color2").default_value = (0.62, 0.16, 0.06, 1)
        socket(brick, "Mortar").default_value = (0.055, 0.05, 0.045, 1)
        socket(brick, "Scale").default_value = float(response["pattern_scale"])
        socket(brick, "Mortar Size").default_value = 0.035
        bump = nodes.new("ShaderNodeBump")
        socket(bump, "Strength").default_value = float(response["bump_strength"])
        socket(bump, "Distance").default_value = float(response["bump_distance"])
        links.new(brick.outputs["Color"], socket(principled, "Base Color"))
        links.new(brick.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], socket(principled, "Normal"))
    elif kind == "painted_metal":
        noise = nodes.new("ShaderNodeTexNoise")
        socket(noise, "Scale").default_value = float(response["pattern_scale"])
        socket(noise, "Detail").default_value = float(response["pattern_detail"])
        bump = nodes.new("ShaderNodeBump")
        socket(bump, "Strength").default_value = float(response["bump_strength"])
        socket(bump, "Distance").default_value = float(response["bump_distance"])
        links.new(noise.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], socket(principled, "Normal"))
    elif kind == "rubber":
        noise = nodes.new("ShaderNodeTexNoise")
        socket(noise, "Scale").default_value = float(response["pattern_scale"])
        socket(noise, "Detail").default_value = float(response["pattern_detail"])
        bump = nodes.new("ShaderNodeBump")
        socket(bump, "Strength").default_value = float(response["bump_strength"])
        socket(bump, "Distance").default_value = float(response["bump_distance"])
        links.new(noise.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], socket(principled, "Normal"))
    elif kind == "glass":
        pass
    elif kind == "emissive":
        pass
    elif kind == "fabric":
        noise = nodes.new("ShaderNodeTexNoise")
        socket(noise, "Scale").default_value = float(response["pattern_scale"])
        socket(noise, "Detail").default_value = float(response["pattern_detail"])
        bump = nodes.new("ShaderNodeBump")
        socket(bump, "Strength").default_value = float(response["bump_strength"])
        socket(bump, "Distance").default_value = float(response["bump_distance"])
        links.new(noise.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], socket(principled, "Normal"))
    elif kind == "skin":
        pass
    elif kind == "cardboard":
        noise = nodes.new("ShaderNodeTexNoise")
        socket(noise, "Scale").default_value = float(response["pattern_scale"])
        socket(noise, "Detail").default_value = float(response["pattern_detail"])
        bump = nodes.new("ShaderNodeBump")
        socket(bump, "Strength").default_value = float(response["bump_strength"])
        socket(bump, "Distance").default_value = float(response["bump_distance"])
        links.new(noise.outputs["Fac"], bump.inputs["Height"])
        links.new(bump.outputs["Normal"], socket(principled, "Normal"))
    else:
        raise ValueError(f"unsupported NR4 material: {kind}")
    return material


def create_capsule_mesh(name: str) -> bpy.types.Mesh:
    radius = 0.4
    half_height = 0.5
    segments = 32
    bands = 10
    rings: list[tuple[float, float]] = []
    for band in range(1, bands + 1):
        angle = -math.pi / 2.0 + (math.pi / 2.0) * band / bands
        rings.append((radius * math.cos(angle), radius + radius * math.sin(angle)))
    cylinder_top = radius + half_height * 2.0
    for band in range(bands):
        angle = (math.pi / 2.0) * band / bands
        rings.append((radius * math.cos(angle), cylinder_top + radius * math.sin(angle)))
    vertices = [(0.0, 0.0, 0.0)]
    for ring_radius, engine_y in rings:
        for segment in range(segments):
            angle = math.tau * segment / segments
            engine = (ring_radius * math.cos(angle), engine_y, ring_radius * math.sin(angle))
            vertices.append((engine[0], -engine[2], engine[1]))
    vertices.append((0.0, 0.0, cylinder_top + radius))
    bottom = 0
    top = len(vertices) - 1
    faces: list[tuple[int, ...]] = []
    for segment in range(segments):
        nxt = (segment + 1) % segments
        faces.append((bottom, 1 + segment, 1 + nxt))
    for ring in range(len(rings) - 1):
        first = 1 + ring * segments
        second = first + segments
        for segment in range(segments):
            nxt = (segment + 1) % segments
            faces.append((first + segment, second + segment, second + nxt, first + nxt))
    last = 1 + (len(rings) - 1) * segments
    for segment in range(segments):
        nxt = (segment + 1) % segments
        faces.append((last + segment, top, last + nxt))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    return mesh


def create_object(draw: dict, pass_index: int) -> bpy.types.Object:
    shape = draw["shape"]
    if shape == "box":
        bpy.ops.mesh.primitive_cube_add(size=1.0)
        obj = bpy.context.object
    elif shape == "wheel_x":
        bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=0.5, depth=1.0)
        obj = bpy.context.object
        obj.data.transform(Matrix.Rotation(math.pi / 2.0, 4, "Y"))
    elif shape == "capsule_y":
        obj = bpy.data.objects.new(draw["label"], create_capsule_mesh(f"{draw['label']}-mesh"))
        bpy.context.collection.objects.link(obj)
    else:
        raise ValueError(f"unsupported NR4 shape: {shape}")
    obj.name = draw["label"]
    rows = [draw["model_matrix"][offset : offset + 4] for offset in range(0, 16, 4)]
    engine_column = Matrix(rows).transposed()
    basis = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
    obj.matrix_world = basis @ engine_column @ basis.inverted()
    obj.pass_index = pass_index
    material = make_material(
        f"{draw['label']}-{draw['material']}",
        draw["material"],
        draw["base_color"],
        draw["material_response"],
    )
    obj.data.materials.append(material)
    if shape == "box":
        bevel = obj.modifiers.new("authored-edge-bevel", "BEVEL")
        bevel.width = 0.025
        bevel.segments = 3
    for polygon in obj.data.polygons:
        polygon.use_smooth = shape != "box"
    return obj


def configure_cycles(scene: bpy.types.Scene, environment: dict) -> list[dict]:
    expected = tuple(int(part) for part in environment["blender"]["version"].split("."))
    if tuple(bpy.app.version[:3]) != expected:
        raise RuntimeError(f"expected Blender {expected}, got {tuple(bpy.app.version[:3])}")
    cycles = environment["cycles"]
    preferences = bpy.context.preferences.addons["cycles"].preferences
    preferences.compute_device_type = cycles["device"]
    preferences.get_devices()
    devices = []
    metal_enabled = False
    for device in preferences.devices:
        enabled = device.type == "METAL"
        device.use = enabled
        metal_enabled = metal_enabled or enabled
        devices.append({"name": device.name, "type": device.type, "enabled": enabled})
    if not metal_enabled:
        raise RuntimeError("native target render requires an available Cycles Metal device")
    scene.render.engine = "CYCLES"
    scene.cycles.device = "GPU"
    scene.cycles.feature_set = cycles["feature_set"]
    scene.cycles.samples = int(cycles["samples"])
    scene.cycles.use_adaptive_sampling = bool(cycles["use_adaptive_sampling"])
    scene.cycles.use_denoising = bool(cycles["use_denoising"])
    scene.cycles.seed = int(cycles["seed"])
    scene.cycles.max_bounces = int(cycles["max_bounces"])
    scene.cycles.diffuse_bounces = int(cycles["diffuse_bounces"])
    scene.cycles.glossy_bounces = int(cycles["glossy_bounces"])
    scene.cycles.transmission_bounces = int(cycles["transmission_bounces"])
    scene.cycles.transparent_max_bounces = int(cycles["transparent_max_bounces"])
    bpy.context.view_layer.cycles.use_denoising = False
    return devices


def pass_values(exr_path: Path, name: str, expected_channels: tuple[str, ...]) -> tuple[int, object]:
    image_input = oiio.ImageInput.open(str(exr_path))
    if image_input is None:
        raise RuntimeError(f"OpenImageIO could not open target EXR: {oiio.geterror()}")
    try:
        spec = image_input.spec()
        suffixes = tuple(f".{name}.{channel}" for channel in expected_channels)
        indices = [
            index
            for index, channel_name in enumerate(spec.channelnames)
            if any(channel_name == suffix[1:] or channel_name.endswith(suffix) for suffix in suffixes)
        ]
        if len(indices) != len(expected_channels) or indices != list(range(indices[0], indices[0] + len(indices))):
            raise RuntimeError(
                f"target EXR does not contain contiguous {name} channels {expected_channels}: "
                f"{spec.channelnames}"
            )
        pixels = image_input.read_image(indices[0], indices[-1] + 1, oiio.FLOAT)
        if pixels is None:
            raise RuntimeError(f"OpenImageIO could not read {name}: {image_input.geterror()}")
        return len(indices), pixels.reshape(-1)
    finally:
        image_input.close()


def write_evidence(output: Path, package: dict) -> list[dict]:
    width, height = package["target_extent"]
    near = float(package["camera"]["near"])
    far = float(package["camera"]["far"])
    draws = package["draws"]

    exr_path = output / "target.exr"
    index_channels, index_values = pass_values(exr_path, "IndexOB", ("X",))
    indices = [max(0, int(round(index_values[offset]))) for offset in range(0, len(index_values), index_channels)]
    (output / "identity.u32").write_bytes(struct.pack(f"<{len(indices)}I", *indices))
    identity_debug = bytearray(width * height * 3)
    mapping = {index + 1: draw for index, draw in enumerate(draws)}
    for pixel, index in enumerate(indices):
        if index == 0:
            continue
        compact = int(mapping[index]["compact_rgb24"])
        identity_debug[pixel * 3 : pixel * 3 + 3] = bytes(
            (compact & 0xFF, (compact >> 8) & 0xFF, (compact >> 16) & 0xFF)
        )
    write_ppm(output / "identity.ppm", width, height, identity_debug)

    depth_channels, depth_values = pass_values(exr_path, "Depth", ("Z",))
    depths = []
    depth_debug = bytearray(width * height * 3)
    for pixel, offset in enumerate(range(0, len(depth_values), depth_channels)):
        value = float(depth_values[offset])
        if not math.isfinite(value) or indices[pixel] == 0:
            value = far
        value = min(max(value, near), far)
        depths.append(value)
        visible = round(math.sqrt((value - near) / (far - near)) * 255.0)
        depth_debug[pixel * 3 : pixel * 3 + 3] = bytes((visible, visible, visible))
    (output / "depth.f32").write_bytes(struct.pack(f"<{len(depths)}f", *depths))
    write_ppm(output / "depth.ppm", width, height, depth_debug)

    normal_channels, normal_values = pass_values(exr_path, "Normal", ("X", "Y", "Z"))
    normals: list[float] = []
    normal_debug = bytearray(width * height * 3)
    for pixel, offset in enumerate(range(0, len(normal_values), normal_channels)):
        vector = normal_values[offset : offset + 3]
        if indices[pixel] == 0 or any(not math.isfinite(value) for value in vector):
            vector = [0.0, 0.0, 0.0]
        normals.extend(vector)
        normal_debug[pixel * 3 : pixel * 3 + 3] = bytes(
            round(min(max(value * 0.5 + 0.5, 0.0), 1.0) * 255.0) for value in vector
        )
    (output / "normal.f32").write_bytes(struct.pack(f"<{len(normals)}f", *normals))
    write_ppm(output / "normal.ppm", width, height, normal_debug)

    paths = [
        output / "target.exr",
        output / "target-display.png",
        output / "identity.u32",
        output / "identity.ppm",
        output / "depth.f32",
        output / "depth.ppm",
        output / "normal.f32",
        output / "normal.ppm",
    ]
    return [artifact(path, output) for path in paths]


def main() -> None:
    args = parse_args()
    package_path = args.frame_package.resolve()
    environment_path = args.environment.resolve()
    output = args.output.resolve()
    package = load_json(package_path)
    environment = load_json(environment_path)
    validate_frame_package(package)
    create_absent(output, "target output")
    atomic_json(
        output / "target-run.json",
        {
            "schema": 1,
            "status": "partial",
            "frame_id": package["frame_id"],
            "frame_package": str(package_path),
            "frame_package_sha256": sha256_file(package_path),
            "environment": str(environment_path),
            "environment_sha256": sha256_file(environment_path),
        },
    )

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    devices = configure_cycles(scene, environment)
    width, height = package["target_extent"]
    scene.render.resolution_x = width
    scene.render.resolution_y = height
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "OPEN_EXR_MULTILAYER"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "32"
    scene.render.image_settings.exr_codec = "ZIP"
    scene.render.filepath = str(output / "target.exr")
    scene.view_settings.view_transform = environment["color"]["view_transform"]
    try:
        scene.view_settings.look = environment["color"]["look"]
    except TypeError:
        # Blender stores the exact accepted look below; inability to select the
        # pinned look is a configuration failure, not a silent alternative.
        raise RuntimeError(f"pinned color look is unavailable: {environment['color']['look']}")
    scene.display_settings.display_device = environment["color"]["display_device"]
    scene.view_settings.exposure = math.log2(float(package["exposure"]))
    scene.view_settings.gamma = 1.0
    scene.render.image_settings.color_management = "FOLLOW_SCENE"

    view_layer = bpy.context.view_layer
    view_layer.use_pass_object_index = True
    view_layer.use_pass_z = True
    view_layer.use_pass_normal = True

    world = bpy.data.worlds.new("nr4-world")
    world.use_nodes = True
    scene.world = world
    background = world.node_tree.nodes["Background"]
    background.inputs["Color"].default_value = tuple(package["scene"]["world_color"]) + (1.0,)
    background.inputs["Strength"].default_value = float(package["scene"]["world_strength"])

    sun_data = bpy.data.lights.new("nr4-sun", "SUN")
    sun_data.energy = float(package["scene"]["sun_strength"])
    sun_data.color = package["scene"]["sun_color"]
    sun_data.angle = float(package["scene"]["sun_angle_radians"])
    sun = bpy.data.objects.new("nr4-sun", sun_data)
    bpy.context.collection.objects.link(sun)
    direction = package["scene"]["sun_direction"]
    sun_direction = Vector((direction[0], -direction[2], direction[1]))
    sun.rotation_euler = sun_direction.to_track_quat("-Z", "Y").to_euler()

    local_data = bpy.data.lights.new("nr4-local-light", "POINT")
    local_data.energy = float(package["scene"]["local_light_strength"])
    local_data.color = package["scene"]["local_light_color"]
    local_data.shadow_soft_size = float(package["scene"]["local_light_radius"])
    local_light = bpy.data.objects.new("nr4-local-light", local_data)
    local_position = package["scene"]["local_light_position"]
    local_light.location = (
        local_position[0],
        -local_position[2],
        local_position[1],
    )
    bpy.context.collection.objects.link(local_light)

    for index, draw in enumerate(package["draws"], 1):
        create_object(draw, index)

    camera_data = bpy.data.cameras.new("nr4-camera")
    camera = bpy.data.objects.new("nr4-camera", camera_data)
    bpy.context.collection.objects.link(camera)
    scene.camera = camera
    position = package["camera"]["position"]
    forward = package["camera"]["forward"]
    up = package["camera"]["up"]
    camera.location = (position[0], -position[2], position[1])
    direction = Vector((forward[0], -forward[2], forward[1])).normalized()
    blender_up = Vector((up[0], -up[2], up[1])).normalized()
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    if (camera.matrix_world.to_3x3() @ Vector((0, 1, 0))).dot(blender_up) < 0:
        raise RuntimeError("camera up conversion inverted")
    camera_data.type = "PERSP"
    camera_data.sensor_fit = "VERTICAL"
    camera_data.sensor_height = 32.0
    camera_data.lens = camera_data.sensor_height / (
        2.0 * math.tan(float(package["camera"]["vertical_fov_radians"]) / 2.0)
    )
    camera_data.clip_start = float(package["camera"]["near"])
    camera_data.clip_end = float(package["camera"]["far"])

    started = time.perf_counter_ns()
    bpy.ops.render.render(write_still=True)
    render_ns = time.perf_counter_ns() - started
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    bpy.data.images["Render Result"].save_render(str(output / "target-display.png"), scene=scene)
    artifacts = write_evidence(output, package)
    manifest = {
        "schema": 1,
        "status": "complete",
        "frame_id": package["frame_id"],
        "frame_package": str(package_path),
        "frame_package_sha256": sha256_file(package_path),
        "environment": str(environment_path),
        "environment_sha256": sha256_file(environment_path),
        "adapter": {
            "sources": [
                {
                    "path": str(path),
                    "repository_path": f"tools/neural-rendering/targets/blender/{path.name}",
                    "sha256": sha256_file(path),
                }
                for path in (Path(__file__).resolve(), Path(__file__).with_name("nr4_common.py"))
            ]
        },
        "blender": {
            "version": bpy.app.version_string,
            "version_cycle": bpy.app.version_cycle,
            "build_hash": bpy.app.build_hash.decode("utf-8", errors="replace"),
            "python": sys.version,
            "platform": platform.platform(),
        },
        "cycles": {
            **environment["cycles"],
            "devices": devices,
            "render_ns": render_ns,
            "denoising_observed": bool(scene.cycles.use_denoising or view_layer.cycles.use_denoising),
        },
        "memory": {
            "process_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            "process_peak_rss_source": "getrusage(RUSAGE_SELF) on macOS",
            "gpu_memory": "unavailable from the pinned Blender/Cycles Python surface",
        },
        "color": {
            **environment["color"],
            "observed_view_transform": scene.view_settings.view_transform,
            "observed_look": scene.view_settings.look,
            "observed_display_device": scene.display_settings.display_device,
        },
        "extent": package["target_extent"],
        "paired_input_extent": package["input_extent"],
        "sampling_map": package["sampling_map"],
        "sequence_event": package["sequence_event"],
        "draw_count": len(package["draws"]),
        "object_index_mapping": [
            {
                "object_index": index,
                "label": draw["label"],
                "stable_key": draw["stable_key"],
                "compact_rgb24": draw["compact_rgb24"],
            }
            for index, draw in enumerate(package["draws"], 1)
        ],
        "artifacts": artifacts,
        "rights": environment["rights"],
    }
    atomic_json(output / "target-run.json", manifest)
    print(output / "target-run.json")


if __name__ == "__main__":
    main()
