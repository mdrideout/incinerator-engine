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
//!   for (model.meshes) |*m| { renderer.drawMesh(m, model_matrix, view_projection); }

const std = @import("std");
const zmesh = @import("zmesh");
const zstbi = @import("zstbi");
const mesh_module = @import("mesh.zig");
const texture_module = @import("texture.zig");
const sdl = @import("sdl.zig");

const Allocator = std.mem.Allocator;
const Mesh = mesh_module.Mesh;
const VertexPNU = mesh_module.VertexPNU;
const OwnedTexture = texture_module.OwnedTexture;
const c = sdl.c;

fn deinitItems(items: anytype) void {
    for (items) |*item| {
        item.deinit();
    }
}

fn deinitBorrowersThenOwners(borrowers: anytype, owners: anytype) void {
    deinitItems(borrowers);
    deinitItems(owners);
}

fn checkedRgba8ImageByteSize(width: u32, height: u32) !usize {
    if (width == 0 or height == 0) return error.InvalidImageDimensions;

    const pixel_count = std.math.mul(usize, width, height) catch
        return error.ImageTooLarge;
    const byte_count = std.math.mul(usize, pixel_count, 4) catch
        return error.ImageTooLarge;
    if (byte_count > std.math.maxInt(u32)) return error.ImageTooLarge;
    return byte_count;
}

// ============================================================================
// Public Types
// ============================================================================

/// A loaded 3D model containing one or more meshes.
/// Call deinit() when done to release GPU resources.
pub const LoadedModel = struct {
    meshes: []Mesh,
    /// Owns every texture borrowed by a mesh in `meshes`.
    textures: []OwnedTexture,
    allocator: Allocator,

    /// Release all GPU resources and memory.
    pub fn deinit(self: *LoadedModel) void {
        // Destroy borrowers before the resources they reference.
        deinitBorrowersThenOwners(self.meshes, self.textures);
        self.allocator.free(self.meshes);
        self.allocator.free(self.textures);
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
pub fn loadGlb(io: std.Io, allocator: Allocator, device: *c.SDL_GPUDevice, path: [:0]const u8) !LoadedModel {
    // =========================================================================
    // Step 0: Initialize zmesh and zstbi (required before any calls)
    // =========================================================================
    zmesh.init(allocator);
    defer zmesh.deinit();

    zstbi.init(io, allocator);
    defer zstbi.deinit();

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

    var initialized_meshes: usize = 0;
    var textures: std.ArrayListUnmanaged(OwnedTexture) = .empty;

    // One rollback path owns every initialized GPU resource. Borrowing meshes
    // are always destroyed before their texture owners, matching LoadedModel's
    // successful teardown order.
    errdefer {
        deinitBorrowersThenOwners(meshes[0..initialized_meshes], textures.items);
        textures.deinit(allocator);
    }

    // =========================================================================
    // Step 4: Extract each primitive
    // =========================================================================
    for (0..data.meshes_count) |mi| {
        const gltf_mesh = gltf_meshes[mi];
        for (0..gltf_mesh.primitives_count) |pi| {
            // Temporary arrays for vertex data (zmesh appends to these)
            var indices: std.ArrayListUnmanaged(u32) = .empty;
            defer indices.deinit(allocator);

            var positions: std.ArrayListUnmanaged([3]f32) = .empty;
            defer positions.deinit(allocator);

            var normals: std.ArrayListUnmanaged([3]f32) = .empty;
            defer normals.deinit(allocator);

            var texcoords: std.ArrayListUnmanaged([2]f32) = .empty;
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
            const mesh_idx = initialized_meshes;
            meshes[mesh_idx] = try Mesh.initIndexed(device, vertices, indices.items);
            initialized_meshes += 1;

            // =========================================================================
            // Step 7: Extract texture from material (if present)
            // =========================================================================
            const primitive = gltf_mesh.primitives[pi];

            // Check if primitive has a material with a base color texture
            if (primitive.material) |material| {
                if (material.has_pbr_metallic_roughness != 0) {
                    const pbr = material.pbr_metallic_roughness;
                    if (pbr.base_color_texture.texture) |tex| {
                        if (tex.image) |image| {
                            if (loadTextureFromImage(allocator, device, data, image)) |loaded_texture| {
                                // ArrayList append is the ownership transfer.
                                // If allocating its storage fails, release the
                                // just-created SDL resource before unwinding the
                                // already initialized model prefix.
                                var owned_texture = loaded_texture;
                                const view = owned_texture.borrow();
                                textures.append(allocator, owned_texture) catch |err| {
                                    owned_texture.deinit();
                                    return err;
                                };
                                meshes[mesh_idx].diffuse_texture = view;
                                std.debug.print("    Loaded diffuse texture: {d}x{d}\n", .{ view.width, view.height });
                            } else |err| {
                                // A missing or currently unsupported optional
                                // image deliberately falls back to the renderer's
                                // placeholder. Invalid image data, allocation
                                // failures, and all GPU creation/upload failures
                                // make the whole load fail transactionally.
                                if (isOptionalTextureFallback(err)) {
                                    std.debug.print("    Warning: Optional texture unavailable ({any}); using placeholder\n", .{err});
                                } else {
                                    return err;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    const owned_textures = try textures.toOwnedSlice(allocator);

    std.debug.print("Successfully loaded {d} mesh(es) from GLB\n", .{initialized_meshes});

    return LoadedModel{
        .meshes = meshes,
        .textures = owned_textures,
        .allocator = allocator,
    };
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Load a texture from a glTF image structure.
/// Handles both embedded (buffer view) and external (URI) images.
fn loadTextureFromImage(
    allocator: Allocator,
    device: *c.SDL_GPUDevice,
    data: *zmesh.io.zcgltf.Data,
    image: *zmesh.io.zcgltf.Image,
) !OwnedTexture {
    _ = data; // Reserved for future external URI support

    // Get image data - either from buffer view (embedded) or URI
    const image_data: []const u8 = blk: {
        if (image.buffer_view) |buffer_view| {
            // Embedded image in GLB buffer
            const buffer = buffer_view.buffer;
            const buffer_data_ptr: [*]const u8 = @ptrCast(buffer.data orelse return error.NoBufferData);
            const offset = buffer_view.offset;
            const size = buffer_view.size;
            break :blk buffer_data_ptr[offset .. offset + size];
        } else if (image.uri) |_| {
            // External image file - not supported for now
            std.debug.print("External texture URIs not yet supported\n", .{});
            return error.ExternalTextureNotSupported;
        } else {
            return error.NoImageData;
        }
    };

    // Decode image using zstbi (handles PNG, JPEG, etc.)
    // Second parameter is desired_channels: 4 = RGBA
    var img = zstbi.Image.loadFromMemory(image_data, 4) catch |err| {
        std.debug.print("Failed to decode image: {any}\n", .{err});
        return error.ImageDecodeFailed;
    };
    defer img.deinit();

    // Create GPU texture from decoded pixels
    const width = img.width;
    const height = img.height;
    const image_byte_size = try checkedRgba8ImageByteSize(width, height);
    if (img.data.len != image_byte_size) return error.InvalidDecodedImageSize;

    // Allocate a separate buffer for the texture data since zstbi data will be freed
    const pixels = allocator.alloc(u8, image_byte_size) catch return error.OutOfMemory;
    defer allocator.free(pixels);
    @memcpy(pixels, img.data);

    return texture_module.createTexture(device, width, height, pixels);
}

/// These cases mean the material's optional image cannot be resolved by the
/// current loader. They are a deliberate placeholder fallback, unlike invalid
/// encoded data, allocator failure, or GPU creation/upload failure.
fn isOptionalTextureFallback(err: anyerror) bool {
    return switch (err) {
        error.NoBufferData,
        error.ExternalTextureNotSupported,
        error.NoImageData,
        => true,
        else => false,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "LoadedModel struct is valid" {
    // Compile-time check that the struct is valid
    _ = LoadedModel;
}

test "loadGlb implementation remains type checked without a GPU" {
    // Zig analyzes function bodies lazily. A volatile false guard keeps the
    // production loader call in this test's semantic graph without executing
    // filesystem or GPU work in the unit-test process.
    var execute = false;
    const execute_volatile: *volatile bool = &execute;
    if (execute_volatile.*) {
        const device: *c.SDL_GPUDevice = @ptrFromInt(0x1000);
        var model = try loadGlb(std.testing.io, std.testing.allocator, device, "");
        model.deinit();
    }
}

test "optional texture fallback policy does not hide resource failures" {
    try std.testing.expect(isOptionalTextureFallback(error.NoImageData));
    try std.testing.expect(isOptionalTextureFallback(error.ExternalTextureNotSupported));
    try std.testing.expect(!isOptionalTextureFallback(error.ImageDecodeFailed));
    try std.testing.expect(!isOptionalTextureFallback(error.OutOfMemory));
    try std.testing.expect(!isOptionalTextureFallback(error.TextureCreationFailed));
    try std.testing.expect(!isOptionalTextureFallback(error.CommandBufferSubmitFailed));
    try std.testing.expect(!isOptionalTextureFallback(error.FenceWaitFailed));
}

test "transaction cleanup destroys only the initialized prefix" {
    const FakeResource = struct {
        deinit_count: *usize,

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };

    var first_count: usize = 0;
    var second_count: usize = 0;
    var uninitialized_count: usize = 0;
    var resources = [_]FakeResource{
        .{ .deinit_count = &first_count },
        .{ .deinit_count = &second_count },
        .{ .deinit_count = &uninitialized_count },
    };

    deinitItems(resources[0..2]);

    try std.testing.expectEqual(@as(usize, 1), first_count);
    try std.testing.expectEqual(@as(usize, 1), second_count);
    try std.testing.expectEqual(@as(usize, 0), uninitialized_count);
}

test "resource teardown destroys borrowers before owners" {
    const FakeResource = struct {
        id: u8,
        next: *usize,
        order: *[2]u8,

        fn deinit(self: *@This()) void {
            self.order[self.next.*] = self.id;
            self.next.* += 1;
        }
    };

    var next: usize = 0;
    var order = [_]u8{ 0, 0 };
    var borrowers = [_]FakeResource{.{ .id = 1, .next = &next, .order = &order }};
    var owners = [_]FakeResource{.{ .id = 2, .next = &next, .order = &order }};

    deinitBorrowersThenOwners(&borrowers, &owners);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &order);
}

test "RGBA8 image byte sizes reject empty and over-u32 images" {
    try std.testing.expectError(error.InvalidImageDimensions, checkedRgba8ImageByteSize(0, 1));
    try std.testing.expectError(error.InvalidImageDimensions, checkedRgba8ImageByteSize(1, 0));
    try std.testing.expectEqual(@as(usize, 4), try checkedRgba8ImageByteSize(1, 1));

    const largest_pixel_count = std.math.maxInt(u32) / 4;
    try std.testing.expectEqual(
        @as(usize, largest_pixel_count * 4),
        try checkedRgba8ImageByteSize(largest_pixel_count, 1),
    );
    try std.testing.expectError(
        error.ImageTooLarge,
        checkedRgba8ImageByteSize(largest_pixel_count + 1, 1),
    );
    try std.testing.expectError(
        error.ImageTooLarge,
        checkedRgba8ImageByteSize(std.math.maxInt(u32), 2),
    );
}
