//! gizmo_tool.zig - 3D Transform Manipulation Gizmo
//!
//! DOMAIN: Editor Layer (Tool)
//!
//! This tool renders ImGuizmo handles for manipulating entity transforms.
//! When an entity is selected, a 3D gizmo appears at its position allowing
//! translate, rotate, or scale operations via mouse drag.
//!
//! How It Works:
//! -------------
//! 1. Check if an entity is selected (ctx.selected_entity)
//! 2. Build a model matrix from entity's Position/Rotation/Scale
//! 3. Call gizmo.manipulate() which:
//!    - Draws the gizmo handles (arrows, circles, or boxes depending on mode)
//!    - Returns true if user dragged and modified the matrix
//! 4. If modified, decompose the new matrix back to Position/Rotation/Scale
//! 5. Write updated transform to ECS (or physics body if entity has RigidBody)
//!
//! Input Integration:
//! ------------------
//! - Left-click + drag on gizmo: manipulate transform
//! - W/E/R keys: switch between translate/rotate/scale modes (handled in editor.zig)
//! - Gizmo doesn't interfere with camera (right-click) controls
//!
//! Physics Integration:
//! --------------------
//! For entities with RigidBody components, we edit the physics body directly
//! rather than the ECS components. This prevents rubber-banding where physics
//! would immediately override our changes.
//!
//! While an entity is selected, its physics body is switched to kinematic mode.
//! This "freezes" the physics - the object won't fall or be affected by forces.
//! When deselected, it's restored to dynamic mode with velocities zeroed.
//! This allows multi-step manipulation (move up, then rotate) without fighting gravity.

const std = @import("std");
const zgui = @import("zgui");
const gizmo = zgui.gizmo;
const zm = @import("zmath");
const flecs = @import("zflecs");

const tool_module = @import("../tool.zig");
const ecs = @import("../../ecs.zig");
const physics = @import("jolt_physics");

const Tool = tool_module.Tool;
const EditorContext = tool_module.EditorContext;

// ============================================================================
// Tool Definition
// ============================================================================

/// The Gizmo tool instance.
/// Always enabled - gizmo only appears when an entity is selected.
pub var tool = Tool{
    .name = "Gizmo",
    .enabled = true, // Always on (only draws when entity selected)
    .draw_fn = draw,
};

// ============================================================================
// Physics Freeze State
// ============================================================================
// Track which entity was previously selected so we can detect selection changes.
// When selection changes, we unfreeze the old entity and freeze the new one.

/// The entity that was selected last frame (used to detect selection changes)
var previously_selected_entity: ?u64 = null;

/// The body ID of the currently frozen physics body (if any)
var frozen_body_id: ?physics.BodyId = null;

/// Whether the frozen body was originally dynamic (vs kinematic/static)
/// We only restore to dynamic if it was dynamic before freezing.
var was_originally_dynamic: bool = false;

/// The ECS entity ID of the frozen entity (needed to look up components on deselect)
var frozen_entity_id: ?u64 = null;

/// Original scale when entity was selected (to detect scale changes)
var original_scale: ecs.Scale = .{};

// ============================================================================
// Matrix Conversion Helpers
// ============================================================================

/// Convert zmath Mat (4x Vec4) to [16]f32 array for ImGuizmo.
/// ImGuizmo uses column-major order, same as zmath.
fn matToArray(mat: zm.Mat) [16]f32 {
    return .{
        // Column 0
        mat[0][0], mat[0][1], mat[0][2], mat[0][3],
        // Column 1
        mat[1][0], mat[1][1], mat[1][2], mat[1][3],
        // Column 2
        mat[2][0], mat[2][1], mat[2][2], mat[2][3],
        // Column 3
        mat[3][0], mat[3][1], mat[3][2], mat[3][3],
    };
}

/// Build a model matrix from Position, Rotation (quaternion), and Scale.
fn buildModelMatrix(pos: ecs.Position, rot: ecs.Rotation, scl: ecs.Scale) [16]f32 {
    // Build TRS matrix: Scale -> Rotate -> Translate
    const translation = zm.translation(pos.x, pos.y, pos.z);
    const rotation = rot.toMatrix();
    const scale = scl.toMatrix();

    // Order: Scale first, then Rotate, then Translate
    const model = zm.mul(zm.mul(scale, rotation), translation);
    return matToArray(model);
}

/// Convert a [16]f32 array back to zmath Mat.
fn arrayToMat(arr: [16]f32) zm.Mat {
    return .{
        .{ arr[0], arr[1], arr[2], arr[3] },
        .{ arr[4], arr[5], arr[6], arr[7] },
        .{ arr[8], arr[9], arr[10], arr[11] },
        .{ arr[12], arr[13], arr[14], arr[15] },
    };
}

/// Extract rotation quaternion directly from a transformation matrix.
/// This avoids Euler angle conversion issues (gimbal lock, convention mismatches).
fn extractRotationFromMatrix(model: [16]f32) ecs.Rotation {
    const mat = arrayToMat(model);

    // Extract the 3x3 rotation part and normalize the basis vectors
    // (to remove any scale that might be baked in)
    const col0 = zm.normalize3(.{ mat[0][0], mat[0][1], mat[0][2], 0 });
    const col1 = zm.normalize3(.{ mat[1][0], mat[1][1], mat[1][2], 0 });
    const col2 = zm.normalize3(.{ mat[2][0], mat[2][1], mat[2][2], 0 });

    // Rebuild a pure rotation matrix
    const rot_mat: zm.Mat = .{
        .{ col0[0], col0[1], col0[2], 0 },
        .{ col1[0], col1[1], col1[2], 0 },
        .{ col2[0], col2[1], col2[2], 0 },
        .{ 0, 0, 0, 1 },
    };

    // Convert rotation matrix to quaternion
    const quat = zm.matToQuat(rot_mat);
    return .{
        .x = quat[0],
        .y = quat[1],
        .z = quat[2],
        .w = quat[3],
    };
}

// ============================================================================
// Physics Freeze/Unfreeze Logic
// ============================================================================

/// Handle entity selection changes for physics freezing.
/// When an entity is selected, freeze its physics body (switch to kinematic).
/// When deselected, unfreeze it (switch back to dynamic with zeroed velocities).
/// If scale changed during manipulation, replace the body's shape in place.
fn handleSelectionChange(world: *ecs.GameWorld, current_selection: ?u64) void {
    // Check if selection has changed
    if (current_selection == previously_selected_entity) {
        return; // No change, nothing to do
    }

    // Selection changed - first unfreeze the previously selected entity
    if (frozen_body_id) |body_id| {
        if (world.physics_world) |pw| {
            if (was_originally_dynamic) {
                // Motion state restoration must happen even if collider resizing
                // fails, otherwise closing/changing selection can strand a body
                // in the editor's temporary kinematic state.
                defer {
                    pw.setMotionType(body_id, .dynamic) catch |err| {
                        std.log.err("could not restore editor body motion type: {s}", .{@errorName(err)});
                    };
                    pw.setLinearVelocity(body_id, .{ 0, 0, 0 }) catch |err| {
                        std.log.err("could not reset editor body linear velocity: {s}", .{@errorName(err)});
                    };
                    pw.setAngularVelocity(body_id, .{ 0, 0, 0 }) catch |err| {
                        std.log.err("could not reset editor body angular velocity: {s}", .{@errorName(err)});
                    };
                }

                // Check if scale changed during manipulation
                if (frozen_entity_id) |entity_id| {
                    if (world.get(@intCast(entity_id), ecs.Scale)) |current_scale| {
                        if (!scaleEquals(original_scale, current_scale.*)) {
                            resizePhysicsBox(pw, body_id, current_scale.*) catch |err| {
                                // Rendering and collision dimensions must not
                                // diverge if the shape replacement is rejected.
                                world.set(@intCast(entity_id), ecs.Scale, original_scale);
                                std.log.err(
                                    "could not resize physics body for entity {d}: {s}",
                                    .{ entity_id, @errorName(err) },
                                );
                            };
                        }
                    }
                }
            }
        }
        frozen_body_id = null;
        frozen_entity_id = null;
        was_originally_dynamic = false;
        original_scale = .{};
    }

    // Now freeze the newly selected entity (if any)
    freezeNewSelection(world, current_selection);

    // Update tracking
    previously_selected_entity = current_selection;
}

/// Release any temporary kinematic edit state when the gizmo cannot run (for
/// example when its tool or the entire editor is hidden).
pub fn releaseInteraction(world: *ecs.GameWorld) void {
    handleSelectionChange(world, null);
}

/// Freeze a newly selected entity's physics body.
fn freezeNewSelection(world: *ecs.GameWorld, selection: ?u64) void {
    const selected_id = selection orelse return;

    if (world.get(@intCast(selected_id), ecs.RigidBody)) |rb| {
        if (world.physics_world) |pw| {
            // Check if it's currently dynamic
            const motion_type = pw.getMotionType(rb.body_id) catch |err| {
                std.log.err("could not inspect selected physics body: {s}", .{@errorName(err)});
                return;
            };
            if (motion_type == .dynamic) {
                // Switch to kinematic to freeze physics
                pw.setMotionType(rb.body_id, .kinematic) catch |err| {
                    std.log.err("could not freeze selected physics body: {s}", .{@errorName(err)});
                    return;
                };
                frozen_body_id = rb.body_id;
                frozen_entity_id = selected_id;
                was_originally_dynamic = true;

                // Store original scale for comparison on deselect
                if (world.get(@intCast(selected_id), ecs.Scale)) |scl| {
                    original_scale = scl.*;
                } else {
                    original_scale = .{}; // Default scale
                }
            }
        }
    }
}

/// Check if two scales are approximately equal.
fn scaleEquals(a: ecs.Scale, b: ecs.Scale) bool {
    const epsilon: f32 = 0.001;
    return @abs(a.x - b.x) < epsilon and
        @abs(a.y - b.y) < epsilon and
        @abs(a.z - b.z) < epsilon;
}

/// Resize a box collider without replacing the body or its ECS handle.
fn resizePhysicsBox(
    pw: *physics.Physics,
    body_id: physics.BodyId,
    new_scale: ecs.Scale,
) !void {
    // The original box was created with half_extents of 0.5 (1 unit cube)
    // Scale that by the new scale values
    const base_half_extent: f32 = 0.5;
    const half_extents = [3]f32{
        base_half_extent * new_scale.x,
        base_half_extent * new_scale.y,
        base_half_extent * new_scale.z,
    };

    try pw.setBoxHalfExtents(body_id, half_extents);
}

// ============================================================================
// Draw Function
// ============================================================================

fn draw(ctx: *EditorContext) void {
    // ========================================================================
    // Initialize ImGuizmo for this frame
    // ========================================================================
    // IMPORTANT: Must call beginFrame() after ImGui's newFrame() but before
    // any gizmo operations. This sets up ImGuizmo's internal state.
    gizmo.beginFrame();

    // ========================================================================
    // Handle Selection Changes (Physics Freeze/Unfreeze)
    // ========================================================================
    // Detect when selection changes and manage physics body states accordingly.
    const world = @constCast(ctx.world);
    handleSelectionChange(world, ctx.selected_entity);

    // ========================================================================
    // Early Exit: No entity selected
    // ========================================================================
    const selected_id = ctx.selected_entity orelse return;

    // ========================================================================
    // Get Entity Components
    // ========================================================================

    // Look up transform components
    const pos_ptr = world.get(@intCast(selected_id), ecs.Position);
    const rot_ptr = world.get(@intCast(selected_id), ecs.Rotation);
    const scl_ptr = world.get(@intCast(selected_id), ecs.Scale);

    // Need at least position to show gizmo
    const pos = pos_ptr orelse return;
    // Dereference optional pointers, using defaults if component not present
    const rot = if (rot_ptr) |r| r.* else ecs.Rotation{};
    const scl = if (scl_ptr) |s| s.* else ecs.Scale{};

    // ========================================================================
    // Setup Gizmo Viewport
    // ========================================================================
    // ImGuizmo needs to know the viewport rect to correctly position the gizmo.
    // This should match the window/viewport where the 3D scene is rendered.
    gizmo.setRect(
        0,
        0,
        @floatFromInt(ctx.window_width),
        @floatFromInt(ctx.window_height),
    );
    gizmo.setOrthographic(false); // We use perspective projection

    // ========================================================================
    // Get Camera Matrices
    // ========================================================================
    const aspect = @as(f32, @floatFromInt(ctx.window_width)) /
        @as(f32, @floatFromInt(ctx.window_height));

    const view = matToArray(ctx.camera.getViewMatrix());
    const proj = matToArray(ctx.camera.getProjectionMatrix(aspect));

    // ========================================================================
    // Build Model Matrix from Entity Transform
    // ========================================================================
    var model_matrix = buildModelMatrix(pos.*, rot, scl);

    // ========================================================================
    // Convert Editor Enums to ImGuizmo Types
    // ========================================================================
    const operation: gizmo.Operation = switch (ctx.gizmo_mode) {
        .translate => gizmo.Operation.translate(),
        .rotate => gizmo.Operation.rotate(),
        .scale => gizmo.Operation.scale(),
    };

    const mode: gizmo.Mode = switch (ctx.gizmo_space) {
        .local => .local,
        .world => .world,
    };

    // ========================================================================
    // Draw Gizmo and Handle Manipulation
    // ========================================================================
    // manipulate() draws the gizmo and returns true if the user modified it.
    // The model_matrix is modified in-place when the user drags handles.
    if (gizmo.manipulate(&view, &proj, operation, mode, &model_matrix, .{})) {
        // User modified the transform - extract components directly from matrix
        // We use decomposeMatrixToComponents only for translation and scale,
        // then extract rotation directly as quaternion to avoid Euler issues.
        var new_translation: [3]f32 = undefined;
        var euler_unused: [3]f32 = undefined;
        var new_scale: [3]f32 = undefined;

        gizmo.decomposeMatrixToComponents(
            &model_matrix,
            &new_translation,
            &euler_unused, // We ignore this - extract quat directly instead
            &new_scale,
        );

        // Extract rotation as quaternion directly from the matrix
        // This avoids Euler angle convention mismatches and gimbal lock
        const new_rot = extractRotationFromMatrix(model_matrix);

        // Apply the transform
        applyTransform(
            world,
            @intCast(selected_id),
            new_translation,
            new_rot,
            new_scale,
        ) catch |err| {
            std.log.err("could not apply gizmo transform: {s}", .{@errorName(err)});
        };
    }
}

// ============================================================================
// Transform Application
// ============================================================================

/// Apply a new transform to an entity.
/// If the entity has a RigidBody, update the physics body directly.
/// Otherwise, update the ECS components.
fn applyTransform(
    world: *ecs.GameWorld,
    entity: flecs.entity_t,
    pos: [3]f32,
    rot: ecs.Rotation,
    scl: [3]f32,
) !void {
    // Check if entity has a physics body
    if (world.get(entity, ecs.RigidBody)) |rb| {
        // ====================================================================
        // Physics Entity: Update physics body directly
        // ====================================================================
        // For dynamic bodies, physics is the source of truth. If we only
        // updated ECS, the physics simulation would immediately override our
        // changes on the next tick (rubber-banding).
        if (world.physics_world) |pw| {
            try pw.setBodyPosition(rb.body_id, pos);
            try pw.setBodyRotation(rb.body_id, .{ rot.x, rot.y, rot.z, rot.w });
        }

        // Also update ECS for immediate visual feedback
        // (physics sync will overwrite this next tick, but it provides
        // smooth visual feedback while dragging)
        world.set(entity, ecs.Position, .{ .x = pos[0], .y = pos[1], .z = pos[2] });
        world.set(entity, ecs.Rotation, rot);
    } else {
        // ====================================================================
        // Non-Physics Entity: Update ECS directly
        // ====================================================================
        // Visual-only entities (loaded models, decorations) have no physics
        // body, so we update ECS components directly.
        world.set(entity, ecs.Position, .{ .x = pos[0], .y = pos[1], .z = pos[2] });
        world.set(entity, ecs.Rotation, rot);
    }

    // Scale is always stored in ECS (physics bodies don't have runtime scale)
    world.set(entity, ecs.Scale, .{ .x = scl[0], .y = scl[1], .z = scl[2] });
}

test "suspending the gizmo restores a selected dynamic body" {
    var physics_world = try physics.Physics.init();
    defer physics_world.deinit();

    var world = try ecs.GameWorld.init();
    defer world.deinit();
    world.setPhysicsWorld(&physics_world);

    const body_id = try physics_world.createDynamicBox(.{ 0, 2, 0 }, .{ 0.5, 0.5, 0.5 });
    const entity = try world.spawn(.{ .scale = .{} });
    world.set(entity, ecs.RigidBody, .{ .body_id = body_id });

    handleSelectionChange(&world, @intCast(entity));
    try std.testing.expectEqual(physics.MotionType.kinematic, try physics_world.getMotionType(body_id));

    releaseInteraction(&world);
    try std.testing.expectEqual(physics.MotionType.dynamic, try physics_world.getMotionType(body_id));
}
