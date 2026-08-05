//! Read-only S4 developer diagnostics and narrow host-time controls.

const zgui = @import("zgui");
const tool_module = @import("../tool.zig");
const engine = @import("incinerator_engine");
const developer_diagnostics = @import("developer_diagnostics");

const DeveloperInput = tool_module.DeveloperInput;

pub const descriptor = tool_module.Descriptor{
    .id = .diagnostics,
    .name = "Diagnostics",
    .enabled_by_default = true,
};

fn drawQueue(label: [:0]const u8, queue: anytype) void {
    if (queue.capacity) |capacity| {
        zgui.text(
            "{s}: {d}/{d} (peak {d}, rejected {d})",
            .{ label, queue.occupancy, capacity, queue.high_water, queue.rejected },
        );
    } else {
        zgui.text(
            "{s}: {d}/unbounded (peak {d}, rejected {d})",
            .{ label, queue.occupancy, queue.high_water, queue.rejected },
        );
    }
}

fn request(ctx: *const DeveloperInput, value: @import("developer_controls").Request) void {
    _ = ctx.control_requests.push(value);
}

fn diagnosticRequest(ctx: *const DeveloperInput, value: developer_diagnostics.Request) void {
    _ = ctx.diagnostic_requests.push(value);
}

fn diagnosticCodeLabel(code: engine.diagnostic_contracts.Code) []const u8 {
    const codes = engine.diagnostic_contracts.codes;
    return switch (code) {
        codes.runtime_system_fault => "runtime_system_fault",
        codes.district_load_requested => "district_load_requested",
        codes.district_cancellation_requested => "district_cancellation_requested",
        codes.district_cancelled => "district_cancelled",
        codes.district_load_failed => "district_load_failed",
        codes.district_activated => "district_activated",
        codes.district_unloaded => "district_unloaded",
        codes.district_stream_content_requested => "stream_content_requested",
        codes.district_stream_content_cancel_requested => "stream_content_cancel_requested",
        codes.district_stream_content_cancelled => "stream_content_cancelled",
        codes.district_stream_content_ready => "stream_content_ready",
        codes.district_stream_content_failed => "stream_content_failed",
        codes.district_stream_logical_submitted => "stream_logical_submitted",
        codes.district_stream_logical_cancel_submitted => "stream_logical_cancel_submitted",
        codes.district_stream_logical_unload_submitted => "stream_logical_unload_submitted",
        codes.district_stream_logical_admitted => "stream_logical_admitted",
        codes.district_stream_logical_activated => "stream_logical_activated",
        codes.district_stream_logical_cancelled => "stream_logical_cancelled",
        codes.district_stream_logical_unloaded => "stream_logical_unloaded",
        codes.district_stream_logical_failed => "stream_logical_failed",
        codes.district_stream_gpu_reserved => "stream_gpu_reserved",
        codes.district_stream_gpu_staged => "stream_gpu_staged",
        codes.district_stream_gpu_submitted => "stream_gpu_submitted",
        codes.district_stream_gpu_resident => "stream_gpu_resident",
        codes.district_stream_gpu_release_requested => "stream_gpu_release_requested",
        codes.district_stream_gpu_drained => "stream_gpu_drained",
        else => "custom",
    };
}

pub fn draw(ctx: *const DeveloperInput) void {
    zgui.setNextWindowPos(.{ .x = 300, .y = 30, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 540, .h = 640, .cond = .first_use_ever });
    if (zgui.begin("Diagnostics", .{})) {
        const snapshot = ctx.snapshot;
        const simulation = snapshot.simulation;

        if (simulation.first_fault) |fault| {
            zgui.textColored(.{ 1, 0.25, 0.2, 1 }, "RUNTIME FAULT", .{});
            zgui.text(
                "tick {d} phase {s} code {d}",
                .{ fault.tick_index, @tagName(fault.phase), fault.error_code },
            );
            zgui.text(
                "system: {s}{s}",
                .{
                    fault.system_name.slice(),
                    if (fault.system_name.truncated) " [truncated]" else "",
                },
            );
            zgui.text(
                "error: {s}{s}",
                .{
                    fault.error_name.slice(),
                    if (fault.error_name.truncated) " [truncated]" else "",
                },
            );
        } else {
            zgui.textColored(
                .{ 0.25, 0.9, 0.35, 1 },
                "Simulation runtime healthy",
                .{},
            );
        }

        if (snapshot.authority_session) |authority| {
            const cycle = authority.last_cycle;
            if (authority.first_cycle_fault) |fault| {
                zgui.textColored(
                    .{ 1, 0.25, 0.2, 1 },
                    "AUTHORITY CYCLE FAULT",
                    .{},
                );
                zgui.text(
                    "stage {s} | target {d} | completed {d} | code {d}",
                    .{
                        @tagName(fault.stage),
                        fault.target_tick,
                        fault.completed_tick,
                        fault.error_code,
                    },
                );
                zgui.text(
                    "error: {s}{s}",
                    .{
                        fault.error_name.slice(),
                        if (fault.error_name.truncated) " [truncated]" else "",
                    },
                );
            } else {
                zgui.textColored(
                    .{ 0.25, 0.9, 0.35, 1 },
                    "Authority session healthy",
                    .{},
                );
            }
            zgui.text(
                "Authority tick {d} | cycle target {d} | completed {d}->{d}",
                .{
                    authority.tick,
                    cycle.target_tick,
                    cycle.completed_tick_before,
                    cycle.completed_tick_after,
                },
            );
            zgui.text(
                "Completed stages {d}/{d} | failed {s}",
                .{
                    cycle.count,
                    cycle.stages.len,
                    if (cycle.failed_stage) |stage| @tagName(stage) else "none",
                },
            );
            for (cycle.stages[0..@as(usize, cycle.count)], 0..) |stage, index| {
                zgui.text("  {d}: {s}", .{ index + 1, @tagName(stage) });
            }
        } else {
            zgui.text("Authority session diagnostics: unavailable", .{});
        }

        zgui.separator();
        zgui.text(
            "Tick {d} | entities {d} | bodies {d} ({d} active)",
            .{
                simulation.tick_index,
                simulation.entity_count,
                simulation.body_count,
                simulation.active_body_count,
            },
        );
        const character_controllers = simulation.character_controllers;
        zgui.text(
            "CharacterVirtual native {d}/{d} | feature-owned {d} | consistent {}",
            .{
                character_controllers.native_used,
                character_controllers.native_capacity,
                character_controllers.feature_owned,
                character_controllers.authority_consistent,
            },
        );

        if (snapshot.host_time) |host_time| {
            var paused = host_time.paused;
            if (zgui.checkbox("Paused", .{ .v = &paused })) {
                request(ctx, .{ .set_paused = paused });
            }
            zgui.sameLine(.{});
            if (zgui.button("Single tick", .{})) request(ctx, .single_step);
            zgui.text("Time scale:", .{});
            inline for (.{
                @import("developer_controls").TimeScale.quarter,
                @import("developer_controls").TimeScale.half,
                @import("developer_controls").TimeScale.normal,
                @import("developer_controls").TimeScale.double,
            }) |scale| {
                if (zgui.button(@tagName(scale), .{})) {
                    request(ctx, .{ .set_time_scale = scale });
                }
                zgui.sameLine(.{});
            }
            zgui.newLine();
            zgui.text(
                "UI request rejections: controls={d}, diagnostics={d}",
                .{
                    host_time.control_requests_rejected,
                    host_time.diagnostic_requests_rejected,
                },
            );
        } else {
            zgui.text("Presentation clock and controls: unavailable", .{});
        }

        zgui.separator();
        drawQueue("crate commands", simulation.crates.commands);
        drawQueue("crate outcomes", simulation.crates.outcomes);
        drawQueue("character commands", simulation.characters.commands);
        drawQueue("character outcomes", simulation.characters.outcomes);
        drawQueue("character events", simulation.characters.events);
        drawQueue("vehicle commands", simulation.vehicles.commands);
        drawQueue("vehicle outcomes", simulation.vehicles.outcomes);
        drawQueue("vehicle events", simulation.vehicles.events);
        drawQueue("district commands", simulation.district.commands);
        drawQueue("district outcomes", simulation.district.outcomes);
        drawQueue("district events", simulation.district.events);
        drawQueue("interaction commands", simulation.interaction.commands);
        drawQueue("interaction outcomes", simulation.interaction.outcomes);
        drawQueue("NPC commands", simulation.npc.commands);
        drawQueue("NPC outcomes", simulation.npc.outcomes);
        drawQueue("NPC events", simulation.npc.events);

        zgui.separator();
        zgui.text(
            "District active={d}, loading={d}, cancelling={d}, bodies={d}",
            .{
                simulation.district.active_count,
                simulation.district.loading_count,
                simulation.district.cancelling_count,
                simulation.district.body_count,
            },
        );
        for (simulation.district.slots, 0..) |slot, index| {
            if (slot.ticket) |ticket| {
                zgui.text(
                    "  slot {d}: {s}, request {?d}, coord ({d}, {d}), generation {d}",
                    .{
                        index,
                        @tagName(slot.state),
                        slot.request_id,
                        ticket.coord.x,
                        ticket.coord.z,
                        ticket.generation,
                    },
                );
            } else {
                zgui.text(
                    "  slot {d}: {s}, request {?d}",
                    .{ index, @tagName(slot.state), slot.request_id },
                );
            }
        }
        zgui.text(
            "Interaction active={d}, spatial={d}, held={d}, bodies={d}",
            .{
                simulation.interaction.active_count,
                simulation.interaction.spatially_owned_count,
                simulation.interaction.held_count,
                simulation.interaction.dynamic_body_count,
            },
        );
        const npc = simulation.npc;
        zgui.text(
            "NPC active={d}, waiting={d}, dormant={d}, controllers={d}, transfers={d}, suspended={d}, resumed={d}",
            .{
                npc.active_count,
                npc.waiting_count,
                npc.dormant_count,
                npc.controller_count,
                npc.transfers,
                npc.controllers_suspended,
                npc.controllers_resumed,
            },
        );
        const npc_event_drops = npc.event_drops;
        const npc_total_event_drops = npc_event_drops.state_changed +|
            npc_event_drops.owner_transferred +|
            npc_event_drops.goal_reached;
        zgui.text(
            "NPC event drops state={d}, owner={d}, goal={d}, total={d}",
            .{
                npc_event_drops.state_changed,
                npc_event_drops.owner_transferred,
                npc_event_drops.goal_reached,
                npc_total_event_drops,
            },
        );
        const encounter = simulation.npc_encounter;
        zgui.text(
            "Encounter records={d} patrol={d} pursue={d} windup={d} recovery={d} search={d} return={d}",
            .{
                encounter.records,
                encounter.patrolling,
                encounter.pursuing,
                encounter.attack_windup,
                encounter.attack_recovery,
                encounter.searching,
                encounter.returning,
            },
        );
        zgui.text(
            "Encounter LOS queries={d} deferred={d} targets +/switch/lost={d}/{d}/{d} attacks start/commit/cancel={d}/{d}/{d} hits={d}",
            .{
                encounter.los_queries,
                encounter.los_deferred,
                encounter.targets_acquired,
                encounter.targets_switched,
                encounter.targets_lost,
                encounter.attacks_started,
                encounter.attacks_committed,
                encounter.attacks_cancelled,
                encounter.hit_reactions,
            },
        );
        if (simulation.population) |population| {
            zgui.text(
                "Population live/awaiting/vacant/replacement={d}/{d}/{d}/{d} activity travel/dwell/wait/interrupted={d}/{d}/{d}/{d}",
                .{
                    population.live,
                    population.awaiting_spawn,
                    population.vacant,
                    population.replacement_pending,
                    population.traveling,
                    population.dwelling,
                    population.waiting_for_slot,
                    population.interrupted,
                },
            );
            zgui.text(
                "Population slots free/claimed/occupied={d}/{d}/{d} decisions={d} contentions={d} lease expirations={d} spawn retries={d}",
                .{
                    population.free_slots,
                    population.claimed_slots,
                    population.occupied_slots,
                    population.decisions,
                    population.slot_contentions,
                    population.lease_expirations,
                    population.spawn_retries.total(),
                },
            );
        } else {
            zgui.text("Population disabled", .{});
        }
        const procedural_worker = simulation.district_worker;
        zgui.text(
            "Procedural worker={s}, generation={?d}, started={}, cancel={}, completion={s}",
            .{
                @tagName(procedural_worker.state),
                procedural_worker.generation,
                procedural_worker.started,
                procedural_worker.cancellation_requested,
                if (procedural_worker.completion_kind) |kind| @tagName(kind) else "none",
            },
        );
        if (snapshot.district_streams) |streams| {
            const aggregates = streams.aggregates;
            zgui.text(
                "Visual streams desired={d}/{d}, transitioning={d}, active={d}, draining={d}, pending={d}, scenes={d}",
                .{
                    aggregates.desired_count,
                    developer_diagnostics.district_stream_slot_count,
                    aggregates.transitioning_count,
                    aggregates.active_count,
                    aggregates.draining_count,
                    aggregates.pending_decoded_scene_count,
                    aggregates.scene_count,
                },
            );
            for (streams.slots, 0..) |stream, index| {
                zgui.text(
                    "Slot {d} coord=({d},{d}) state={s} desired={} pending={} correlation={?d}",
                    .{
                        index,
                        stream.coord.x,
                        stream.coord.z,
                        @tagName(stream.state),
                        stream.desired_inside,
                        stream.pending_decoded_scene,
                        stream.correlation_id,
                    },
                );
                if (stream.scene) |scene| {
                    zgui.text(
                        "  generations content={?d}, logical={?d}; scene={d}:{d}",
                        .{
                            stream.generations.content,
                            stream.generations.logical,
                            scene.index,
                            scene.generation,
                        },
                    );
                } else {
                    zgui.text(
                        "  generations content={?d}, logical={?d}; scene=none",
                        .{
                            stream.generations.content,
                            stream.generations.logical,
                        },
                    );
                }
            }
        } else {
            zgui.text("Visual district streams: unavailable", .{});
        }
        if (snapshot.content_worker) |worker| {
            zgui.text(
                "Cooked worker={s}, generation={d}, started={}, cancel={}, completion={s}",
                .{
                    @tagName(worker.stage),
                    worker.generation,
                    worker.thread_started,
                    worker.cancellation_requested,
                    if (worker.completion_kind) |kind| @tagName(kind) else "none",
                },
            );
        }
        if (snapshot.gpu) |gpu| {
            zgui.text(
                "GPU scenes={d}/{d}, batches={d}/{d}",
                .{
                    gpu.current.live_scenes,
                    gpu.limits.scene_capacity,
                    gpu.current.active_batches,
                    gpu.limits.batch_capacity,
                },
            );
            zgui.text(
                "Residency reserved={d}, staged={d}, submitted={d}, resident={d}, retiring={d}",
                .{
                    gpu.current.reserved_scenes,
                    gpu.current.staged_scenes,
                    gpu.current.submitted_scenes,
                    gpu.current.resident_scenes,
                    gpu.current.retiring_scenes,
                },
            );
            zgui.text(
                "Bytes staged={d}, upload={d}, in-flight={d}, resident={d}",
                .{
                    gpu.current.staged_cpu_bytes,
                    gpu.current.staged_upload_bytes,
                    gpu.current.in_flight_upload_bytes,
                    gpu.current.resident_gpu_bytes,
                },
            );
            zgui.text(
                "Peaks staged={d}, in-flight={d}, resident={d}",
                .{
                    gpu.high_water.staged_cpu_bytes,
                    gpu.high_water.in_flight_upload_bytes,
                    gpu.high_water.resident_gpu_bytes,
                },
            );
        }

        zgui.separator();
        zgui.text(
            "Journal {d}/{d}, overwritten={d}, rejected frozen={d}, exhausted={d}",
            .{
                snapshot.journal.count,
                snapshot.journal.capacity,
                snapshot.journal.overwritten,
                snapshot.journal.rejected_while_frozen,
                snapshot.journal.rejected_sequence_exhausted,
            },
        );
        zgui.text(
            "frozen={}, trigger_armed={}, sequence_exhausted={}",
            .{
                snapshot.journal.frozen,
                snapshot.journal.trigger_armed,
                snapshot.journal.sequence_exhausted,
            },
        );
        if (zgui.button("Freeze next entry", .{})) {
            diagnosticRequest(ctx, .{ .arm_freeze = .{} });
        }
        zgui.sameLine(.{});
        if (zgui.button("Freeze runtime fault", .{})) {
            diagnosticRequest(ctx, .{ .arm_freeze = .{
                .severity = .fatal,
                .category = .runtime,
                .code = engine.diagnostic_contracts.codes.runtime_system_fault,
            } });
        }
        if (zgui.button("Disarm", .{})) diagnosticRequest(ctx, .disarm_freeze);
        zgui.sameLine(.{});
        if (zgui.button("Resume", .{})) diagnosticRequest(ctx, .resume_capture);
        zgui.sameLine(.{});
        if (zgui.button("Clear", .{})) diagnosticRequest(ctx, .clear);
        zgui.sameLine(.{});
        if (zgui.button("Export JSON", .{})) diagnosticRequest(ctx, .export_json);
        for (0..ctx.journal.len()) |index| {
            const entry = ctx.journal.at(index).?;
            zgui.text(
                "#{d} [{s}/{s}] {s} (0x{x}) tick={?d} correlation={d}",
                .{
                    entry.sequence,
                    @tagName(entry.severity),
                    @tagName(entry.category),
                    diagnosticCodeLabel(entry.code),
                    entry.code,
                    entry.tick_index,
                    entry.correlation_id,
                },
            );
        }
    }
    zgui.end();
}
