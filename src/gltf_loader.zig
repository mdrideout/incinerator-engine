//! gltf_loader.zig - Load 3D models from GLB/glTF files
//!
//! DOMAIN: Asset/Resource Layer
//!
//! This module loads 3D models from GLB (binary glTF) files using zmesh's
//! cgltf wrapper. It extracts mesh geometry and creates GPU-ready Mesh objects.
//!
//! Responsibilities:
//! - Parse GLB/glTF files
//! - Extract vertex data (positions, normals, UVs)
//! - Extract index data
//! - Create Mesh objects ready for rendering
//!
//! This module does NOT:
//! - Load textures (future enhancement)
//! - Handle materials/PBR (future enhancement)
//! - Handle animations/skeletons (future enhancement)
//!
//! Usage:
//!   var model = try gltf_loader.loadGlb(allocator, device, "assets/models/character.glb");
//!   defer model.deinit();
//!   for (model.meshes) |*m| { renderer.drawMesh(m, mvp); }

const std = @import("std");
const zmesh = @import("zmesh");
const mesh_module = @import("mesh.zig");
const sdl = @import("sdl.zig");

const Allocator = std.mem.Allocator;
const Mesh = mesh_module.Mesh;
const VertexPNU = mesh_module.VertexPNU;
const c = sdl.c;

// ============================================================================
// Public Types
// ============================================================================

/// A loaded 3D model containing one or more meshes.
/// Call deinit() when done to release GPU resources.
pub const LoadedModel = struct {
    meshes: []Mesh,
    allocator: Allocator,

    /// Release all GPU resources and memory.
    pub fn deinit(self: *LoadedModel) void {
        for (self.meshes) |*m| {
            m.deinit();
        }
        self.allocator.free(self.meshes);
    }

    /// Get the total number of triangles across all meshes.
    pub fn triangleCount(self: *const LoadedModel) u32 {
        var total: u32 = 0;
        for (self.meshes) |m| {
            total += if (m.index_count > 0) m.index_count / 3 else m.vertex_count / 3;
        }
        return total;
    }
};

// ============================================================================
// Public API
// ============================================================================

/// Load a GLB (binary glTF) file and create GPU-ready meshes.
///
/// Parameters:
/// - allocator: Used for temporary buffers during loading
/// - device: GPU device for creating vertex/index buffers
/// - path: Path to the .glb file (must be null-terminated, e.g., "assets/models/character.glb")
///
/// Returns a LoadedModel containing all meshes from the file.
/// The caller owns the returned model and must call deinit() to release resources.
pub fn loadGlb(allocator: Allocator, device: *c.SDL_GPUDevice, path: [:0]const u8) !LoadedModel {
    // =========================================================================
    // Step 0: Initialize zmesh (required before any zmesh calls)
    // =========================================================================
    zmesh.init(allocator);
    defer zmesh.deinit();

    // =========================================================================
    // Step 1: Parse the GLB file
    // =========================================================================
    // zmesh.io.zcgltf.parseAndLoadFile loads and parses the entire GLB,
    // including embedded binary buffers. For .gltf files (non-binary),
    // it would load external .bin files automatically.
    const data = zmesh.io.zcgltf.parseAndLoadFile(path) catch |err| {
        std.debug.print("Failed to load GLB file '{s}': {any}\n", .{ path, err });
        return error.GltfLoadFailed;
    };
    defer zmesh.io.zcgltf.free(data);

    std.debug.print("Loaded GLB: {s}\n", .{path});
    std.debug.print("  Meshes: {d}\n", .{data.meshes_count});

    // =========================================================================
    // Step 2: Count total mesh primitives
    // =========================================================================
    // In glTF, a "mesh" can have multiple "primitives" (sub-meshes with
    // different materials). We create one Mesh per primitive.
    const gltf_meshes = data.meshes orelse {
        std.debug.print("GLB file contains no meshes\n", .{});
        return error.NoMeshesFound;
    };

    var total_primitives: usize = 0;
    for (0..data.meshes_count) |i| {
        total_primitives += gltf_meshes[i].primitives_count;
    }

    if (total_primitives == 0) {
        std.debug.print("GLB file contains no mesh primitives\n", .{});
        return error.NoMeshesFound;
    }

    std.debug.print("  Total primitives: {d}\n", .{total_primitives});

    // =========================================================================
    // Step 3: Allocate output mesh array
    // =========================================================================
    var meshes = try allocator.alloc(Mesh, total_primitives);
    errdefer allocator.free(meshes);

    // =========================================================================
    // Step 4: Extract each primitive
    // =========================================================================
    var mesh_idx: usize = 0;

    for (0..data.meshes_count) |mi| {
        const gltf_mesh = gltf_meshes[mi];
        for (0..gltf_mesh.primitives_count) |pi| {
            // Temporary arrays for vertex data (zmesh appends to these)
            var indices = std.ArrayListUnmanaged(u32){};
            defer indices.deinit(allocator);

            var positions = std.ArrayListUnmanaged([3]f32){};
            defer positions.deinit(allocator);

            var normals = std.ArrayListUnmanaged([3]f32){};
            defer normals.deinit(allocator);

            var texcoords = std.ArrayListUnmanaged([2]f32){};
            defer texcoords.deinit(allocator);

            // Extract vertex data from this primitive
            // This function reads the glTF accessors and buffers,
            // converting to simple arrays we can use
            zmesh.io.zcgltf.appendMeshPrimitive(
                allocator,
                data,
                @intCast(mi), // mesh index
                @intCast(pi), // primitive index
                &indices,
                &positions,
                &normals,
                &texcoords,
                null, // tangents (not needed yet)
            ) catch |err| {
                std.debug.print("Failed to extract primitive {d}.{d}: {any}\n", .{ mi, pi, err });
                // Clean up already-created meshes
                for (meshes[0..mesh_idx]) |*m| {
                    m.deinit();
                }
                return error.PrimitiveExtractionFailed;
            };

            std.debug.print("  Primitive {d}.{d}: {d} vertices, {d} indices\n", .{
                mi,
                pi,
                positions.items.len,
                indices.items.len,
            });

            // =========================================================================
            // Step 5: Combine into VertexPNU array
            // =========================================================================
            // glTF stores positions, normals, UVs in separate arrays.
            // We interleave them into our VertexPNU format for the GPU.
            var vertices = try allocator.alloc(VertexPNU, positions.items.len);
            defer allocator.free(vertices);

            for (positions.items, 0..) |pos, i| {
                vertices[i] = VertexPNU{
                    .position = pos,
                    // Use normal if available, otherwise default to +Y (up)
                    .normal = if (i < normals.items.len) normals.items[i] else [3]f32{ 0, 1, 0 },
                    // Use texcoord if available, otherwise default to (0,0)
                    .texcoord = if (i < texcoords.items.len) texcoords.items[i] else [2]f32{ 0, 0 },
                };
            }

            // =========================================================================
            // Step 6: Create GPU mesh
            // =========================================================================
            meshes[mesh_idx] = try Mesh.initIndexed(device, vertices, indices.items);
            mesh_idx += 1;
        }
    }

    std.debug.print("Successfully loaded {d} mesh(es) from GLB\n", .{mesh_idx});

    return LoadedModel{
        .meshes = meshes,
        .allocator = allocator,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "LoadedModel.triangleCount" {
    // This is a compile-time check that the struct is valid
    _ = LoadedModel;
}
