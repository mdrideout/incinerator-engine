//! scene_tool.zig - Scene Hierarchy and Inspector Tool
//!
//! DOMAIN: Editor Layer (Tool)
//!
//! This tool provides visibility into the game world:
//! - Lists all entities in the scene hierarchy
//! - Allows selecting entities by clicking
//! - Shows properties of the selected entity (transform, mesh info)
//!
//! Why is this useful?
//! ------------------
//! 1. Visibility: See what's actually in your world at runtime
//! 2. Selection: Click to select entities for inspection or manipulation
//! 3. Debugging: "Why isn't my entity showing?" - check if it exists
//! 4. Foundation: Selection is the first step toward gizmo manipulation
//!
//! Architecture Note:
//! ------------------
//! The EditorContext has a `selected_entity: ?u64` field that stores the
//! currently selected entity's flecs ID. This is shared across all tools, so the
//! Scene Tool can set it and a future Inspector Tool can read it.

const std = @import("std");
const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const ecs = @import("../../ecs.zig");

const Tool = tool_module.Tool;
const EditorContext = tool_module.EditorContext;

// ============================================================================
// Tool Definition
// ============================================================================

/// The Scene tool instance.
/// Starts disabled - enable from Tools menu when needed.
pub var tool = Tool{
    .name = "Scene",
    .enabled = false, // Start hidden
    .draw_fn = draw,
};

// ============================================================================
// Draw Function
// ============================================================================

fn draw(ctx: *EditorContext) void {
    // ========================================================================
    // Window Setup
    // ========================================================================
    zgui.setNextWindowPos(.{
        .x = 300, // To the right of Stats/Camera tools
        .y = 30,
        .cond = .first_use_ever,
    });
    zgui.setNextWindowSize(.{
        .w = 280,
        .h = 400,
        .cond = .first_use_ever,
    });

    if (zgui.begin("Scene", .{})) {
        // Cast away const to call query methods (queries don't modify world state)
        const world = @constCast(ctx.world);
        const entity_count = world.entityCount();

        // ====================================================================
        // Entity List Header
        // ====================================================================
        zgui.text("Entities ({d} total)", .{entity_count});
        zgui.separator();

        // ====================================================================
        // Renderable Entity List
        // ====================================================================
        // Display each renderable entity as a selectable item.
        // Clicking an entity selects it (stored in ctx.selected_entity).

        // Count renderable entities (separate from total flecs entities)
        var renderable_count: u32 = 0;

        // First pass: count and build entity list
        var iter = world.renderables();
        defer iter.deinit(); // Clean up iterator when done
        while (iter.next()) |_| {
            renderable_count += 1;
        }

        if (renderable_count == 0) {
            zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "(no renderable entities)", .{});
        } else {
            zgui.text("Renderables ({d})", .{renderable_count});
            zgui.spacing();

            // Second pass: draw selectable list
            var iter2 = world.renderables();
            defer iter2.deinit(); // Clean up iterator when done
            var display_idx: u32 = 0;
            while (iter2.next()) |entity| {
                // Create a unique label for each entity
                var label_buf: [64]u8 = undefined;
                const label = std.fmt.bufPrintZ(&label_buf, "Entity {d}##ent{d}", .{ entity.entity, display_idx }) catch "Entity";

                // Check if this entity is currently selected
                const is_selected = if (ctx.selected_entity) |sel| sel == entity.entity else false;

                // Selectable widget - returns true when clicked
                if (zgui.selectable(label, .{
                    .selected = is_selected,
                })) {
                    // Toggle selection: clicking selected entity deselects it
                    if (is_selected) {
                        ctx.selected_entity = null;
                    } else {
                        ctx.selected_entity = entity.entity;
                    }
                }

                // Show a brief summary on the same line
                zgui.sameLine(.{});
                zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "({d:.1}, {d:.1}, {d:.1})", .{
                    entity.position.x,
                    entity.position.y,
                    entity.position.z,
                });

                display_idx += 1;
            }
        }

        // ====================================================================
        // Selected Entity Inspector
        // ====================================================================
        // When an entity is selected, show its full properties below.

        zgui.spacing();
        zgui.separator();

        if (ctx.selected_entity) |selected_id| {
            // Find the selected entity in the renderable query
            var found_entity: ?ecs.GameWorld.RenderableEntity = null;
            var iter3 = world.renderables();
            defer iter3.deinit(); // IMPORTANT: iter may break early, must finalize
            while (iter3.next()) |entity| {
                if (entity.entity == selected_id) {
                    found_entity = entity;
                    break;
                }
            }

            if (found_entity) |entity| {
                zgui.text("Selected: Entity {d}", .{entity.entity});
                zgui.spacing();

                // Transform section
                if (zgui.collapsingHeader("Transform", .{ .default_open = true })) {
                    zgui.indent(.{});

                    // Position
                    zgui.text("Position", .{});
                    zgui.text("  X: {d:.3}", .{entity.position.x});
                    zgui.text("  Y: {d:.3}", .{entity.position.y});
                    zgui.text("  Z: {d:.3}", .{entity.position.z});

                    zgui.spacing();

                    // Rotation (Euler angles in radians)
                    const rad_to_deg = 180.0 / std.math.pi;
                    zgui.text("Rotation (Euler)", .{});
                    zgui.text("  X: {d:.1} deg ({d:.3} rad)", .{ entity.rotation.x * rad_to_deg, entity.rotation.x });
                    zgui.text("  Y: {d:.1} deg ({d:.3} rad)", .{ entity.rotation.y * rad_to_deg, entity.rotation.y });
                    zgui.text("  Z: {d:.1} deg ({d:.3} rad)", .{ entity.rotation.z * rad_to_deg, entity.rotation.z });

                    zgui.spacing();

                    // Scale
                    zgui.text("Scale", .{});
                    zgui.text("  X: {d:.3}", .{entity.scale.x});
                    zgui.text("  Y: {d:.3}", .{entity.scale.y});
                    zgui.text("  Z: {d:.3}", .{entity.scale.z});

                    zgui.unindent(.{});
                }

                // Mesh section
                if (zgui.collapsingHeader("Mesh", .{ .default_open = true })) {
                    zgui.indent(.{});

                    const mesh_ptr = entity.mesh;

                    // Show vertex count
                    zgui.text("Vertices: {d}", .{mesh_ptr.vertex_count});

                    // Show index count if indexed
                    if (mesh_ptr.index_count > 0) {
                        zgui.text("Indices: {d}", .{mesh_ptr.index_count});
                        zgui.text("Triangles: {d}", .{mesh_ptr.index_count / 3});
                    } else {
                        zgui.text("Triangles: {d}", .{mesh_ptr.vertex_count / 3});
                    }

                    // Show vertex format
                    const format_str = switch (mesh_ptr.vertex_format) {
                        .pos_color => "Position + Color",
                        .pos_normal_uv => "Position + Normal + UV",
                    };
                    zgui.text("Format: {s}", .{format_str});

                    // Show texture info
                    if (mesh_ptr.diffuse_texture) |_| {
                        zgui.textColored(.{ 0.3, 0.8, 0.3, 1.0 }, "Has diffuse texture", .{});
                    } else {
                        zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "No texture", .{});
                    }

                    zgui.unindent(.{});
                }
            } else {
                // Selected entity no longer exists or isn't renderable
                zgui.textColored(.{ 1.0, 0.5, 0.5, 1.0 }, "Selected entity not found", .{});
                ctx.selected_entity = null;
            }
        } else {
            zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "No entity selected", .{});
            zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "Click an entity above to inspect", .{});
        }
    }
    zgui.end();
}
