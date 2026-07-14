//! Renderer-free same-cohort flight-recording contract for the sandbox host.
//!
//! This module owns only replay values, bounded recording, canonical hashing,
//! and the explicit little-endian envelope. It does not construct a world or
//! import SDL/editor/rendering hosts. A caller must fully parse and validate a
//! capture before using its values to create authoritative state.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("incinerator_engine");
const crates = @import("crate_feature");
const characters = @import("character_feature");
const vehicles = @import("vehicle_feature");
const districts = @import("district_feature");
const interactions = @import("interaction_feature");
const npcs = @import("npc_feature");
const district_contract = @import("district_contract");
const sandbox_recipe = @import("sandbox_district_recipe");
const simulation_cohort_options = @import("simulation_cohort_options");

const replay = engine.contracts.replay;

pub const Digest = replay.Digest;
pub const TickDigests = replay.TickDigests;
pub const DigestCategory = replay.Category;

pub const magic = [8]u8{ 'I', 'N', 'C', 'R', 'P', 'L', 'A', 'Y' };
pub const format_version: u16 = 1;
pub const schema_cohort: u16 = 5;
pub const header_size: usize = 64;
pub const integrity_size: usize = @sizeOf(Digest);
pub const max_envelope_bytes: usize = 8 * 1024 * 1024;

pub const max_bootstrap_commands: u32 = 256;
pub const max_recorded_commands: u32 = 32 * 1024;
pub const max_district_ingress: u32 = 4 * 1024;
pub const max_tick_digests: u32 = 32 * 1024;

/// Hard construction limits for replay-provided world capacities. These are
/// intentionally independent of envelope byte limits: hosts use the values to
/// size authoritative identity and digest scratch before replay begins.
pub const max_world_crates: u32 = 8 * 1024;
pub const max_world_characters: u32 = 4 * 1024;
pub const max_world_vehicles: u32 = 2 * 1024;
pub const max_world_districts: u8 = 2;
pub const max_world_interactions: u8 = 1;
pub const max_world_npcs: u32 = 64;
pub const max_world_identities: u32 = 16 * 1024;

comptime {
    if (max_world_npcs != npcs.max_npcs) {
        @compileError("replay and NPC feature capacity cohorts must match exactly");
    }
}

const Revision = [40]u8;

pub const TargetCohort = enum(u8) {
    macos_aarch64 = 1,
};

pub const OptimizeCohort = enum(u8) {
    debug = 1,
    release_safe = 2,
    release_fast = 3,
    release_small = 4,
};

pub const FlecsDebugCohort = enum(u8) {
    none = 1,
    sanitize = 2,
};

/// Every field that can silently change the current sandbox's logical
/// execution cohort is explicit. Dependency revisions are the immutable pins
/// in the current repository, not versions discovered from the host machine.
pub const SimulationCohort = struct {
    replay_schema: u16,
    engine_schedule_cohort: u16,
    snapshot_schema: u16,
    zig_major: u16,
    zig_minor: u16,
    zig_patch: u16,
    target: TargetCohort,
    optimize: OptimizeCohort,
    cpu_codegen_digest: Digest,

    zflecs_revision: Revision,
    flecs_debug: FlecsDebugCohort,
    flecs_float_bits: u8,
    flecs_time_bits: u8,
    flecs_use_os_alloc: bool,
    flecs_hi_component_id: u16,
    flecs_hi_id_record_id: u16,

    joltc_zig_revision: Revision,
    joltc_revision: Revision,
    jolt_revision: Revision,
    jolt_no_exceptions: bool,
    jolt_object_layer_bits: u8,
    jolt_cross_platform_deterministic: bool,
    jolt_worker_count: i32,
    jolt_max_jobs: u32,
    jolt_max_barriers: u32,

    pub fn validate(self: SimulationCohort) !void {
        if (self.replay_schema == 0 or
            self.engine_schedule_cohort == 0 or
            self.snapshot_schema == 0 or
            (self.zig_major == 0 and self.zig_minor == 0 and self.zig_patch == 0) or
            !hasNonzeroByte(&self.cpu_codegen_digest) or
            self.flecs_float_bits == 0 or
            self.flecs_time_bits == 0 or
            self.flecs_hi_component_id == 0 or
            self.flecs_hi_id_record_id == 0 or
            self.jolt_object_layer_bits == 0 or
            self.jolt_worker_count <= 0 or
            self.jolt_max_jobs == 0 or
            self.jolt_max_barriers == 0)
        {
            return error.InvalidSimulationCohort;
        }
        if (!hasNonzeroByte(&self.zflecs_revision) or
            !hasNonzeroByte(&self.joltc_zig_revision) or
            !hasNonzeroByte(&self.joltc_revision) or
            !hasNonzeroByte(&self.jolt_revision))
        {
            return error.InvalidSimulationCohort;
        }
    }

    pub fn fingerprint(self: SimulationCohort) !Digest {
        var sink = DigestSink.init();
        try encodeSimulationCohort(&sink, self);
        return sink.final();
    }
};

pub const current_simulation_cohort = SimulationCohort{
    .replay_schema = schema_cohort,
    // Cohort 5 adds navigation-driven NPC authority between interaction and
    // the single shared physics step.
    .engine_schedule_cohort = 5,
    .snapshot_schema = 7,
    .zig_major = @intCast(builtin.zig_version.major),
    .zig_minor = @intCast(builtin.zig_version.minor),
    .zig_patch = @intCast(builtin.zig_version.patch),
    .target = currentTargetCohort(),
    .optimize = currentOptimizeCohort(),
    .cpu_codegen_digest = currentCpuCodegenDigest(),
    .zflecs_revision = revisionFromSlice(simulation_cohort_options.zflecs_revision),
    .flecs_debug = if (builtin.mode == .Debug) .sanitize else .none,
    .flecs_float_bits = simulation_cohort_options.flecs_float_bits,
    .flecs_time_bits = simulation_cohort_options.flecs_time_bits,
    .flecs_use_os_alloc = simulation_cohort_options.flecs_use_os_alloc,
    .flecs_hi_component_id = simulation_cohort_options.flecs_hi_component_id,
    .flecs_hi_id_record_id = simulation_cohort_options.flecs_hi_id_record_id,
    .joltc_zig_revision = revisionFromSlice(simulation_cohort_options.joltc_zig_revision),
    .joltc_revision = revisionFromSlice(simulation_cohort_options.joltc_revision),
    .jolt_revision = revisionFromSlice(simulation_cohort_options.jolt_revision),
    .jolt_no_exceptions = simulation_cohort_options.jolt_no_exceptions,
    .jolt_object_layer_bits = simulation_cohort_options.jolt_object_layer_bits,
    .jolt_cross_platform_deterministic = simulation_cohort_options.jolt_cross_platform_deterministic,
    .jolt_worker_count = simulation_cohort_options.jolt_worker_count,
    .jolt_max_jobs = simulation_cohort_options.jolt_max_jobs,
    .jolt_max_barriers = simulation_cohort_options.jolt_max_barriers,
};

fn revisionFromSlice(comptime value: []const u8) Revision {
    if (value.len != @sizeOf(Revision)) {
        @compileError("simulation cohort revisions must be exact Git SHA-1 values");
    }
    return value[0..@sizeOf(Revision)].*;
}

fn currentTargetCohort() TargetCohort {
    if (builtin.target.os.tag == .macos and builtin.target.cpu.arch == .aarch64) {
        return .macos_aarch64;
    }
    @compileError("sandbox replay currently supports only Apple Silicon macOS");
}

fn currentOptimizeCohort() OptimizeCohort {
    return switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .release_safe,
        .ReleaseFast => .release_fast,
        .ReleaseSmall => .release_small,
    };
}

/// Hash the complete CPU code-generation selection without depending on the
/// in-memory layout of Zig's feature bit set. Feature definitions are visited
/// in stable enum-index order and each enabled entry carries both its index and
/// name. The Zig version is a separate cohort field, so a future compiler may
/// evolve that enumeration without aliasing a capture from this compiler.
fn cpuCodegenDigest(
    model_name: []const u8,
    features: std.Target.Cpu.Feature.Set,
) Digest {
    @setEvalBranchQuota(200_000);
    std.debug.assert(model_name.len > 0 and model_name.len <= std.math.maxInt(u16));

    var enabled_count: u16 = 0;
    for (std.Target.aarch64.all_features) |feature| {
        if (features.isEnabled(feature.index)) enabled_count += 1;
    }

    var writer = replay.Writer.init();
    writer.writeBytes("incinerator.cpu-codegen.v1");
    writer.writeU16(@intCast(model_name.len));
    writer.writeBytes(model_name);
    writer.writeU16(enabled_count);
    for (std.Target.aarch64.all_features) |feature| {
        if (!features.isEnabled(feature.index)) continue;
        writer.writeU16(feature.index);
        writer.writeU16(@intCast(feature.name.len));
        writer.writeBytes(feature.name);
    }
    return writer.final();
}

fn currentCpuCodegenDigest() Digest {
    return cpuCodegenDigest(
        builtin.target.cpu.model.name,
        builtin.target.cpu.features,
    );
}

pub const StaticBox = struct {
    position: [3]f32,
    half_extents: [3]f32,

    pub fn validate(self: StaticBox) !void {
        try (engine.physics.StaticBoxDesc{
            .pose = .{ .position = self.position },
            .half_extents = self.half_extents,
        }).validate();
    }
};

pub const default_ground = StaticBox{
    .position = .{ 0, -1, 0 },
    .half_extents = .{ 50, 1, 50 },
};

/// Exact renderer-free inputs used to construct a cold sandbox world.
/// Presentation assets are intentionally absent; the V1 feature configs retain
/// only authoritative tuning while the capacities remain host-owned values.
pub const WorldConfig = struct {
    namespace: u64,
    fixed_delta_seconds: f32,
    max_crates: u32,
    max_characters: u32,
    max_vehicles: u32,
    max_districts: u8 = max_world_districts,
    max_interactions: u8 = max_world_interactions,
    max_npcs: u32 = max_world_npcs,
    character: characters.CharacterConfigV1,
    vehicle: vehicles.VehicleConfigV1,
    interaction: interactions.InteractionConfigV1,
    npc: npcs.NpcConfigV1,
    ground: ?StaticBox = default_ground,
    block: ?StaticBox = null,

    pub fn fromFeatureConfigs(
        namespace: u64,
        fixed_delta_seconds: f32,
        max_crates_value: usize,
        character: characters.Config,
        vehicle: vehicles.Config,
        interaction: interactions.Config,
        npc: npcs.Config,
        create_ground: bool,
        block: ?StaticBox,
    ) !WorldConfig {
        const result = WorldConfig{
            .namespace = namespace,
            .fixed_delta_seconds = fixed_delta_seconds,
            .max_crates = std.math.cast(u32, max_crates_value) orelse
                return error.WorldCapacityOutOfRange,
            .max_characters = std.math.cast(u32, character.max_characters) orelse
                return error.WorldCapacityOutOfRange,
            .max_vehicles = std.math.cast(u32, vehicle.max_vehicles) orelse
                return error.WorldCapacityOutOfRange,
            .character = characters.CharacterConfigV1.fromConfig(character),
            .vehicle = vehicles.VehicleConfigV1.fromConfig(vehicle),
            .interaction = interactions.InteractionConfigV1.fromConfig(interaction),
            .npc = npcs.NpcConfigV1.fromConfig(npc),
            .ground = if (create_ground) default_ground else null,
            .block = block,
        };
        try result.validate();
        return result;
    }

    pub fn validate(self: WorldConfig) !void {
        if (self.namespace == 0) return error.InvalidIdentityNamespace;
        try replay.validateCanonicalF32(try replay.canonicalF32(self.fixed_delta_seconds));
        if (self.fixed_delta_seconds <= 0) return error.InvalidFixedDelta;
        if (self.max_crates == 0 or self.max_characters == 0 or
            self.max_vehicles == 0 or
            self.max_districts != max_world_districts or
            self.max_interactions != max_world_interactions or
            self.max_npcs != max_world_npcs)
        {
            return error.InvalidWorldCapacity;
        }
        if (self.max_crates > max_world_crates or
            self.max_characters > max_world_characters or
            self.max_vehicles > max_world_vehicles)
        {
            return error.WorldCapacityOutOfRange;
        }
        var identity_capacity: u64 = self.max_crates;
        identity_capacity = std.math.add(u64, identity_capacity, self.max_characters) catch
            return error.WorldCapacityOutOfRange;
        identity_capacity = std.math.add(u64, identity_capacity, self.max_vehicles) catch
            return error.WorldCapacityOutOfRange;
        identity_capacity = std.math.add(u64, identity_capacity, self.max_districts) catch
            return error.WorldCapacityOutOfRange;
        identity_capacity = std.math.add(u64, identity_capacity, self.max_interactions) catch
            return error.WorldCapacityOutOfRange;
        identity_capacity = std.math.add(u64, identity_capacity, self.max_npcs) catch
            return error.WorldCapacityOutOfRange;
        if (identity_capacity > max_world_identities) {
            return error.WorldIdentityCapacityExceeded;
        }
        try self.character.validate();
        try self.vehicle.validate();
        try self.interaction.validate();
        try self.npc.validate();
        const virtual_character_capacity = std.math.add(
            u64,
            self.max_characters,
            self.max_npcs,
        ) catch return error.VirtualCharacterCapacityExceeded;
        if (virtual_character_capacity > simulation_cohort_options.jolt_max_virtual_characters) {
            return error.VirtualCharacterCapacityExceeded;
        }
        if (self.ground) |ground| {
            try ground.validate();
            if (!std.meta.eql(ground, default_ground)) {
                return error.UnsupportedGroundConfiguration;
            }
        }
        if (self.block) |block| try block.validate();

        var required: u64 = self.max_crates;
        required = std.math.add(u64, required, self.max_vehicles) catch
            return error.PhysicsBodyBudgetExceeded;
        required = std.math.add(
            u64,
            required,
            district_contract.max_static_boxes * max_world_districts,
        ) catch
            return error.PhysicsBodyBudgetExceeded;
        required = std.math.add(u64, required, self.max_interactions) catch
            return error.PhysicsBodyBudgetExceeded;
        if (self.ground != null) required += 1;
        if (self.block != null) required += 1;
        if (required > simulation_cohort_options.jolt_max_bodies) {
            return error.PhysicsBodyBudgetExceeded;
        }
    }

    pub fn fingerprint(self: WorldConfig) !Digest {
        var sink = DigestSink.init();
        try encodeWorldConfig(&sink, self);
        return sink.final();
    }
};

pub const current_catalog_format_version: u16 = 1;
pub const current_catalog_schema_cohort: u16 = 1;

/// Identity of the admitted canonical district catalog. Replays deliberately
/// have no single-bundle compatibility mode: the catalog is the one current
/// content admission boundary for the greenfield engine.
pub const ContentCohort = struct {
    catalog_format_version: u16,
    catalog_schema_cohort: u16,
    district_recipe_version: u32,
    catalog_id_digest: Digest,
    source_digest: Digest,
    integrity_digest: Digest,
    /// The catalog id is represented by a framed digest so replay state stays
    /// fixed-size and does not retain allocator-owned strings.
    pub fn init(
        catalog_id: []const u8,
        catalog_format_version: u16,
        catalog_schema_cohort: u16,
        district_recipe_version: u32,
        source_digest: Digest,
        integrity_digest: Digest,
    ) !ContentCohort {
        if (catalog_id.len == 0 or catalog_id.len > std.math.maxInt(u16)) {
            return error.InvalidCatalogId;
        }
        var writer = replay.Writer.init();
        writer.writeBytes("incinerator.catalog-id.v1");
        writer.writeU16(@intCast(catalog_id.len));
        writer.writeBytes(catalog_id);
        const result = ContentCohort{
            .catalog_format_version = catalog_format_version,
            .catalog_schema_cohort = catalog_schema_cohort,
            .district_recipe_version = district_recipe_version,
            .catalog_id_digest = writer.final(),
            .source_digest = source_digest,
            .integrity_digest = integrity_digest,
        };
        try result.validate();
        return result;
    }

    pub fn validate(self: ContentCohort) !void {
        const valid = self.catalog_format_version != 0 and
            self.catalog_schema_cohort != 0 and
            self.district_recipe_version != 0 and
            hasNonzeroByte(&self.catalog_id_digest) and
            hasNonzeroByte(&self.source_digest) and
            hasNonzeroByte(&self.integrity_digest);
        if (!valid) return error.InvalidContentCohort;
    }

    pub fn recipeVersion(self: ContentCohort) u32 {
        return self.district_recipe_version;
    }

    pub fn fingerprint(self: ContentCohort) !Digest {
        var sink = DigestSink.init();
        try encodeContentCohort(&sink, self);
        return sink.final();
    }
};

pub const NormalizedDistrictRequestLoad = struct {
    request_id: u64,
    coord: district_contract.ChunkCoord,
};

pub const DistrictCommandTag = enum(u8) {
    request_load = 1,
    cancel_load = 2,
    unload = 3,
};

/// District presentation Assets are deliberately stripped at admission. A
/// replay host supplies inert presentation assets when rematerializing the
/// feature command; those handles never enter the authoritative envelope.
pub const NormalizedDistrictCommand = union(DistrictCommandTag) {
    request_load: NormalizedDistrictRequestLoad,
    cancel_load: districts.CancelLoad,
    unload: districts.Unload,

    pub fn fromFeature(command: districts.Command) NormalizedDistrictCommand {
        return switch (command) {
            .request_load => |request| .{ .request_load = .{
                .request_id = request.request_id,
                .coord = request.coord,
            } },
            .cancel_load => |cancel| .{ .cancel_load = cancel },
            .unload => |unload_request| .{ .unload = unload_request },
        };
    }

    pub fn toFeature(self: NormalizedDistrictCommand, assets: districts.Assets) districts.Command {
        return switch (self) {
            .request_load => |request| .{ .request_load = .{
                .request_id = request.request_id,
                .coord = request.coord,
                .assets = assets,
            } },
            .cancel_load => |cancel| .{ .cancel_load = cancel },
            .unload => |unload_request| .{ .unload = unload_request },
        };
    }
};

pub const CommandSource = enum(u8) {
    crate = 1,
    character = 2,
    vehicle = 3,
    district = 4,
    interaction = 5,
    npc = 6,
};

pub const NormalizedCommand = union(CommandSource) {
    crate: crates.Command,
    character: characters.Command,
    vehicle: vehicles.Command,
    district: NormalizedDistrictCommand,
    interaction: interactions.Command,
    npc: npcs.Command,

    pub fn fromCrate(command: crates.Command) NormalizedCommand {
        return .{ .crate = command };
    }

    pub fn fromCharacter(command: characters.Command) NormalizedCommand {
        return .{ .character = command };
    }

    pub fn fromVehicle(command: vehicles.Command) NormalizedCommand {
        return .{ .vehicle = command };
    }

    pub fn fromDistrict(command: districts.Command) NormalizedCommand {
        return .{ .district = NormalizedDistrictCommand.fromFeature(command) };
    }

    pub fn fromInteraction(command: interactions.Command) NormalizedCommand {
        return .{ .interaction = command };
    }

    pub fn fromNpc(command: npcs.Command) NormalizedCommand {
        return .{ .npc = command };
    }

    pub fn fingerprint(self: NormalizedCommand) !Digest {
        var sink = DigestSink.init();
        try encodeNormalizedCommand(&sink, self);
        return sink.final();
    }
};

pub const RecordedCommand = struct {
    eligible_tick: u64,
    command: NormalizedCommand,
};

pub const DistrictCompletionIngress = struct {
    consumption_tick: u64,
    completion: district_contract.Completion,
};

pub const IncompleteReason = enum(u8) {
    bootstrap_capacity = 1,
    command_capacity = 2,
    district_ingress_capacity = 3,
    tick_digest_capacity = 4,
    envelope_capacity = 5,
    allocation_failure = 6,
    invalid_record = 7,
    out_of_order_record = 8,
    output_policy_violated = 9,
    digest_failed = 10,
    loader_issue = 11,
    authority_failed = 12,
    commands_pending_at_finish = 13,
    unsupported_submission_phase = 14,
};

pub const RecordResult = enum {
    recorded,
    capture_incomplete,
};

pub const Limits = struct {
    max_file_bytes: usize = max_envelope_bytes,
    max_bootstrap: u32 = max_bootstrap_commands,
    max_commands: u32 = max_recorded_commands,
    max_ingress: u32 = max_district_ingress,
    max_digests: u32 = max_tick_digests,

    pub fn validate(self: Limits) !void {
        if (self.max_file_bytes < header_size + integrity_size or
            self.max_file_bytes > max_envelope_bytes or
            self.max_bootstrap > max_bootstrap_commands or
            self.max_commands > max_recorded_commands or
            self.max_ingress > max_district_ingress or
            self.max_digests > max_tick_digests)
        {
            return error.InvalidReplayLimits;
        }
    }
};

pub const CaptureView = struct {
    simulation_cohort: SimulationCohort,
    world: WorldConfig,
    content: ContentCohort,
    incomplete_reason: ?IncompleteReason = null,
    bootstrap_commands: []const RecordedCommand,
    commands: []const RecordedCommand,
    district_ingress: []const DistrictCompletionIngress,
    tick_digests: []const TickDigests,

    pub fn validate(self: CaptureView, limits: Limits) !void {
        try validateCapture(self, limits);
    }

    pub fn validateCompatible(self: CaptureView, expected_content: ContentCohort) !void {
        if (!std.meta.eql(self.simulation_cohort, current_simulation_cohort)) {
            return error.IncompatibleSimulationCohort;
        }
        if (!std.meta.eql(self.content, expected_content)) {
            return error.IncompatibleContentCohort;
        }
        if (self.incomplete_reason != null) return error.IncompleteCapture;
    }
};

pub const ParsedCapture = struct {
    allocator: std.mem.Allocator,
    simulation_cohort: SimulationCohort,
    world: WorldConfig,
    content: ContentCohort,
    incomplete_reason: ?IncompleteReason,
    bootstrap_commands: []RecordedCommand,
    commands: []RecordedCommand,
    district_ingress: []DistrictCompletionIngress,
    tick_digests: []TickDigests,

    pub fn view(self: *const ParsedCapture) CaptureView {
        return .{
            .simulation_cohort = self.simulation_cohort,
            .world = self.world,
            .content = self.content,
            .incomplete_reason = self.incomplete_reason,
            .bootstrap_commands = self.bootstrap_commands,
            .commands = self.commands,
            .district_ingress = self.district_ingress,
            .tick_digests = self.tick_digests,
        };
    }

    pub fn validateCompatible(self: *const ParsedCapture, expected_content: ContentCohort) !void {
        try self.view().validateCompatible(expected_content);
    }

    pub fn deinit(self: *ParsedCapture) void {
        self.allocator.free(self.tick_digests);
        self.allocator.free(self.district_ingress);
        self.allocator.free(self.commands);
        self.allocator.free(self.bootstrap_commands);
        self.* = undefined;
    }
};

/// Bounded owner-thread recorder. Saturation and explicitly reported live-run
/// failures retain the first incomplete reason and turn all later record calls
/// into no-ops; they never become a reason to reject an authoritative command
/// or tick that the simulation itself accepted.
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    simulation_cohort: SimulationCohort,
    world: WorldConfig,
    content: ContentCohort,
    bootstrap_commands: std.ArrayListUnmanaged(RecordedCommand) = .empty,
    commands: std.ArrayListUnmanaged(RecordedCommand) = .empty,
    district_ingress: std.ArrayListUnmanaged(DistrictCompletionIngress) = .empty,
    tick_digests: std.ArrayListUnmanaged(TickDigests) = .empty,
    incomplete_reason: ?IncompleteReason = null,
    base_encoded_bytes: usize,
    recorded_payload_bytes: usize = 0,
    bootstrap_closed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        world: WorldConfig,
        content: ContentCohort,
        limits: Limits,
    ) !Recorder {
        return initWithCohort(
            allocator,
            current_simulation_cohort,
            world,
            content,
            limits,
        );
    }

    pub fn initWithCohort(
        allocator: std.mem.Allocator,
        simulation_cohort: SimulationCohort,
        world: WorldConfig,
        content: ContentCohort,
        limits: Limits,
    ) !Recorder {
        try limits.validate();
        try simulation_cohort.validate();
        try world.validate();
        try content.validate();
        const fixed_payload = try encodedFixedPayloadSize(
            simulation_cohort,
            world,
            content,
        );
        const base_encoded_bytes = std.math.add(
            usize,
            header_size + integrity_size,
            fixed_payload,
        ) catch return error.ReplayEnvelopeTooLarge;
        if (base_encoded_bytes > limits.max_file_bytes) {
            return error.ReplayEnvelopeTooLarge;
        }
        var recorder = Recorder{
            .allocator = allocator,
            .limits = limits,
            .simulation_cohort = simulation_cohort,
            .world = world,
            .content = content,
            .base_encoded_bytes = base_encoded_bytes,
        };
        errdefer recorder.deinit();

        // Recording runs inside authoritative tick processing. Move every
        // possible list allocation into cold admission so a successful init
        // guarantees that appending up to each configured bound is infallible.
        const bootstrap_capacity = std.math.cast(usize, limits.max_bootstrap) orelse
            return error.ReplayCapacityOutOfRange;
        const command_capacity = std.math.cast(usize, limits.max_commands) orelse
            return error.ReplayCapacityOutOfRange;
        const ingress_capacity = std.math.cast(usize, limits.max_ingress) orelse
            return error.ReplayCapacityOutOfRange;
        const digest_capacity = std.math.cast(usize, limits.max_digests) orelse
            return error.ReplayCapacityOutOfRange;
        try recorder.bootstrap_commands.ensureTotalCapacityPrecise(
            allocator,
            bootstrap_capacity,
        );
        try recorder.commands.ensureTotalCapacityPrecise(allocator, command_capacity);
        try recorder.district_ingress.ensureTotalCapacityPrecise(allocator, ingress_capacity);
        try recorder.tick_digests.ensureTotalCapacityPrecise(allocator, digest_capacity);
        return recorder;
    }

    pub fn deinit(self: *Recorder) void {
        self.tick_digests.deinit(self.allocator);
        self.district_ingress.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.bootstrap_commands.deinit(self.allocator);
        self.* = undefined;
    }

    /// Mark a live capture unusable without changing simulation control flow.
    /// The first reason is immutable so the original loss of replay fidelity
    /// is not hidden by later shutdown fallout.
    pub fn markIncomplete(self: *Recorder, reason: IncompleteReason) void {
        if (self.incomplete_reason == null) self.incomplete_reason = reason;
    }

    pub fn incompleteReason(self: *const Recorder) ?IncompleteReason {
        return self.incomplete_reason;
    }

    pub fn recordBootstrap(
        self: *Recorder,
        command: NormalizedCommand,
    ) RecordResult {
        if (self.incomplete_reason != null) return .capture_incomplete;
        if (self.bootstrap_closed) {
            self.markIncomplete(.out_of_order_record);
            return .capture_incomplete;
        }
        if (self.bootstrap_commands.items.len >= self.limits.max_bootstrap) {
            self.markIncomplete(.bootstrap_capacity);
            return .capture_incomplete;
        }
        const record = RecordedCommand{ .eligible_tick = 1, .command = command };
        validateRecordedCommand(record) catch {
            self.markIncomplete(.invalid_record);
            return .capture_incomplete;
        };
        const encoded_size = encodedRecordedCommandSize(record) catch {
            self.markIncomplete(.invalid_record);
            return .capture_incomplete;
        };
        if (!self.reserveRecordBytes(encoded_size)) return .capture_incomplete;
        self.bootstrap_commands.appendAssumeCapacity(record);
        return .recorded;
    }

    pub fn recordCommand(
        self: *Recorder,
        eligible_tick: u64,
        command: NormalizedCommand,
    ) RecordResult {
        if (self.incomplete_reason != null) return .capture_incomplete;
        self.bootstrap_closed = true;
        if (self.commands.items.len >= self.limits.max_commands) {
            self.markIncomplete(.command_capacity);
            return .capture_incomplete;
        }
        const record = RecordedCommand{ .eligible_tick = eligible_tick, .command = command };
        validateRecordedCommand(record) catch {
            self.markIncomplete(.invalid_record);
            return .capture_incomplete;
        };
        if (eligible_tick == 1) {
            self.markIncomplete(.invalid_record);
            return .capture_incomplete;
        }
        if (self.commands.items.len > 0 and
            eligible_tick < self.commands.items[self.commands.items.len - 1].eligible_tick)
        {
            self.markIncomplete(.out_of_order_record);
            return .capture_incomplete;
        }
        const encoded_size = encodedRecordedCommandSize(record) catch {
            self.markIncomplete(.invalid_record);
            return .capture_incomplete;
        };
        if (!self.reserveRecordBytes(encoded_size)) return .capture_incomplete;
        self.commands.appendAssumeCapacity(record);
        return .recorded;
    }

    pub fn recordDistrictCompletion(
        self: *Recorder,
        consumption_tick: u64,
        completion: district_contract.Completion,
    ) RecordResult {
        if (self.incomplete_reason != null) return .capture_incomplete;
        self.bootstrap_closed = true;
        if (self.district_ingress.items.len >= self.limits.max_ingress) {
            self.markIncomplete(.district_ingress_capacity);
            return .capture_incomplete;
        }
        const ingress = DistrictCompletionIngress{
            .consumption_tick = consumption_tick,
            .completion = completion,
        };
        validateDistrictIngress(ingress) catch {
            self.markIncomplete(.invalid_record);
            return .capture_incomplete;
        };
        if (self.district_ingress.items.len > 0 and
            consumption_tick <= self.district_ingress.items[self.district_ingress.items.len - 1].consumption_tick)
        {
            self.markIncomplete(.out_of_order_record);
            return .capture_incomplete;
        }
        const encoded_size = encodedDistrictIngressSize(ingress) catch {
            self.markIncomplete(.invalid_record);
            return .capture_incomplete;
        };
        if (!self.reserveRecordBytes(encoded_size)) return .capture_incomplete;
        self.district_ingress.appendAssumeCapacity(ingress);
        return .recorded;
    }

    pub fn recordTickDigests(self: *Recorder, digests: TickDigests) RecordResult {
        if (self.incomplete_reason != null) return .capture_incomplete;
        self.bootstrap_closed = true;
        if (self.tick_digests.items.len >= self.limits.max_digests) {
            self.markIncomplete(.tick_digest_capacity);
            return .capture_incomplete;
        }
        const expected_tick: u64 = if (self.tick_digests.items.len == 0)
            1
        else
            self.tick_digests.items[self.tick_digests.items.len - 1].tick_index +| 1;
        if (digests.tick_index != expected_tick) {
            self.markIncomplete(.out_of_order_record);
            return .capture_incomplete;
        }
        const encoded_size = encodedTickDigestsSize();
        if (!self.reserveRecordBytes(encoded_size)) return .capture_incomplete;
        self.tick_digests.appendAssumeCapacity(digests);
        return .recorded;
    }

    pub fn view(self: *const Recorder) CaptureView {
        return .{
            .simulation_cohort = self.simulation_cohort,
            .world = self.world,
            .content = self.content,
            .incomplete_reason = self.incomplete_reason,
            .bootstrap_commands = self.bootstrap_commands.items,
            .commands = self.commands.items,
            .district_ingress = self.district_ingress.items,
            .tick_digests = self.tick_digests.items,
        };
    }

    pub fn encode(self: *const Recorder, allocator: std.mem.Allocator) ![]u8 {
        return encodeWithLimits(allocator, self.view(), self.limits);
    }

    fn reserveRecordBytes(self: *Recorder, encoded_size: usize) bool {
        const payload = std.math.add(
            usize,
            self.recorded_payload_bytes,
            encoded_size,
        ) catch {
            self.markIncomplete(.envelope_capacity);
            return false;
        };
        const total = std.math.add(usize, self.base_encoded_bytes, payload) catch {
            self.markIncomplete(.envelope_capacity);
            return false;
        };
        if (total > self.limits.max_file_bytes) {
            self.markIncomplete(.envelope_capacity);
            return false;
        }
        self.recorded_payload_bytes = payload;
        return true;
    }
};

pub const TickBatch = struct {
    tick_index: u64,
    commands: []const RecordedCommand,
    district_ingress: []const DistrictCompletionIngress,
    expected_digests: TickDigests,
};

/// Cursor over the digest spine of a fully recorded capture. Commands are
/// returned before district ingress for each tick so the replay host can
/// preserve the feature's defined same-tick consumption order.
pub const ReplayCursor = struct {
    capture: CaptureView,
    command_index: usize = 0,
    ingress_index: usize = 0,
    digest_index: usize = 0,

    pub fn init(capture: CaptureView) !ReplayCursor {
        try capture.validate(.{});
        if (capture.incomplete_reason != null) return error.IncompleteCapture;
        return .{ .capture = capture };
    }

    pub fn bootstrap(self: *const ReplayCursor) []const RecordedCommand {
        return self.capture.bootstrap_commands;
    }

    pub fn next(self: *ReplayCursor) ?TickBatch {
        if (self.digest_index >= self.capture.tick_digests.len) return null;
        const expected = self.capture.tick_digests[self.digest_index];

        const command_start = self.command_index;
        while (self.command_index < self.capture.commands.len and
            self.capture.commands[self.command_index].eligible_tick == expected.tick_index)
        {
            self.command_index += 1;
        }
        const ingress_start = self.ingress_index;
        while (self.ingress_index < self.capture.district_ingress.len and
            self.capture.district_ingress[self.ingress_index].consumption_tick == expected.tick_index)
        {
            self.ingress_index += 1;
        }
        self.digest_index += 1;
        return .{
            .tick_index = expected.tick_index,
            .commands = self.capture.commands[command_start..self.command_index],
            .district_ingress = self.capture.district_ingress[ingress_start..self.ingress_index],
            .expected_digests = expected,
        };
    }
};

pub const DivergenceKind = enum {
    tick_index,
    category_digest,
};

pub const Divergence = struct {
    kind: DivergenceKind,
    tick_index: u64,
    category: ?DigestCategory,
    expected: ?Digest,
    actual: ?Digest,
};

pub fn firstDivergence(expected: TickDigests, actual: TickDigests) ?Divergence {
    if (expected.tick_index != actual.tick_index) {
        return .{
            .kind = .tick_index,
            .tick_index = @min(expected.tick_index, actual.tick_index),
            .category = null,
            .expected = null,
            .actual = null,
        };
    }
    inline for ([_]DigestCategory{
        .runtime,
        .crate,
        .character,
        .vehicle,
        .district,
        .interaction,
        .npc,
    }) |category| {
        const expected_digest = expected.get(category);
        const actual_digest = actual.get(category);
        if (!std.mem.eql(u8, &expected_digest, &actual_digest)) {
            return .{
                .kind = .category_digest,
                .tick_index = expected.tick_index,
                .category = category,
                .expected = expected_digest,
                .actual = actual_digest,
            };
        }
    }
    return null;
}

const SizeSink = struct {
    size: usize = 0,

    fn writeBytes(self: *SizeSink, bytes: []const u8) !void {
        self.size = std.math.add(usize, self.size, bytes.len) catch
            return error.ReplayEnvelopeTooLarge;
    }
    fn writeU8(self: *SizeSink, _: u8) !void {
        try self.writeBytes(&.{0});
    }
    fn writeU16(self: *SizeSink, _: u16) !void {
        try self.writeBytes(&([_]u8{0} ** 2));
    }
    fn writeU32(self: *SizeSink, _: u32) !void {
        try self.writeBytes(&([_]u8{0} ** 4));
    }
    fn writeU64(self: *SizeSink, _: u64) !void {
        try self.writeBytes(&([_]u8{0} ** 8));
    }
    fn writeI32(self: *SizeSink, _: i32) !void {
        try self.writeBytes(&([_]u8{0} ** 4));
    }
    fn writeF32(self: *SizeSink, value: f32) !void {
        _ = try replay.canonicalF32(value);
        try self.writeBytes(&([_]u8{0} ** 4));
    }
    fn writeBool(self: *SizeSink, _: bool) !void {
        try self.writeU8(0);
    }
};

const ByteSink = struct {
    bytes: []u8,
    cursor: usize = 0,

    fn writeBytes(self: *ByteSink, bytes: []const u8) !void {
        const end = std.math.add(usize, self.cursor, bytes.len) catch
            return error.ReplayEnvelopeTooLarge;
        if (end > self.bytes.len) return error.ReplayEncoderOverflow;
        @memcpy(self.bytes[self.cursor..end], bytes);
        self.cursor = end;
    }
    fn writeU8(self: *ByteSink, value: u8) !void {
        try self.writeBytes(&.{value});
    }
    fn writeU16(self: *ByteSink, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }
    fn writeU32(self: *ByteSink, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }
    fn writeU64(self: *ByteSink, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }
    fn writeI32(self: *ByteSink, value: i32) !void {
        try self.writeU32(@bitCast(value));
    }
    fn writeF32(self: *ByteSink, value: f32) !void {
        const canonical = try replay.canonicalF32(value);
        try self.writeU32(@bitCast(canonical));
    }
    fn writeBool(self: *ByteSink, value: bool) !void {
        try self.writeU8(if (value) 1 else 0);
    }
};

const DigestSink = struct {
    writer: replay.Writer,

    fn init() DigestSink {
        return .{ .writer = replay.Writer.init() };
    }
    fn writeBytes(self: *DigestSink, bytes: []const u8) !void {
        self.writer.writeBytes(bytes);
    }
    fn writeU8(self: *DigestSink, value: u8) !void {
        self.writer.writeU8(value);
    }
    fn writeU16(self: *DigestSink, value: u16) !void {
        self.writer.writeU16(value);
    }
    fn writeU32(self: *DigestSink, value: u32) !void {
        self.writer.writeU32(value);
    }
    fn writeU64(self: *DigestSink, value: u64) !void {
        self.writer.writeU64(value);
    }
    fn writeI32(self: *DigestSink, value: i32) !void {
        self.writer.writeI32(value);
    }
    fn writeF32(self: *DigestSink, value: f32) !void {
        try self.writer.writeF32(value);
    }
    fn writeBool(self: *DigestSink, value: bool) !void {
        self.writer.writeBool(value);
    }
    fn final(self: *DigestSink) Digest {
        return self.writer.final();
    }
};

fn encodeSimulationCohort(sink: anytype, value: SimulationCohort) !void {
    try sink.writeBytes("simulation-cohort-v1");
    try sink.writeU16(value.replay_schema);
    try sink.writeU16(value.engine_schedule_cohort);
    try sink.writeU16(value.snapshot_schema);
    try sink.writeU16(value.zig_major);
    try sink.writeU16(value.zig_minor);
    try sink.writeU16(value.zig_patch);
    try sink.writeU8(@intFromEnum(value.target));
    try sink.writeU8(@intFromEnum(value.optimize));
    try sink.writeBytes(&value.cpu_codegen_digest);
    try sink.writeBytes(&value.zflecs_revision);
    try sink.writeU8(@intFromEnum(value.flecs_debug));
    try sink.writeU8(value.flecs_float_bits);
    try sink.writeU8(value.flecs_time_bits);
    try sink.writeBool(value.flecs_use_os_alloc);
    try sink.writeU16(value.flecs_hi_component_id);
    try sink.writeU16(value.flecs_hi_id_record_id);
    try sink.writeBytes(&value.joltc_zig_revision);
    try sink.writeBytes(&value.joltc_revision);
    try sink.writeBytes(&value.jolt_revision);
    try sink.writeBool(value.jolt_no_exceptions);
    try sink.writeU8(value.jolt_object_layer_bits);
    try sink.writeBool(value.jolt_cross_platform_deterministic);
    try sink.writeI32(value.jolt_worker_count);
    try sink.writeU32(value.jolt_max_jobs);
    try sink.writeU32(value.jolt_max_barriers);
}

fn encodeWorldConfig(sink: anytype, value: WorldConfig) !void {
    try sink.writeBytes("world-config-v3");
    try sink.writeU64(value.namespace);
    try sink.writeF32(value.fixed_delta_seconds);
    try sink.writeU32(value.max_crates);
    try sink.writeU32(value.max_characters);
    try sink.writeU32(value.max_vehicles);
    try sink.writeU8(value.max_districts);
    try sink.writeU8(value.max_interactions);
    try sink.writeU32(value.max_npcs);
    try encodeCharacterConfig(sink, value.character);
    try encodeVehicleConfig(sink, value.vehicle);
    try encodeInteractionConfig(sink, value.interaction);
    try encodeNpcConfig(sink, value.npc);
    try encodeOptionalStaticBox(sink, value.ground);
    try encodeOptionalStaticBox(sink, value.block);
}

fn encodeNpcConfig(sink: anytype, value: npcs.NpcConfigV1) !void {
    try sink.writeF32(value.radius);
    try sink.writeF32(value.half_height);
    try sink.writeF32(value.move_speed);
    try sink.writeF32(value.gravity);
    try sink.writeF32(value.terminal_fall_speed);
    try sink.writeF32(value.max_slope_radians);
    try sink.writeF32(value.mass);
    try sink.writeF32(value.max_strength);
    try sink.writeF32(value.stick_to_floor_distance);
    try sink.writeF32(value.step_up_height);
    try sink.writeF32(value.arrival_distance);
}

fn encodeInteractionConfig(
    sink: anytype,
    value: interactions.InteractionConfigV1,
) !void {
    try sink.writeF32(value.collect_range);
    try encodeF32Array(sink, &value.drop_offset);
}

fn encodeCharacterConfig(sink: anytype, value: characters.CharacterConfigV1) !void {
    try sink.writeF32(value.radius);
    try sink.writeF32(value.half_height);
    try sink.writeF32(value.move_speed);
    try sink.writeF32(value.jump_speed);
    try sink.writeF32(value.gravity);
    try sink.writeF32(value.terminal_fall_speed);
    try sink.writeF32(value.max_slope_radians);
    try sink.writeF32(value.mass);
    try sink.writeF32(value.max_strength);
    try sink.writeF32(value.stick_to_floor_distance);
    try sink.writeF32(value.step_up_height);
}

fn encodeVehicleConfig(sink: anytype, value: vehicles.VehicleConfigV1) !void {
    const tuning = value.tuning;
    try encodeF32Array(sink, &tuning.chassis_half_extents);
    try encodeF32Array(sink, &tuning.center_of_mass_offset);
    try sink.writeF32(tuning.mass);
    for (tuning.wheel_attachment_positions) |position| try encodeF32Array(sink, &position);
    try sink.writeF32(tuning.wheel_radius);
    try sink.writeF32(tuning.wheel_width);
    try sink.writeF32(tuning.suspension_min_length);
    try sink.writeF32(tuning.suspension_max_length);
    try sink.writeF32(tuning.suspension_frequency);
    try sink.writeF32(tuning.suspension_damping);
    try sink.writeF32(tuning.max_steer_radians);
    try sink.writeF32(tuning.max_brake_torque);
    try sink.writeF32(tuning.max_hand_brake_torque);
    try sink.writeF32(tuning.front_differential_ratio);
    try sink.writeF32(tuning.front_limited_slip_ratio);
    try sink.writeF32(tuning.max_pitch_roll_radians);
    try sink.writeF32(tuning.wheel_collision_max_slope_radians);
    try sink.writeF32(value.max_entry_distance);
    try encodeF32Array(sink, &value.exit_offset);
}

fn encodeContentCohort(sink: anytype, value: ContentCohort) !void {
    try sink.writeBytes("catalog-cohort-v1");
    try sink.writeU16(value.catalog_format_version);
    try sink.writeU16(value.catalog_schema_cohort);
    try sink.writeU32(value.district_recipe_version);
    try sink.writeBytes(&value.catalog_id_digest);
    try sink.writeBytes(&value.source_digest);
    try sink.writeBytes(&value.integrity_digest);
}

const CrateCommandTag = enum(u8) { spawn = 1, despawn = 2, impulse = 3, relocate = 4 };
const CrateRelocationVelocityTag = enum(u8) { preserve = 1, zero = 2, exact = 3 };
const CharacterCommandTag = enum(u8) { spawn = 1, actions = 2, despawn = 3 };
const VehicleCommandTag = enum(u8) {
    spawn = 1,
    enter = 2,
    drive = 3,
    exit = 4,
    despawn = 5,
    abandon = 6,
};
const InteractionCommandTag = enum(u8) { spawn = 1, despawn = 2, collect = 3, drop = 4 };
const NpcCommandTag = enum(u8) { spawn = 1, set_goal = 2, despawn = 3 };
const NpcGoalTag = enum(u8) { hold = 1, navigate_to = 2, patrol_between = 3 };

fn encodeNormalizedCommand(sink: anytype, command: NormalizedCommand) !void {
    try sink.writeU8(@intFromEnum(std.meta.activeTag(command)));
    switch (command) {
        .crate => |value| try encodeCrateCommand(sink, value),
        .character => |value| try encodeCharacterCommand(sink, value),
        .vehicle => |value| try encodeVehicleCommand(sink, value),
        .district => |value| try encodeDistrictCommand(sink, value),
        .interaction => |value| try encodeInteractionCommand(sink, value),
        .npc => |value| try encodeNpcCommand(sink, value),
    }
}

fn encodeNpcCommand(sink: anytype, command: npcs.Command) !void {
    switch (command) {
        .spawn => |spawn| {
            try sink.writeU8(@intFromEnum(NpcCommandTag.spawn));
            try sink.writeU64(spawn.request_id);
            try encodeNavigationNodeRef(sink, spawn.node);
            try encodeNpcGoal(sink, spawn.goal);
        },
        .set_goal => |set_goal| {
            try sink.writeU8(@intFromEnum(NpcCommandTag.set_goal));
            try sink.writeU64(set_goal.request_id);
            try encodePersistentId(sink, set_goal.id);
            try encodeNpcGoal(sink, set_goal.goal);
        },
        .despawn => |despawn| {
            try sink.writeU8(@intFromEnum(NpcCommandTag.despawn));
            try sink.writeU64(despawn.request_id);
            try encodePersistentId(sink, despawn.id);
        },
    }
}

fn encodeNpcGoal(sink: anytype, goal: npcs.Goal) !void {
    switch (goal) {
        .hold => try sink.writeU8(@intFromEnum(NpcGoalTag.hold)),
        .navigate_to => |target| {
            try sink.writeU8(@intFromEnum(NpcGoalTag.navigate_to));
            try encodeNavigationNodeRef(sink, target);
        },
        .patrol_between => |patrol| {
            try sink.writeU8(@intFromEnum(NpcGoalTag.patrol_between));
            try encodeNavigationNodeRef(sink, patrol.first);
            try encodeNavigationNodeRef(sink, patrol.second);
        },
    }
}

fn encodeInteractionCommand(sink: anytype, command: interactions.Command) !void {
    switch (command) {
        .spawn => |spawn| {
            try sink.writeU8(@intFromEnum(InteractionCommandTag.spawn));
            try sink.writeU64(spawn.request_id);
            try encodePose(sink, spawn.pose);
            try encodeF32Array(sink, &spawn.velocity.linear);
            try encodeF32Array(sink, &spawn.velocity.angular);
            try encodeF32Array(sink, &spawn.half_extents);
        },
        .despawn => |despawn| {
            try sink.writeU8(@intFromEnum(InteractionCommandTag.despawn));
            try encodePersistentId(sink, despawn.id);
        },
        .collect => |collect| {
            try sink.writeU8(@intFromEnum(InteractionCommandTag.collect));
            try sink.writeU64(collect.transaction_id);
            try encodePersistentId(sink, collect.carrier_id);
            try encodePersistentId(sink, collect.carryable_id);
        },
        .drop => |drop| {
            try sink.writeU8(@intFromEnum(InteractionCommandTag.drop));
            try sink.writeU64(drop.transaction_id);
            try encodePersistentId(sink, drop.carrier_id);
            try encodePersistentId(sink, drop.carryable_id);
        },
    }
}

fn encodeCrateCommand(sink: anytype, command: crates.Command) !void {
    switch (command) {
        .spawn => |spawn| {
            try sink.writeU8(@intFromEnum(CrateCommandTag.spawn));
            try sink.writeU64(spawn.request_id);
            try encodePose(sink, spawn.pose);
            try encodeF32Array(sink, &spawn.velocity.linear);
            try encodeF32Array(sink, &spawn.velocity.angular);
            try encodeF32Array(sink, &spawn.half_extents);
        },
        .despawn => |despawn| {
            try sink.writeU8(@intFromEnum(CrateCommandTag.despawn));
            try encodePersistentId(sink, despawn.id);
        },
        .impulse => |impulse| {
            try sink.writeU8(@intFromEnum(CrateCommandTag.impulse));
            try encodePersistentId(sink, impulse.id);
            try encodeF32Array(sink, &impulse.impulse);
        },
        .relocate => |relocation| {
            try sink.writeU8(@intFromEnum(CrateCommandTag.relocate));
            try sink.writeU64(relocation.transaction_id);
            try encodePersistentId(sink, relocation.id);
            try encodePose(sink, relocation.target_pose);
            switch (relocation.velocity) {
                .preserve => try sink.writeU8(@intFromEnum(CrateRelocationVelocityTag.preserve)),
                .zero => try sink.writeU8(@intFromEnum(CrateRelocationVelocityTag.zero)),
                .exact => |velocity| {
                    try sink.writeU8(@intFromEnum(CrateRelocationVelocityTag.exact));
                    try encodeF32Array(sink, &velocity.linear);
                    try encodeF32Array(sink, &velocity.angular);
                },
            }
            try sink.writeBool(relocation.expected_revision != null);
            if (relocation.expected_revision) |revision| try sink.writeU64(revision);
        },
    }
}

fn encodeCharacterCommand(sink: anytype, command: characters.Command) !void {
    switch (command) {
        .spawn => |spawn| {
            try sink.writeU8(@intFromEnum(CharacterCommandTag.spawn));
            try sink.writeU64(spawn.request_id);
            try encodeF32Array(sink, &spawn.position);
            try encodeF32Array(sink, &spawn.velocity);
            try sink.writeF32(spawn.facing_yaw);
        },
        .actions => |actions| {
            try sink.writeU8(@intFromEnum(CharacterCommandTag.actions));
            try encodePersistentId(sink, actions.id);
            try encodeF32Array(sink, &actions.move);
            try sink.writeF32(actions.facing_yaw);
            try sink.writeBool(actions.jump_pressed);
        },
        .despawn => |despawn| {
            try sink.writeU8(@intFromEnum(CharacterCommandTag.despawn));
            try encodePersistentId(sink, despawn.id);
        },
    }
}

fn encodeVehicleCommand(sink: anytype, command: vehicles.Command) !void {
    switch (command) {
        .spawn => |spawn| {
            try sink.writeU8(@intFromEnum(VehicleCommandTag.spawn));
            try sink.writeU64(spawn.request_id);
            try encodeBodyState(sink, spawn.chassis);
        },
        .enter => |enter| {
            try sink.writeU8(@intFromEnum(VehicleCommandTag.enter));
            try encodePersistentId(sink, enter.vehicle_id);
            try encodePersistentId(sink, enter.driver_id);
        },
        .drive => |drive| {
            try sink.writeU8(@intFromEnum(VehicleCommandTag.drive));
            try encodePersistentId(sink, drive.vehicle_id);
            try encodePersistentId(sink, drive.driver_id);
            try sink.writeF32(drive.input.throttle);
            try sink.writeF32(drive.input.steering);
            try sink.writeF32(drive.input.brake);
            try sink.writeF32(drive.input.hand_brake);
        },
        .exit => |exit_command| {
            try sink.writeU8(@intFromEnum(VehicleCommandTag.exit));
            try encodePersistentId(sink, exit_command.vehicle_id);
            try encodePersistentId(sink, exit_command.driver_id);
        },
        .abandon => |abandon| {
            try sink.writeU8(@intFromEnum(VehicleCommandTag.abandon));
            try encodePersistentId(sink, abandon.vehicle_id);
            try encodePersistentId(sink, abandon.driver_id);
        },
        .despawn => |despawn| {
            try sink.writeU8(@intFromEnum(VehicleCommandTag.despawn));
            try encodePersistentId(sink, despawn.id);
        },
    }
}

fn encodeDistrictCommand(sink: anytype, command: NormalizedDistrictCommand) !void {
    try sink.writeU8(@intFromEnum(std.meta.activeTag(command)));
    switch (command) {
        .request_load => |request| {
            try sink.writeU64(request.request_id);
            try encodeChunkCoord(sink, request.coord);
        },
        .cancel_load => |cancel| {
            try sink.writeU64(cancel.request_id);
            try encodeLoadTicket(sink, cancel.ticket);
        },
        .unload => |unload_request| {
            try sink.writeU64(unload_request.request_id);
            try encodeLoadTicket(sink, unload_request.ticket);
        },
    }
}

fn encodeRecordedCommand(sink: anytype, record: RecordedCommand) !void {
    try sink.writeU64(record.eligible_tick);
    try encodeNormalizedCommand(sink, record.command);
}

const CompletionTag = enum(u8) { ready = 1, cancelled = 2, failed = 3 };
const FailureTag = enum(u8) { unsupported_recipe_version = 1, invalid_build = 2 };

fn encodeDistrictIngress(sink: anytype, ingress: DistrictCompletionIngress) !void {
    try sink.writeU64(ingress.consumption_tick);
    switch (ingress.completion) {
        .ready => |ready| {
            try sink.writeU8(@intFromEnum(CompletionTag.ready));
            try encodeLoadTicket(sink, ready.ticket);
            try encodeDistrictBuild(sink, ready.build);
        },
        .cancelled => |ticket| {
            try sink.writeU8(@intFromEnum(CompletionTag.cancelled));
            try encodeLoadTicket(sink, ticket);
        },
        .failed => |failed| {
            try sink.writeU8(@intFromEnum(CompletionTag.failed));
            try encodeLoadTicket(sink, failed.ticket);
            switch (failed.failure) {
                .unsupported_recipe_version => |version| {
                    try sink.writeU8(@intFromEnum(FailureTag.unsupported_recipe_version));
                    try sink.writeU32(version);
                },
                .invalid_build => |failure| {
                    try sink.writeU8(@intFromEnum(FailureTag.invalid_build));
                    try sink.writeU8(encodeBuildValidationFailure(failure));
                },
            }
        },
    }
}

fn encodeDistrictBuild(sink: anytype, build: district_contract.DistrictBuild) !void {
    try encodeChunkCoord(sink, build.coord);
    try sink.writeU32(build.recipe_version);
    try sink.writeU64(build.checksum);
    try sink.writeU32(build.decoded_bytes);
    try sink.writeU8(build.static_box_count);
    try sink.writeU8(build.navigation_node_count);
    try sink.writeU8(build.navigation_edge_count);
    for (build.boxes()) |box| {
        try encodePose(sink, box.pose);
        try encodeF32Array(sink, &box.half_extents);
    }
    for (build.navigationNodes()) |node| {
        try encodeF32Array(sink, &node.position);
        try sink.writeU8(node.first_edge);
        try sink.writeU8(node.edge_count);
        try sink.writeU8(node.flags);
        try sink.writeU8(node.reserved);
    }
    for (build.navigationEdges()) |edge| {
        try encodeChunkCoord(sink, edge.target.coord);
        try sink.writeU8(edge.target.index);
        try sink.writeU8(edge.flags);
        try sink.writeU16(edge.reserved);
    }
}

fn encodeTickDigests(sink: anytype, digests: TickDigests) !void {
    try sink.writeU64(digests.tick_index);
    try sink.writeBytes(&digests.runtime);
    try sink.writeBytes(&digests.crate);
    try sink.writeBytes(&digests.character);
    try sink.writeBytes(&digests.vehicle);
    try sink.writeBytes(&digests.district);
    try sink.writeBytes(&digests.interaction);
    try sink.writeBytes(&digests.npc);
}

fn encodeOptionalStaticBox(sink: anytype, value: ?StaticBox) !void {
    try sink.writeBool(value != null);
    if (value) |box| {
        try encodeF32Array(sink, &box.position);
        try encodeF32Array(sink, &box.half_extents);
    }
}

fn encodePersistentId(sink: anytype, id: engine.PersistentId) !void {
    try sink.writeU64(id.namespace);
    try sink.writeU64(id.local);
}

fn encodeChunkCoord(sink: anytype, coord: district_contract.ChunkCoord) !void {
    try sink.writeI32(coord.x);
    try sink.writeI32(coord.z);
}

fn encodeLoadTicket(sink: anytype, ticket: district_contract.LoadTicket) !void {
    try encodeChunkCoord(sink, ticket.coord);
    try sink.writeU64(ticket.generation);
}

fn encodeNavigationNodeRef(sink: anytype, reference: npcs.NodeRef) !void {
    try encodeChunkCoord(sink, reference.coord);
    try sink.writeU8(reference.index);
}

fn encodePose(sink: anytype, pose: engine.physics.Pose) !void {
    try encodeF32Array(sink, &pose.position);
    try encodeF32Array(sink, &pose.rotation);
}

fn encodeBodyState(sink: anytype, state: engine.physics.BodyState) !void {
    try encodePose(sink, state.pose);
    try encodeF32Array(sink, &state.velocity.linear);
    try encodeF32Array(sink, &state.velocity.angular);
}

fn encodeF32Array(sink: anytype, values: []const f32) !void {
    for (values) |value| try sink.writeF32(value);
}

fn encodedFixedPayloadSize(
    simulation_cohort: SimulationCohort,
    world: WorldConfig,
    content: ContentCohort,
) !usize {
    var sink = SizeSink{};
    try encodeSimulationCohort(&sink, simulation_cohort);
    try encodeWorldConfig(&sink, world);
    try encodeContentCohort(&sink, content);
    return sink.size;
}

fn encodedRecordedCommandSize(record: RecordedCommand) !usize {
    var sink = SizeSink{};
    try encodeRecordedCommand(&sink, record);
    return sink.size;
}

fn encodedDistrictIngressSize(ingress: DistrictCompletionIngress) !usize {
    var sink = SizeSink{};
    try encodeDistrictIngress(&sink, ingress);
    return sink.size;
}

fn encodedTickDigestsSize() usize {
    return 8 + 7 * @sizeOf(Digest);
}

fn validateRecordedCommand(record: RecordedCommand) !void {
    if (record.eligible_tick == 0) return error.InvalidEligibleTick;
    try validateNormalizedCommand(record.command);
}

fn validateNormalizedCommand(command: NormalizedCommand) !void {
    switch (command) {
        .crate => |value| switch (value) {
            .spawn => |spawn| try (engine.physics.DynamicBoxDesc{
                .pose = spawn.pose,
                .velocity = spawn.velocity,
                .half_extents = spawn.half_extents,
            }).validate(),
            .despawn => |despawn| try despawn.id.validate(),
            .impulse => |impulse| {
                try impulse.id.validate();
                try validateFiniteValues(&impulse.impulse);
            },
            .relocate => |relocation| {
                if (relocation.transaction_id == 0) return error.InvalidTransactionId;
                try relocation.id.validate();
                _ = try relocation.target_pose.normalized();
                switch (relocation.velocity) {
                    .preserve, .zero => {},
                    .exact => |velocity| try velocity.validate(),
                }
            },
        },
        .character => |value| switch (value) {
            .spawn => |spawn| {
                try validateFiniteValues(&spawn.position);
                try (engine.physics.Velocity{ .linear = spawn.velocity }).validate();
                if (!std.math.isFinite(spawn.facing_yaw)) return error.InvalidFacingYaw;
            },
            .actions => |actions| {
                try actions.id.validate();
                try validateFiniteValues(&actions.move);
                if (@abs(actions.move[0]) > 1 or @abs(actions.move[1]) > 1) {
                    return error.InvalidMoveAction;
                }
                if (!std.math.isFinite(actions.facing_yaw)) return error.InvalidFacingYaw;
            },
            .despawn => |despawn| try despawn.id.validate(),
        },
        .vehicle => |value| switch (value) {
            .spawn => |spawn| try spawn.chassis.validate(),
            .enter => |enter| {
                try enter.vehicle_id.validate();
                try enter.driver_id.validate();
            },
            .drive => |drive| {
                try drive.vehicle_id.validate();
                try drive.driver_id.validate();
                try drive.input.validate();
            },
            .exit => |exit_command| {
                try exit_command.vehicle_id.validate();
                try exit_command.driver_id.validate();
            },
            .abandon => |abandon| {
                try abandon.vehicle_id.validate();
                try abandon.driver_id.validate();
            },
            .despawn => |despawn| try despawn.id.validate(),
        },
        .district => |value| switch (value) {
            .request_load => {},
            .cancel_load => |cancel| try cancel.ticket.validate(),
            .unload => |unload_request| try unload_request.ticket.validate(),
        },
        .interaction => |value| switch (value) {
            .spawn => |spawn| try (engine.physics.DynamicBoxDesc{
                .pose = spawn.pose,
                .velocity = spawn.velocity,
                .half_extents = spawn.half_extents,
            }).validate(),
            .despawn => |despawn| try despawn.id.validate(),
            .collect => |collect| {
                if (collect.transaction_id == 0) return error.InvalidTransactionId;
                try collect.carrier_id.validate();
                try collect.carryable_id.validate();
            },
            .drop => |drop| {
                if (drop.transaction_id == 0) return error.InvalidTransactionId;
                try drop.carrier_id.validate();
                try drop.carryable_id.validate();
            },
        },
        .npc => |value| try npcs.validateCommand(value),
    }
}

fn validateDistrictIngress(ingress: DistrictCompletionIngress) !void {
    if (ingress.consumption_tick == 0) return error.InvalidConsumptionTick;
    switch (ingress.completion) {
        .ready => |ready| {
            try ready.ticket.validate();
            try ready.build.validate();
            if (!district_contract.ChunkCoord.eql(ready.ticket.coord, ready.build.coord)) {
                return error.DistrictCompletionCoordinateMismatch;
            }
        },
        .cancelled => |ticket| try ticket.validate(),
        .failed => |failed| try failed.ticket.validate(),
    }
}

fn validateCapture(capture: CaptureView, limits: Limits) !void {
    try limits.validate();
    try capture.simulation_cohort.validate();
    try capture.world.validate();
    try capture.content.validate();
    if (capture.bootstrap_commands.len > limits.max_bootstrap or
        capture.commands.len > limits.max_commands or
        capture.district_ingress.len > limits.max_ingress or
        capture.tick_digests.len > limits.max_digests)
    {
        return error.ReplayRecordCapacityExceeded;
    }

    for (capture.bootstrap_commands) |record| {
        try validateRecordedCommand(record);
        if (record.eligible_tick != 1) return error.InvalidBootstrapTick;
    }
    var previous_command_tick: u64 = 0;
    for (capture.commands) |record| {
        try validateRecordedCommand(record);
        if (record.eligible_tick == 1) return error.InvalidRuntimeCommandTick;
        if (record.eligible_tick < previous_command_tick) return error.UnorderedCommands;
        previous_command_tick = record.eligible_tick;
    }
    var previous_ingress_tick: u64 = 0;
    for (capture.district_ingress) |ingress| {
        try validateDistrictIngress(ingress);
        if (ingress.consumption_tick <= previous_ingress_tick) return error.UnorderedIngress;
        previous_ingress_tick = ingress.consumption_tick;
    }
    for (capture.tick_digests, 0..) |digests, index| {
        if (digests.tick_index != @as(u64, @intCast(index)) + 1) {
            return error.NonContiguousTickDigests;
        }
    }

    if (capture.incomplete_reason == null) {
        const final_tick: u64 = capture.tick_digests.len;
        if ((capture.bootstrap_commands.len != 0 or capture.commands.len != 0 or
            capture.district_ingress.len != 0) and final_tick == 0)
        {
            return error.MissingTickDigests;
        }
        if (previous_command_tick > final_tick or previous_ingress_tick > final_tick) {
            return error.RecordBeyondFinalTick;
        }
    }

    const payload_size = try encodedCapturePayloadSize(capture);
    const total_without_integrity = std.math.add(usize, header_size, payload_size) catch
        return error.ReplayEnvelopeTooLarge;
    const total_size = std.math.add(usize, total_without_integrity, integrity_size) catch
        return error.ReplayEnvelopeTooLarge;
    if (total_size > limits.max_file_bytes) return error.ReplayEnvelopeTooLarge;
}

fn encodedCapturePayloadSize(capture: CaptureView) !usize {
    var sink = SizeSink{};
    try encodeSimulationCohort(&sink, capture.simulation_cohort);
    try encodeWorldConfig(&sink, capture.world);
    try encodeContentCohort(&sink, capture.content);
    for (capture.bootstrap_commands) |record| try encodeRecordedCommand(&sink, record);
    for (capture.commands) |record| try encodeRecordedCommand(&sink, record);
    for (capture.district_ingress) |ingress| try encodeDistrictIngress(&sink, ingress);
    for (capture.tick_digests) |digests| try encodeTickDigests(&sink, digests);
    return sink.size;
}

fn validateFiniteValues(values: []const f32) !void {
    for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteReplayValue;
}

fn hasNonzeroByte(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return true;
    return false;
}

fn encodeBuildValidationFailure(value: district_contract.BuildValidationFailure) u8 {
    return switch (value) {
        .unsupported_recipe_version => 1,
        .no_static_boxes => 2,
        .too_many_static_boxes => 3,
        .invalid_pose => 4,
        .non_canonical_axis_alignment => 5,
        .invalid_half_extents => 6,
        .too_many_navigation_nodes => 7,
        .too_many_navigation_edges => 8,
        .navigation_count_mismatch => 9,
        .invalid_navigation_position => 10,
        .navigation_node_outside_district => 11,
        .invalid_navigation_node_flags => 12,
        .invalid_navigation_node_reserved => 13,
        .invalid_navigation_edge_range => 14,
        .invalid_navigation_node_degree => 15,
        .invalid_navigation_edge_target => 16,
        .invalid_navigation_edge_flags => 17,
        .invalid_navigation_edge_reserved => 18,
        .duplicate_navigation_edge => 19,
        .non_canonical_navigation_edge_order => 20,
        .decoded_byte_count_mismatch => 21,
        .checksum_mismatch => 22,
    };
}

pub fn encode(allocator: std.mem.Allocator, capture: CaptureView) ![]u8 {
    return encodeWithLimits(allocator, capture, .{});
}

pub fn encodeWithLimits(
    allocator: std.mem.Allocator,
    capture: CaptureView,
    limits: Limits,
) ![]u8 {
    try capture.validate(limits);
    const payload_size = try encodedCapturePayloadSize(capture);
    const total_size = std.math.add(
        usize,
        header_size + integrity_size,
        payload_size,
    ) catch return error.ReplayEnvelopeTooLarge;
    if (total_size > limits.max_file_bytes or total_size > max_envelope_bytes) {
        return error.ReplayEnvelopeTooLarge;
    }

    const bytes = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    putU16(bytes, 8, format_version);
    putU16(bytes, 10, schema_cohort);
    putU32(bytes, 12, header_size);
    putU64(bytes, 16, total_size);
    putU64(bytes, 24, header_size);
    putU64(bytes, 32, payload_size);
    putU32(bytes, 40, capture.bootstrap_commands.len);
    putU32(bytes, 44, capture.commands.len);
    putU32(bytes, 48, capture.district_ingress.len);
    putU32(bytes, 52, capture.tick_digests.len);
    bytes[56] = if (capture.incomplete_reason) |reason| @intFromEnum(reason) else 0;
    bytes[57] = if (capture.incomplete_reason != null) 1 else 0;

    const payload_end = header_size + payload_size;
    var sink = ByteSink{ .bytes = bytes[header_size..payload_end] };
    try encodeSimulationCohort(&sink, capture.simulation_cohort);
    try encodeWorldConfig(&sink, capture.world);
    try encodeContentCohort(&sink, capture.content);
    for (capture.bootstrap_commands) |record| try encodeRecordedCommand(&sink, record);
    for (capture.commands) |record| try encodeRecordedCommand(&sink, record);
    for (capture.district_ingress) |ingress| try encodeDistrictIngress(&sink, ingress);
    for (capture.tick_digests) |digests| try encodeTickDigests(&sink, digests);
    if (sink.cursor != payload_size) return error.ReplayEncoderSizeMismatch;

    var integrity: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..payload_end], &integrity, .{});
    @memcpy(bytes[payload_end..total_size], &integrity);
    return bytes;
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !ParsedCapture {
    return parseWithLimits(allocator, bytes, .{});
}

pub fn parseCompatible(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_content: ContentCohort,
) !ParsedCapture {
    var parsed = try parse(allocator, bytes);
    errdefer parsed.deinit();
    try parsed.validateCompatible(expected_content);
    return parsed;
}

pub fn parseWithLimits(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
) !ParsedCapture {
    try limits.validate();
    if (bytes.len > limits.max_file_bytes or bytes.len > max_envelope_bytes) {
        return error.ReplayEnvelopeTooLarge;
    }
    if (bytes.len < header_size + integrity_size) return error.TruncatedReplayEnvelope;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.BadReplayMagic;
    const found_version = getU16(bytes, 8);
    if (found_version != format_version) return error.UnsupportedReplayFormat;
    const found_schema = getU16(bytes, 10);
    if (found_schema != schema_cohort) return error.IncompatibleReplaySchema;
    if (getU32(bytes, 12) != header_size) return error.InvalidReplayHeader;

    const declared_total = getU64(bytes, 16);
    const declared_payload_offset = getU64(bytes, 24);
    const declared_payload_size = getU64(bytes, 32);
    if (declared_total != bytes.len or declared_payload_offset != header_size) {
        return error.ReplaySizeMismatch;
    }
    const payload_size = std.math.cast(usize, declared_payload_size) orelse
        return error.ReplaySizeMismatch;
    const payload_end = std.math.add(usize, header_size, payload_size) catch
        return error.ReplaySizeMismatch;
    const expected_total = std.math.add(usize, payload_end, integrity_size) catch
        return error.ReplaySizeMismatch;
    if (expected_total != bytes.len) return error.ReplaySizeMismatch;
    if (getU16(bytes, 58) != 0 or getU32(bytes, 60) != 0) {
        return error.InvalidReplayHeader;
    }

    const incomplete_tag = bytes[56];
    const flags = bytes[57];
    if ((flags & ~@as(u8, 1)) != 0 or ((flags & 1) != 0) != (incomplete_tag != 0)) {
        return error.InvalidReplayHeader;
    }
    const incomplete_reason: ?IncompleteReason = if (incomplete_tag == 0)
        null
    else
        std.enums.fromInt(IncompleteReason, incomplete_tag) orelse
            return error.InvalidIncompleteReason;

    const bootstrap_count = getU32(bytes, 40);
    const command_count = getU32(bytes, 44);
    const ingress_count = getU32(bytes, 48);
    const digest_count = getU32(bytes, 52);
    if (bootstrap_count > limits.max_bootstrap or
        command_count > limits.max_commands or
        ingress_count > limits.max_ingress or
        digest_count > limits.max_digests)
    {
        return error.ReplayRecordCapacityExceeded;
    }

    var actual_integrity: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..payload_end], &actual_integrity, .{});
    if (!std.mem.eql(u8, &actual_integrity, bytes[payload_end..])) {
        return error.ReplayIntegrityMismatch;
    }

    var reader = Reader{ .bytes = bytes[header_size..payload_end] };
    const simulation_cohort = try decodeSimulationCohort(&reader);
    const world = try decodeWorldConfig(&reader);
    const content = try decodeContentCohort(&reader);
    const minimum_records_size = try minimumRecordPayloadSize(
        bootstrap_count,
        command_count,
        ingress_count,
        digest_count,
    );
    if (reader.bytes.len - reader.cursor < minimum_records_size) {
        return error.TruncatedReplayPayload;
    }

    const bootstrap_commands = try allocator.alloc(RecordedCommand, bootstrap_count);
    errdefer allocator.free(bootstrap_commands);
    const commands = try allocator.alloc(RecordedCommand, command_count);
    errdefer allocator.free(commands);
    const district_ingress = try allocator.alloc(DistrictCompletionIngress, ingress_count);
    errdefer allocator.free(district_ingress);
    const tick_digests = try allocator.alloc(TickDigests, digest_count);
    errdefer allocator.free(tick_digests);

    for (bootstrap_commands) |*record| record.* = try decodeRecordedCommand(&reader);
    for (commands) |*record| record.* = try decodeRecordedCommand(&reader);
    for (district_ingress) |*ingress| ingress.* = try decodeDistrictIngress(&reader);
    for (tick_digests) |*digests| digests.* = try decodeTickDigests(&reader);
    if (reader.cursor != reader.bytes.len) return error.TrailingReplayPayload;

    const result = ParsedCapture{
        .allocator = allocator,
        .simulation_cohort = simulation_cohort,
        .world = world,
        .content = content,
        .incomplete_reason = incomplete_reason,
        .bootstrap_commands = bootstrap_commands,
        .commands = commands,
        .district_ingress = district_ingress,
        .tick_digests = tick_digests,
    };
    try result.view().validate(limits);
    return result;
}

const Reader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn readBytes(self: *Reader, destination: []u8) !void {
        const end = std.math.add(usize, self.cursor, destination.len) catch
            return error.TruncatedReplayPayload;
        if (end > self.bytes.len) return error.TruncatedReplayPayload;
        @memcpy(destination, self.bytes[self.cursor..end]);
        self.cursor = end;
    }
    fn requireBytes(self: *Reader, expected: []const u8) !void {
        const end = std.math.add(usize, self.cursor, expected.len) catch
            return error.TruncatedReplayPayload;
        if (end > self.bytes.len) return error.TruncatedReplayPayload;
        if (!std.mem.eql(u8, self.bytes[self.cursor..end], expected)) {
            return error.InvalidReplayDomain;
        }
        self.cursor = end;
    }
    fn readU8(self: *Reader) !u8 {
        if (self.cursor >= self.bytes.len) return error.TruncatedReplayPayload;
        const result = self.bytes[self.cursor];
        self.cursor += 1;
        return result;
    }
    fn readU16(self: *Reader) !u16 {
        var bytes: [2]u8 = undefined;
        try self.readBytes(&bytes);
        return std.mem.readInt(u16, &bytes, .little);
    }
    fn readU32(self: *Reader) !u32 {
        var bytes: [4]u8 = undefined;
        try self.readBytes(&bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }
    fn readU64(self: *Reader) !u64 {
        var bytes: [8]u8 = undefined;
        try self.readBytes(&bytes);
        return std.mem.readInt(u64, &bytes, .little);
    }
    fn readI32(self: *Reader) !i32 {
        return @bitCast(try self.readU32());
    }
    fn readF32(self: *Reader) !f32 {
        const value: f32 = @bitCast(try self.readU32());
        try replay.validateCanonicalF32(value);
        return value;
    }
    fn readBool(self: *Reader) !bool {
        return switch (try self.readU8()) {
            0 => false,
            1 => true,
            else => error.InvalidReplayBoolean,
        };
    }
    fn readDigest(self: *Reader) !Digest {
        var result: Digest = undefined;
        try self.readBytes(&result);
        return result;
    }
    fn readRevision(self: *Reader) !Revision {
        var result: Revision = undefined;
        try self.readBytes(&result);
        return result;
    }
};

fn decodeSimulationCohort(reader: *Reader) !SimulationCohort {
    try reader.requireBytes("simulation-cohort-v1");
    return .{
        .replay_schema = try reader.readU16(),
        .engine_schedule_cohort = try reader.readU16(),
        .snapshot_schema = try reader.readU16(),
        .zig_major = try reader.readU16(),
        .zig_minor = try reader.readU16(),
        .zig_patch = try reader.readU16(),
        .target = std.enums.fromInt(TargetCohort, try reader.readU8()) orelse
            return error.InvalidTargetCohort,
        .optimize = std.enums.fromInt(OptimizeCohort, try reader.readU8()) orelse
            return error.InvalidOptimizeCohort,
        .cpu_codegen_digest = try reader.readDigest(),
        .zflecs_revision = try reader.readRevision(),
        .flecs_debug = std.enums.fromInt(FlecsDebugCohort, try reader.readU8()) orelse
            return error.InvalidFlecsDebugCohort,
        .flecs_float_bits = try reader.readU8(),
        .flecs_time_bits = try reader.readU8(),
        .flecs_use_os_alloc = try reader.readBool(),
        .flecs_hi_component_id = try reader.readU16(),
        .flecs_hi_id_record_id = try reader.readU16(),
        .joltc_zig_revision = try reader.readRevision(),
        .joltc_revision = try reader.readRevision(),
        .jolt_revision = try reader.readRevision(),
        .jolt_no_exceptions = try reader.readBool(),
        .jolt_object_layer_bits = try reader.readU8(),
        .jolt_cross_platform_deterministic = try reader.readBool(),
        .jolt_worker_count = try reader.readI32(),
        .jolt_max_jobs = try reader.readU32(),
        .jolt_max_barriers = try reader.readU32(),
    };
}

fn decodeWorldConfig(reader: *Reader) !WorldConfig {
    try reader.requireBytes("world-config-v3");
    return .{
        .namespace = try reader.readU64(),
        .fixed_delta_seconds = try reader.readF32(),
        .max_crates = try reader.readU32(),
        .max_characters = try reader.readU32(),
        .max_vehicles = try reader.readU32(),
        .max_districts = try reader.readU8(),
        .max_interactions = try reader.readU8(),
        .max_npcs = try reader.readU32(),
        .character = try decodeCharacterConfig(reader),
        .vehicle = try decodeVehicleConfig(reader),
        .interaction = try decodeInteractionConfig(reader),
        .npc = try decodeNpcConfig(reader),
        .ground = try decodeOptionalStaticBox(reader),
        .block = try decodeOptionalStaticBox(reader),
    };
}

fn decodeNpcConfig(reader: *Reader) !npcs.NpcConfigV1 {
    return .{
        .radius = try reader.readF32(),
        .half_height = try reader.readF32(),
        .move_speed = try reader.readF32(),
        .gravity = try reader.readF32(),
        .terminal_fall_speed = try reader.readF32(),
        .max_slope_radians = try reader.readF32(),
        .mass = try reader.readF32(),
        .max_strength = try reader.readF32(),
        .stick_to_floor_distance = try reader.readF32(),
        .step_up_height = try reader.readF32(),
        .arrival_distance = try reader.readF32(),
    };
}

fn decodeInteractionConfig(reader: *Reader) !interactions.InteractionConfigV1 {
    return .{
        .collect_range = try reader.readF32(),
        .drop_offset = try decodeF32Array(reader, 3),
    };
}

fn decodeCharacterConfig(reader: *Reader) !characters.CharacterConfigV1 {
    return .{
        .radius = try reader.readF32(),
        .half_height = try reader.readF32(),
        .move_speed = try reader.readF32(),
        .jump_speed = try reader.readF32(),
        .gravity = try reader.readF32(),
        .terminal_fall_speed = try reader.readF32(),
        .max_slope_radians = try reader.readF32(),
        .mass = try reader.readF32(),
        .max_strength = try reader.readF32(),
        .stick_to_floor_distance = try reader.readF32(),
        .step_up_height = try reader.readF32(),
    };
}

fn decodeVehicleConfig(reader: *Reader) !vehicles.VehicleConfigV1 {
    var wheel_positions: [engine.physics.vehicle_wheel_count][3]f32 = undefined;
    const chassis_half_extents = try decodeF32Array(reader, 3);
    const center_of_mass_offset = try decodeF32Array(reader, 3);
    const mass = try reader.readF32();
    for (&wheel_positions) |*position| position.* = try decodeF32Array(reader, 3);
    return .{
        .tuning = .{
            .chassis_half_extents = chassis_half_extents,
            .center_of_mass_offset = center_of_mass_offset,
            .mass = mass,
            .wheel_attachment_positions = wheel_positions,
            .wheel_radius = try reader.readF32(),
            .wheel_width = try reader.readF32(),
            .suspension_min_length = try reader.readF32(),
            .suspension_max_length = try reader.readF32(),
            .suspension_frequency = try reader.readF32(),
            .suspension_damping = try reader.readF32(),
            .max_steer_radians = try reader.readF32(),
            .max_brake_torque = try reader.readF32(),
            .max_hand_brake_torque = try reader.readF32(),
            .front_differential_ratio = try reader.readF32(),
            .front_limited_slip_ratio = try reader.readF32(),
            .max_pitch_roll_radians = try reader.readF32(),
            .wheel_collision_max_slope_radians = try reader.readF32(),
        },
        .max_entry_distance = try reader.readF32(),
        .exit_offset = try decodeF32Array(reader, 3),
    };
}

fn decodeContentCohort(reader: *Reader) !ContentCohort {
    var domain: ["catalog-cohort-v1".len]u8 = undefined;
    try reader.readBytes(&domain);
    if (!std.mem.eql(u8, &domain, "catalog-cohort-v1")) {
        return error.InvalidReplayDomain;
    }
    return .{
        .catalog_format_version = try reader.readU16(),
        .catalog_schema_cohort = try reader.readU16(),
        .district_recipe_version = try reader.readU32(),
        .catalog_id_digest = try reader.readDigest(),
        .source_digest = try reader.readDigest(),
        .integrity_digest = try reader.readDigest(),
    };
}

fn decodeRecordedCommand(reader: *Reader) !RecordedCommand {
    return .{
        .eligible_tick = try reader.readU64(),
        .command = try decodeNormalizedCommand(reader),
    };
}

fn decodeNormalizedCommand(reader: *Reader) !NormalizedCommand {
    const source = std.enums.fromInt(CommandSource, try reader.readU8()) orelse
        return error.InvalidCommandSource;
    return switch (source) {
        .crate => .{ .crate = try decodeCrateCommand(reader) },
        .character => .{ .character = try decodeCharacterCommand(reader) },
        .vehicle => .{ .vehicle = try decodeVehicleCommand(reader) },
        .district => .{ .district = try decodeDistrictCommand(reader) },
        .interaction => .{ .interaction = try decodeInteractionCommand(reader) },
        .npc => .{ .npc = try decodeNpcCommand(reader) },
    };
}

fn decodeNpcCommand(reader: *Reader) !npcs.Command {
    const tag = std.enums.fromInt(NpcCommandTag, try reader.readU8()) orelse
        return error.InvalidNpcCommandTag;
    const command: npcs.Command = switch (tag) {
        .spawn => .{ .spawn = .{
            .request_id = try reader.readU64(),
            .node = try decodeNavigationNodeRef(reader),
            .goal = try decodeNpcGoal(reader),
        } },
        .set_goal => .{ .set_goal = .{
            .request_id = try reader.readU64(),
            .id = try decodePersistentId(reader),
            .goal = try decodeNpcGoal(reader),
        } },
        .despawn => .{ .despawn = .{
            .request_id = try reader.readU64(),
            .id = try decodePersistentId(reader),
        } },
    };
    try npcs.validateCommand(command);
    return command;
}

fn decodeNpcGoal(reader: *Reader) !npcs.Goal {
    const tag = std.enums.fromInt(NpcGoalTag, try reader.readU8()) orelse
        return error.InvalidNpcGoalTag;
    return switch (tag) {
        .hold => .hold,
        .navigate_to => .{ .navigate_to = try decodeNavigationNodeRef(reader) },
        .patrol_between => .{ .patrol_between = .{
            .first = try decodeNavigationNodeRef(reader),
            .second = try decodeNavigationNodeRef(reader),
        } },
    };
}

fn decodeInteractionCommand(reader: *Reader) !interactions.Command {
    const tag = std.enums.fromInt(InteractionCommandTag, try reader.readU8()) orelse
        return error.InvalidInteractionCommandTag;
    return switch (tag) {
        .spawn => .{ .spawn = .{
            .request_id = try reader.readU64(),
            .pose = try decodePose(reader),
            .velocity = .{
                .linear = try decodeF32Array(reader, 3),
                .angular = try decodeF32Array(reader, 3),
            },
            .half_extents = try decodeF32Array(reader, 3),
        } },
        .despawn => .{ .despawn = .{ .id = try decodePersistentId(reader) } },
        .collect => .{ .collect = .{
            .transaction_id = try reader.readU64(),
            .carrier_id = try decodePersistentId(reader),
            .carryable_id = try decodePersistentId(reader),
        } },
        .drop => .{ .drop = .{
            .transaction_id = try reader.readU64(),
            .carrier_id = try decodePersistentId(reader),
            .carryable_id = try decodePersistentId(reader),
        } },
    };
}

fn decodeCrateCommand(reader: *Reader) !crates.Command {
    const tag = std.enums.fromInt(CrateCommandTag, try reader.readU8()) orelse
        return error.InvalidCrateCommandTag;
    return switch (tag) {
        .spawn => .{ .spawn = .{
            .request_id = try reader.readU64(),
            .pose = try decodePose(reader),
            .velocity = .{
                .linear = try decodeF32Array(reader, 3),
                .angular = try decodeF32Array(reader, 3),
            },
            .half_extents = try decodeF32Array(reader, 3),
        } },
        .despawn => .{ .despawn = .{ .id = try decodePersistentId(reader) } },
        .impulse => .{ .impulse = .{
            .id = try decodePersistentId(reader),
            .impulse = try decodeF32Array(reader, 3),
        } },
        .relocate => blk: {
            const transaction_id = try reader.readU64();
            const id = try decodePersistentId(reader);
            const target_pose = try decodePose(reader);
            const velocity_tag = std.enums.fromInt(
                CrateRelocationVelocityTag,
                try reader.readU8(),
            ) orelse return error.InvalidCrateRelocationVelocityTag;
            const velocity: crates.RelocationVelocity = switch (velocity_tag) {
                .preserve => .preserve,
                .zero => .zero,
                .exact => .{ .exact = .{
                    .linear = try decodeF32Array(reader, 3),
                    .angular = try decodeF32Array(reader, 3),
                } },
            };
            const expected_revision = if (try reader.readBool())
                try reader.readU64()
            else
                null;
            break :blk .{ .relocate = .{
                .transaction_id = transaction_id,
                .id = id,
                .target_pose = target_pose,
                .velocity = velocity,
                .expected_revision = expected_revision,
            } };
        },
    };
}

fn decodeCharacterCommand(reader: *Reader) !characters.Command {
    const tag = std.enums.fromInt(CharacterCommandTag, try reader.readU8()) orelse
        return error.InvalidCharacterCommandTag;
    return switch (tag) {
        .spawn => .{ .spawn = .{
            .request_id = try reader.readU64(),
            .position = try decodeF32Array(reader, 3),
            .velocity = try decodeF32Array(reader, 3),
            .facing_yaw = try reader.readF32(),
        } },
        .actions => .{ .actions = .{
            .id = try decodePersistentId(reader),
            .move = try decodeF32Array(reader, 2),
            .facing_yaw = try reader.readF32(),
            .jump_pressed = try reader.readBool(),
        } },
        .despawn => .{ .despawn = .{ .id = try decodePersistentId(reader) } },
    };
}

fn decodeVehicleCommand(reader: *Reader) !vehicles.Command {
    const tag = std.enums.fromInt(VehicleCommandTag, try reader.readU8()) orelse
        return error.InvalidVehicleCommandTag;
    return switch (tag) {
        .spawn => .{ .spawn = .{
            .request_id = try reader.readU64(),
            .chassis = try decodeBodyState(reader),
        } },
        .enter => .{ .enter = .{
            .vehicle_id = try decodePersistentId(reader),
            .driver_id = try decodePersistentId(reader),
        } },
        .drive => .{ .drive = .{
            .vehicle_id = try decodePersistentId(reader),
            .driver_id = try decodePersistentId(reader),
            .input = .{
                .throttle = try reader.readF32(),
                .steering = try reader.readF32(),
                .brake = try reader.readF32(),
                .hand_brake = try reader.readF32(),
            },
        } },
        .exit => .{ .exit = .{
            .vehicle_id = try decodePersistentId(reader),
            .driver_id = try decodePersistentId(reader),
        } },
        .abandon => .{ .abandon = .{
            .vehicle_id = try decodePersistentId(reader),
            .driver_id = try decodePersistentId(reader),
        } },
        .despawn => .{ .despawn = .{ .id = try decodePersistentId(reader) } },
    };
}

fn decodeDistrictCommand(reader: *Reader) !NormalizedDistrictCommand {
    const tag = std.enums.fromInt(DistrictCommandTag, try reader.readU8()) orelse
        return error.InvalidDistrictCommandTag;
    return switch (tag) {
        .request_load => .{ .request_load = .{
            .request_id = try reader.readU64(),
            .coord = try decodeChunkCoord(reader),
        } },
        .cancel_load => .{ .cancel_load = .{
            .request_id = try reader.readU64(),
            .ticket = try decodeLoadTicket(reader),
        } },
        .unload => .{ .unload = .{
            .request_id = try reader.readU64(),
            .ticket = try decodeLoadTicket(reader),
        } },
    };
}

fn decodeDistrictIngress(reader: *Reader) !DistrictCompletionIngress {
    const consumption_tick = try reader.readU64();
    const tag = std.enums.fromInt(CompletionTag, try reader.readU8()) orelse
        return error.InvalidCompletionTag;
    const completion: district_contract.Completion = switch (tag) {
        .ready => .{ .ready = .{
            .ticket = try decodeLoadTicket(reader),
            .build = try decodeDistrictBuild(reader),
        } },
        .cancelled => .{ .cancelled = try decodeLoadTicket(reader) },
        .failed => blk: {
            const ticket = try decodeLoadTicket(reader);
            const failure_tag = std.enums.fromInt(FailureTag, try reader.readU8()) orelse
                return error.InvalidDistrictFailureTag;
            const failure: district_contract.Failure = switch (failure_tag) {
                .unsupported_recipe_version => .{
                    .unsupported_recipe_version = try reader.readU32(),
                },
                .invalid_build => .{
                    .invalid_build = try decodeBuildValidationFailure(try reader.readU8()),
                },
            };
            break :blk .{ .failed = .{ .ticket = ticket, .failure = failure } };
        },
    };
    return .{ .consumption_tick = consumption_tick, .completion = completion };
}

fn decodeDistrictBuild(reader: *Reader) !district_contract.DistrictBuild {
    const coord = try decodeChunkCoord(reader);
    const recipe_version = try reader.readU32();
    const checksum = try reader.readU64();
    const decoded_bytes = try reader.readU32();
    const static_box_count = try reader.readU8();
    const navigation_node_count = try reader.readU8();
    const navigation_edge_count = try reader.readU8();
    if (static_box_count > district_contract.max_static_boxes) {
        return error.DistrictStaticBoxCapacityExceeded;
    }
    if (navigation_node_count > district_contract.max_navigation_nodes) {
        return error.DistrictNavigationNodeCapacityExceeded;
    }
    if (navigation_edge_count > district_contract.max_navigation_edges) {
        return error.DistrictNavigationEdgeCapacityExceeded;
    }
    var result = district_contract.DistrictBuild{
        .coord = coord,
        .recipe_version = recipe_version,
        .checksum = checksum,
        .decoded_bytes = decoded_bytes,
        .static_box_count = static_box_count,
        .navigation_node_count = navigation_node_count,
        .navigation_edge_count = navigation_edge_count,
    };
    for (result.static_boxes[0..static_box_count]) |*box| {
        box.* = .{
            .pose = try decodePose(reader),
            .half_extents = try decodeF32Array(reader, 3),
        };
    }
    for (result.navigation_nodes[0..navigation_node_count]) |*node| {
        node.* = .{
            .position = try decodeF32Array(reader, 3),
            .first_edge = try reader.readU8(),
            .edge_count = try reader.readU8(),
            .flags = try reader.readU8(),
            .reserved = try reader.readU8(),
        };
    }
    for (result.navigation_edges[0..navigation_edge_count]) |*edge| {
        edge.* = .{
            .target = .{
                .coord = try decodeChunkCoord(reader),
                .index = try reader.readU8(),
            },
            .flags = try reader.readU8(),
            .reserved = try reader.readU16(),
        };
    }
    return result;
}

fn decodeTickDigests(reader: *Reader) !TickDigests {
    return .{
        .tick_index = try reader.readU64(),
        .runtime = try reader.readDigest(),
        .crate = try reader.readDigest(),
        .character = try reader.readDigest(),
        .vehicle = try reader.readDigest(),
        .district = try reader.readDigest(),
        .interaction = try reader.readDigest(),
        .npc = try reader.readDigest(),
    };
}

fn decodeOptionalStaticBox(reader: *Reader) !?StaticBox {
    if (!try reader.readBool()) return null;
    return .{
        .position = try decodeF32Array(reader, 3),
        .half_extents = try decodeF32Array(reader, 3),
    };
}

fn decodePersistentId(reader: *Reader) !engine.PersistentId {
    return .{ .namespace = try reader.readU64(), .local = try reader.readU64() };
}

fn decodeChunkCoord(reader: *Reader) !district_contract.ChunkCoord {
    return .{ .x = try reader.readI32(), .z = try reader.readI32() };
}

fn decodeNavigationNodeRef(reader: *Reader) !npcs.NodeRef {
    return .{
        .coord = try decodeChunkCoord(reader),
        .index = try reader.readU8(),
    };
}

fn decodeLoadTicket(reader: *Reader) !district_contract.LoadTicket {
    return .{ .coord = try decodeChunkCoord(reader), .generation = try reader.readU64() };
}

fn decodePose(reader: *Reader) !engine.physics.Pose {
    return .{
        .position = try decodeF32Array(reader, 3),
        .rotation = try decodeF32Array(reader, 4),
    };
}

fn decodeBodyState(reader: *Reader) !engine.physics.BodyState {
    return .{
        .pose = try decodePose(reader),
        .velocity = .{
            .linear = try decodeF32Array(reader, 3),
            .angular = try decodeF32Array(reader, 3),
        },
    };
}

fn decodeF32Array(reader: *Reader, comptime len: usize) ![len]f32 {
    var result: [len]f32 = undefined;
    for (&result) |*value| value.* = try reader.readF32();
    return result;
}

fn decodeBuildValidationFailure(value: u8) !district_contract.BuildValidationFailure {
    return switch (value) {
        1 => .unsupported_recipe_version,
        2 => .no_static_boxes,
        3 => .too_many_static_boxes,
        4 => .invalid_pose,
        5 => .non_canonical_axis_alignment,
        6 => .invalid_half_extents,
        7 => .too_many_navigation_nodes,
        8 => .too_many_navigation_edges,
        9 => .navigation_count_mismatch,
        10 => .invalid_navigation_position,
        11 => .navigation_node_outside_district,
        12 => .invalid_navigation_node_flags,
        13 => .invalid_navigation_node_reserved,
        14 => .invalid_navigation_edge_range,
        15 => .invalid_navigation_node_degree,
        16 => .invalid_navigation_edge_target,
        17 => .invalid_navigation_edge_flags,
        18 => .invalid_navigation_edge_reserved,
        19 => .duplicate_navigation_edge,
        20 => .non_canonical_navigation_edge_order,
        21 => .decoded_byte_count_mismatch,
        22 => .checksum_mismatch,
        else => error.InvalidBuildValidationFailure,
    };
}

fn minimumRecordPayloadSize(
    bootstrap_count: u32,
    command_count: u32,
    ingress_count: u32,
    digest_count: u32,
) !usize {
    // Smallest command is a persistent-ID-only despawn. Smallest completion
    // is cancellation with one ticket. Digests are fixed-size.
    const command_total = std.math.mul(
        usize,
        @as(usize, bootstrap_count) + @as(usize, command_count),
        8 + 1 + 1 + 16,
    ) catch return error.ReplayEnvelopeTooLarge;
    const ingress_total = std.math.mul(
        usize,
        ingress_count,
        8 + 1 + 16,
    ) catch return error.ReplayEnvelopeTooLarge;
    const digest_total = std.math.mul(
        usize,
        digest_count,
        encodedTickDigestsSize(),
    ) catch return error.ReplayEnvelopeTooLarge;
    const commands_and_ingress = std.math.add(usize, command_total, ingress_total) catch
        return error.ReplayEnvelopeTooLarge;
    return std.math.add(usize, commands_and_ingress, digest_total) catch
        return error.ReplayEnvelopeTooLarge;
}

fn putU16(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], @intCast(value), .little);
}

fn putU32(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @intCast(value), .little);
}

fn putU64(bytes: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], @intCast(value), .little);
}

fn getU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn getU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn getU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

const TestCapture = struct {
    world: WorldConfig,
    content: ContentCohort,
    bootstrap: [6]RecordedCommand,
    commands: [18]RecordedCommand,
    ingress: [3]DistrictCompletionIngress,
    digests: [4]TickDigests,

    fn view(self: *const TestCapture) CaptureView {
        return .{
            .simulation_cohort = current_simulation_cohort,
            .world = self.world,
            .content = self.content,
            .bootstrap_commands = &self.bootstrap,
            .commands = &self.commands,
            .district_ingress = &self.ingress,
            .tick_digests = &self.digests,
        };
    }
};

fn testWorldConfig() !WorldConfig {
    return WorldConfig.fromFeatureConfigs(
        77,
        1.0 / 120.0,
        32,
        .{ .max_characters = 2 },
        .{ .max_vehicles = 2 },
        .{},
        .{},
        true,
        .{ .position = .{ 0, 1, -4 }, .half_extents = .{ 2, 1, 0.5 } },
    );
}

fn testContentCohort() !ContentCohort {
    return ContentCohort.init(
        "district/test-catalog",
        current_catalog_format_version,
        current_catalog_schema_cohort,
        sandbox_recipe.current_recipe_version,
        [_]u8{0x31} ** 32,
        [_]u8{0xa7} ** 32,
    );
}

fn testTickDigests(tick_index: u64, seed: u8) TickDigests {
    return .{
        .tick_index = tick_index,
        .runtime = [_]u8{seed} ** 32,
        .crate = [_]u8{seed +% 1} ** 32,
        .character = [_]u8{seed +% 2} ** 32,
        .vehicle = [_]u8{seed +% 3} ** 32,
        .district = [_]u8{seed +% 4} ** 32,
        .interaction = [_]u8{seed +% 5} ** 32,
        .npc = [_]u8{seed +% 6} ** 32,
    };
}

fn testCapture() !TestCapture {
    const first_id = engine.PersistentId{ .namespace = 77, .local = 1 };
    const second_id = engine.PersistentId{ .namespace = 77, .local = 2 };
    const third_id = engine.PersistentId{ .namespace = 77, .local = 3 };
    const coord = district_contract.ChunkCoord{ .x = -3, .z = 9 };
    const ticket = district_contract.LoadTicket{ .coord = coord, .generation = 4 };
    const build = switch (sandbox_recipe.build(
        coord,
        sandbox_recipe.current_recipe_version,
    )) {
        .ready => |value| value,
        .failed => unreachable,
    };

    return .{
        .world = try testWorldConfig(),
        .content = try testContentCohort(),
        .bootstrap = .{
            .{
                .eligible_tick = 1,
                .command = .{ .crate = .{ .spawn = .{
                    .request_id = 1,
                    .pose = .{ .position = .{ 0, 4, 0 } },
                } } },
            },
            .{ .eligible_tick = 1, .command = .{ .crate = .{ .spawn = .{
                .request_id = 2,
                .pose = .{ .position = .{ 1, 4, 0 } },
                .velocity = .{ .linear = .{ 1, 0, 0 } },
                .half_extents = .{ 0.5, 1, 0.5 },
            } } } },
            .{ .eligible_tick = 1, .command = .{ .crate = .{
                .despawn = .{ .id = first_id },
            } } },
            .{ .eligible_tick = 1, .command = .{ .crate = .{ .impulse = .{
                .id = first_id,
                .impulse = .{ 2, 0, -1 },
            } } } },
            .{ .eligible_tick = 1, .command = .{ .character = .{ .spawn = .{
                .request_id = 3,
                .position = .{ 0, 0, 1 },
                .velocity = .{ 0, 1, 0 },
                .facing_yaw = 0.25,
            } } } },
            .{ .eligible_tick = 1, .command = .{ .character = .{ .actions = .{
                .id = first_id,
                .move = .{ 0.5, -0.25 },
                .facing_yaw = -0.5,
                .jump_pressed = true,
            } } } },
        },
        .commands = .{
            .{ .eligible_tick = 2, .command = .{ .character = .{
                .despawn = .{ .id = first_id },
            } } },
            .{ .eligible_tick = 2, .command = .{ .vehicle = .{ .spawn = .{
                .request_id = 4,
                .chassis = .{ .pose = .{ .position = .{ 0, 2, 0 } } },
            } } } },
            .{ .eligible_tick = 2, .command = .{ .vehicle = .{ .enter = .{
                .vehicle_id = second_id,
                .driver_id = first_id,
            } } } },
            .{ .eligible_tick = 2, .command = .{ .vehicle = .{ .drive = .{
                .vehicle_id = second_id,
                .driver_id = first_id,
                .input = .{ .throttle = 0.75, .steering = -0.25, .brake = 0.1 },
            } } } },
            .{ .eligible_tick = 2, .command = .{ .vehicle = .{ .exit = .{
                .vehicle_id = second_id,
                .driver_id = first_id,
            } } } },
            .{ .eligible_tick = 3, .command = .{ .vehicle = .{
                .despawn = .{ .id = second_id },
            } } },
            .{ .eligible_tick = 3, .command = .{ .district = .{
                .request_load = .{ .request_id = 5, .coord = coord },
            } } },
            .{ .eligible_tick = 3, .command = .{ .district = .{
                .cancel_load = .{ .request_id = 6, .ticket = ticket },
            } } },
            .{ .eligible_tick = 3, .command = .{ .district = .{
                .unload = .{ .request_id = 7, .ticket = ticket },
            } } },
            .{ .eligible_tick = 3, .command = .{ .crate = .{ .relocate = .{
                .transaction_id = 8,
                .id = second_id,
                .target_pose = .{
                    .position = .{ 4, 5, -2 },
                    .rotation = .{ 0, 0.70710677, 0, 0.70710677 },
                },
                .velocity = .{ .exact = .{
                    .linear = .{ 1, 2, 3 },
                    .angular = .{ -1, 0.5, 0 },
                } },
                .expected_revision = 4,
            } } } },
            .{ .eligible_tick = 4, .command = .{ .interaction = .{ .spawn = .{
                .request_id = 9,
                .pose = .{ .position = .{ 1, 0.5, 2 } },
                .velocity = .{ .linear = .{ 0.25, 0, -0.5 } },
                .half_extents = .{ 0.3, 0.4, 0.5 },
            } } } },
            .{ .eligible_tick = 4, .command = .{ .interaction = .{ .collect = .{
                .transaction_id = 10,
                .carrier_id = first_id,
                .carryable_id = second_id,
            } } } },
            .{ .eligible_tick = 4, .command = .{ .interaction = .{ .drop = .{
                .transaction_id = 11,
                .carrier_id = first_id,
                .carryable_id = second_id,
            } } } },
            .{ .eligible_tick = 4, .command = .{ .interaction = .{
                .despawn = .{ .id = second_id },
            } } },
            .{ .eligible_tick = 4, .command = .{ .npc = .{ .spawn = .{
                .request_id = 12,
                .node = .{ .coord = sandbox_recipe.navigation_west_coord, .index = 0 },
                .goal = .hold,
            } } } },
            .{ .eligible_tick = 4, .command = .{ .npc = .{ .set_goal = .{
                .request_id = 13,
                .id = third_id,
                .goal = .{ .navigate_to = .{
                    .coord = sandbox_recipe.navigation_east_coord,
                    .index = 2,
                } },
            } } } },
            .{ .eligible_tick = 4, .command = .{ .npc = .{ .set_goal = .{
                .request_id = 14,
                .id = third_id,
                .goal = .{ .patrol_between = .{
                    .first = .{
                        .coord = sandbox_recipe.navigation_west_coord,
                        .index = 0,
                    },
                    .second = .{
                        .coord = sandbox_recipe.navigation_east_coord,
                        .index = 2,
                    },
                } },
            } } } },
            .{ .eligible_tick = 4, .command = .{ .npc = .{ .despawn = .{
                .request_id = 15,
                .id = third_id,
            } } } },
        },
        .ingress = .{
            .{
                .consumption_tick = 2,
                .completion = .{ .ready = .{ .ticket = ticket, .build = build } },
            },
            .{ .consumption_tick = 3, .completion = .{ .cancelled = ticket } },
            .{
                .consumption_tick = 4,
                .completion = .{ .failed = .{
                    .ticket = ticket,
                    .failure = .{ .invalid_build = .checksum_mismatch },
                } },
            },
        },
        .digests = .{
            testTickDigests(1, 0x10),
            testTickDigests(2, 0x20),
            testTickDigests(3, 0x30),
            testTickDigests(4, 0x40),
        },
    };
}

fn expectCaptureEqual(expected: CaptureView, actual: CaptureView) !void {
    try std.testing.expect(std.meta.eql(expected.simulation_cohort, actual.simulation_cohort));
    try std.testing.expect(std.meta.eql(expected.world, actual.world));
    try std.testing.expect(std.meta.eql(expected.content, actual.content));
    try std.testing.expectEqual(expected.incomplete_reason, actual.incomplete_reason);
    try std.testing.expectEqual(expected.bootstrap_commands.len, actual.bootstrap_commands.len);
    try std.testing.expectEqual(expected.commands.len, actual.commands.len);
    try std.testing.expectEqual(expected.district_ingress.len, actual.district_ingress.len);
    try std.testing.expectEqual(expected.tick_digests.len, actual.tick_digests.len);
    for (expected.bootstrap_commands, actual.bootstrap_commands) |lhs, rhs| {
        try std.testing.expect(std.meta.eql(lhs, rhs));
    }
    for (expected.commands, actual.commands) |lhs, rhs| {
        try std.testing.expect(std.meta.eql(lhs, rhs));
    }
    for (expected.district_ingress, actual.district_ingress) |lhs, rhs| {
        try std.testing.expect(std.meta.eql(lhs, rhs));
    }
    for (expected.tick_digests, actual.tick_digests) |lhs, rhs| {
        try std.testing.expectEqual(lhs, rhs);
    }
}

fn refreshIntegrity(bytes: []u8) void {
    const payload_end = bytes.len - integrity_size;
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..payload_end], &digest, .{});
    @memcpy(bytes[payload_end..], &digest);
}

test "current simulation cohort pins the exact Jolt worker and capacity configuration" {
    try current_simulation_cohort.validate();
    try std.testing.expectEqual(@as(u16, 5), current_simulation_cohort.replay_schema);
    try std.testing.expectEqual(@as(u16, 5), current_simulation_cohort.engine_schedule_cohort);
    try std.testing.expectEqual(@as(u16, 7), current_simulation_cohort.snapshot_schema);
    try std.testing.expectEqual(@as(i32, 1), current_simulation_cohort.jolt_worker_count);
    try std.testing.expectEqual(
        simulation_cohort_options.jolt_worker_count,
        current_simulation_cohort.jolt_worker_count,
    );
    try std.testing.expectEqual(
        simulation_cohort_options.jolt_max_jobs,
        current_simulation_cohort.jolt_max_jobs,
    );
    try std.testing.expectEqual(
        simulation_cohort_options.jolt_max_barriers,
        current_simulation_cohort.jolt_max_barriers,
    );
    try std.testing.expectEqual(TargetCohort.macos_aarch64, current_simulation_cohort.target);
    try std.testing.expectEqual(currentCpuCodegenDigest(), current_simulation_cohort.cpu_codegen_digest);

    const changed_model_digest = cpuCodegenDigest(
        "different-apple-cpu",
        builtin.target.cpu.features,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &current_simulation_cohort.cpu_codegen_digest,
        &changed_model_digest,
    ));
    var changed_features = builtin.target.cpu.features;
    const first_feature = std.Target.aarch64.all_features[0];
    if (changed_features.isEnabled(first_feature.index)) {
        changed_features.removeFeature(first_feature.index);
    } else {
        changed_features.addFeature(first_feature.index);
    }
    const changed_feature_digest = cpuCodegenDigest(
        builtin.target.cpu.model.name,
        changed_features,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &current_simulation_cohort.cpu_codegen_digest,
        &changed_feature_digest,
    ));

    const first = try current_simulation_cohort.fingerprint();
    const second = try current_simulation_cohort.fingerprint();
    try std.testing.expectEqual(first, second);
    var changed = current_simulation_cohort;
    changed.jolt_worker_count += 1;
    try std.testing.expect(!std.mem.eql(u8, &first, &(try changed.fingerprint())));
}

test "crate relocation command codec preserves policy revision and rejects hostile tags" {
    const command = NormalizedCommand{ .crate = .{ .relocate = .{
        .transaction_id = 91,
        .id = .{ .namespace = 77, .local = 2 },
        .target_pose = .{
            .position = .{ 3, 4, 5 },
            .rotation = .{ 0, 0.70710677, 0, 0.70710677 },
        },
        .velocity = .{ .exact = .{
            .linear = .{ 1, -2, 3 },
            .angular = .{ 0.25, 0.5, -0.75 },
        } },
        .expected_revision = 14,
    } } };
    try validateNormalizedCommand(command);

    var bytes: [128]u8 = undefined;
    var sink = ByteSink{ .bytes = &bytes };
    try encodeNormalizedCommand(&sink, command);
    var reader = Reader{ .bytes = bytes[0..sink.cursor] };
    const decoded = try decodeNormalizedCommand(&reader);
    try std.testing.expect(std.meta.eql(command, decoded));
    try std.testing.expectEqual(sink.cursor, reader.cursor);

    var invalid_transaction = command;
    invalid_transaction.crate.relocate.transaction_id = 0;
    try std.testing.expectError(
        error.InvalidTransactionId,
        validateNormalizedCommand(invalid_transaction),
    );

    // source + crate tag + transaction + persistent ID + pose
    const velocity_tag_offset = 1 + 1 + 8 + 16 + (7 * @sizeOf(f32));
    bytes[velocity_tag_offset] = 0xff;
    var hostile_reader = Reader{ .bytes = bytes[0..sink.cursor] };
    try std.testing.expectError(
        error.InvalidCrateRelocationVelocityTag,
        decodeNormalizedCommand(&hostile_reader),
    );
}

test "interaction command codec is canonical validated and tag bounded" {
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(CommandSource.interaction));
    const command = NormalizedCommand.fromInteraction(.{ .collect = .{
        .transaction_id = 92,
        .carrier_id = .{ .namespace = 77, .local = 1 },
        .carryable_id = .{ .namespace = 77, .local = 2 },
    } });
    try validateNormalizedCommand(command);

    var bytes: [128]u8 = undefined;
    var sink = ByteSink{ .bytes = &bytes };
    try encodeNormalizedCommand(&sink, command);
    var reader = Reader{ .bytes = bytes[0..sink.cursor] };
    const decoded = try decodeNormalizedCommand(&reader);
    try std.testing.expect(std.meta.eql(command, decoded));
    try std.testing.expectEqual(sink.cursor, reader.cursor);
    try std.testing.expectEqual(try command.fingerprint(), try decoded.fingerprint());

    var invalid_transaction = command;
    invalid_transaction.interaction.collect.transaction_id = 0;
    try std.testing.expectError(
        error.InvalidTransactionId,
        validateNormalizedCommand(invalid_transaction),
    );

    bytes[1] = 0xff;
    var hostile_reader = Reader{ .bytes = bytes[0..sink.cursor] };
    try std.testing.expectError(
        error.InvalidInteractionCommandTag,
        decodeNormalizedCommand(&hostile_reader),
    );
}

test "NPC command codec covers every command goal and validates while decoding" {
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(CommandSource.npc));
    const west = npcs.NodeRef{
        .coord = sandbox_recipe.navigation_west_coord,
        .index = 0,
    };
    const east = npcs.NodeRef{
        .coord = sandbox_recipe.navigation_east_coord,
        .index = 2,
    };
    const id = engine.PersistentId{ .namespace = 77, .local = 3 };
    const commands = [_]NormalizedCommand{
        NormalizedCommand.fromNpc(.{ .spawn = .{
            .request_id = 101,
            .node = west,
            .goal = .hold,
        } }),
        NormalizedCommand.fromNpc(.{ .set_goal = .{
            .request_id = 102,
            .id = id,
            .goal = .{ .navigate_to = east },
        } }),
        NormalizedCommand.fromNpc(.{ .set_goal = .{
            .request_id = 103,
            .id = id,
            .goal = .{ .patrol_between = .{ .first = west, .second = east } },
        } }),
        NormalizedCommand.fromNpc(.{ .despawn = .{
            .request_id = 104,
            .id = id,
        } }),
    };
    const expected_sizes = [_]usize{ 20, 36, 45, 26 };

    for (commands, expected_sizes) |command, expected_size| {
        try validateNormalizedCommand(command);
        var sizer = SizeSink{};
        try encodeNormalizedCommand(&sizer, command);
        try std.testing.expectEqual(expected_size, sizer.size);
        var storage: [128]u8 = undefined;
        var sink = ByteSink{ .bytes = &storage };
        try encodeNormalizedCommand(&sink, command);
        var reader = Reader{ .bytes = storage[0..sink.cursor] };
        const decoded = try decodeNormalizedCommand(&reader);
        try std.testing.expect(std.meta.eql(command, decoded));
        try std.testing.expectEqual(sink.cursor, reader.cursor);
        try std.testing.expectEqual(try command.fingerprint(), try decoded.fingerprint());
    }
    var patrol_fingerprint_expected: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &patrol_fingerprint_expected,
        "6492549f47350880de4b5146f93141a2108c75dff564c72a8162762322ffa4e6",
    );
    try std.testing.expectEqual(
        patrol_fingerprint_expected,
        try commands[2].fingerprint(),
    );

    var recorder = try Recorder.init(
        std.testing.allocator,
        try testWorldConfig(),
        try testContentCohort(),
        .{
            .max_bootstrap = 0,
            .max_commands = commands.len,
            .max_ingress = 0,
            .max_digests = 0,
        },
    );
    defer recorder.deinit();
    for (commands) |command| {
        try std.testing.expectEqual(
            RecordResult.recorded,
            recorder.recordCommand(2, command),
        );
    }

    var storage: [128]u8 = undefined;
    var sink = ByteSink{ .bytes = &storage };
    try encodeNormalizedCommand(&sink, commands[0]);

    const command_tag = storage[1];
    storage[1] = 0xff;
    var hostile_command = Reader{ .bytes = storage[0..sink.cursor] };
    try std.testing.expectError(
        error.InvalidNpcCommandTag,
        decodeNormalizedCommand(&hostile_command),
    );
    storage[1] = command_tag;

    const goal_tag_offset = 1 + 1 + 8 + 8 + 1;
    storage[goal_tag_offset] = 0xff;
    var hostile_goal = Reader{ .bytes = storage[0..sink.cursor] };
    try std.testing.expectError(
        error.InvalidNpcGoalTag,
        decodeNormalizedCommand(&hostile_goal),
    );

    const invalid_request = NormalizedCommand.fromNpc(.{ .spawn = .{
        .request_id = 0,
        .node = west,
        .goal = .hold,
    } });
    var invalid_request_storage: [128]u8 = undefined;
    var invalid_request_sink = ByteSink{ .bytes = &invalid_request_storage };
    try encodeNormalizedCommand(&invalid_request_sink, invalid_request);
    var invalid_request_reader = Reader{
        .bytes = invalid_request_storage[0..invalid_request_sink.cursor],
    };
    try std.testing.expectError(
        error.InvalidNpcRequestId,
        decodeNormalizedCommand(&invalid_request_reader),
    );

    const noncanonical_patrol = NormalizedCommand.fromNpc(.{ .set_goal = .{
        .request_id = 105,
        .id = id,
        .goal = .{ .patrol_between = .{ .first = west, .second = west } },
    } });
    var patrol_storage: [128]u8 = undefined;
    var patrol_sink = ByteSink{ .bytes = &patrol_storage };
    try encodeNormalizedCommand(&patrol_sink, noncanonical_patrol);
    var patrol_reader = Reader{ .bytes = patrol_storage[0..patrol_sink.cursor] };
    try std.testing.expectError(
        error.InvalidNpcPatrol,
        decodeNormalizedCommand(&patrol_reader),
    );
}

test "world and content cohorts are renderer-free canonical construction inputs" {
    const world = try testWorldConfig();
    try world.validate();
    try std.testing.expect(world.ground != null);
    try std.testing.expectEqual(@as(u32, 2), world.max_characters);
    try std.testing.expectEqual(@as(u32, 2), world.max_vehicles);
    try std.testing.expectEqual(@as(u8, 1), world.max_interactions);
    try std.testing.expectEqual(@as(u32, 64), world.max_npcs);
    try std.testing.expectEqual(@as(f32, 2.5), world.interaction.collect_range);
    try std.testing.expectEqual(@as(f32, 2.5), world.npc.move_speed);
    try std.testing.expect(!@hasField(WorldConfig, "assets"));
    var world_v3_sizer = SizeSink{};
    try encodeWorldConfig(&world_v3_sizer, world);
    try std.testing.expectEqual(@as(usize, 343), world_v3_sizer.size);
    try std.testing.expectEqual(@as(usize, 232), encodedTickDigestsSize());
    var world_v3_expected: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &world_v3_expected,
        "0ba288eeb62c2cd1c8ee2b76564502313bb3c26c047836eaeb7cdaacfe8027d8",
    );
    try std.testing.expectEqual(world_v3_expected, try world.fingerprint());

    const baseline_world_fingerprint = try world.fingerprint();
    var npc_tuning_variants = [_]WorldConfig{world} ** 11;
    npc_tuning_variants[0].npc.radius = 0.36;
    npc_tuning_variants[1].npc.half_height = 0.46;
    npc_tuning_variants[2].npc.move_speed = 2.6;
    npc_tuning_variants[3].npc.gravity = -19;
    npc_tuning_variants[4].npc.terminal_fall_speed = 54;
    npc_tuning_variants[5].npc.max_slope_radians = 0.8;
    npc_tuning_variants[6].npc.mass = 66;
    npc_tuning_variants[7].npc.max_strength = 101;
    npc_tuning_variants[8].npc.stick_to_floor_distance = 0.45;
    npc_tuning_variants[9].npc.step_up_height = 0.35;
    npc_tuning_variants[10].npc.arrival_distance = 0.09;
    for (npc_tuning_variants) |variant| {
        try variant.validate();
        const variant_fingerprint = try variant.fingerprint();
        try std.testing.expect(!std.mem.eql(
            u8,
            &baseline_world_fingerprint,
            &variant_fingerprint,
        ));
    }

    var changed_interaction = world;
    changed_interaction.interaction.collect_range = 3.0;
    try changed_interaction.validate();
    try std.testing.expect(!std.mem.eql(
        u8,
        &(try world.fingerprint()),
        &(try changed_interaction.fingerprint()),
    ));

    var changed_npc = world;
    changed_npc.npc.move_speed = 3.0;
    try changed_npc.validate();
    try std.testing.expect(!std.mem.eql(
        u8,
        &(try world.fingerprint()),
        &(try changed_npc.fingerprint()),
    ));

    const content = try testContentCohort();
    try content.validate();
    try std.testing.expectEqual(
        sandbox_recipe.current_recipe_version,
        content.recipeVersion(),
    );
    const same = try testContentCohort();
    try std.testing.expectEqual(try content.fingerprint(), try same.fingerprint());

    // Recipe V2 intentionally changes the renderer-free content cohort even
    // when the synthetic bundle/catalog digests remain the same.
    var recipe_v2_expected: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &recipe_v2_expected,
        "59617f99b6e9bde383bc18659340e62549c337a7e93e44bfa1280cebcb3d1528",
    );
    const recipe_v2_actual = try content.fingerprint();
    try std.testing.expectEqualSlices(u8, &recipe_v2_expected, &recipe_v2_actual);

    const catalog = try ContentCohort.init(
        "district/catalog",
        current_catalog_format_version,
        current_catalog_schema_cohort,
        sandbox_recipe.current_recipe_version,
        [_]u8{0x31} ** 32,
        [_]u8{0xa7} ** 32,
    );
    try catalog.validate();
    const catalog_fingerprint = try catalog.fingerprint();
    try std.testing.expect(!std.mem.eql(u8, &catalog_fingerprint, &recipe_v2_actual));

    var catalog_fixture = try testCapture();
    catalog_fixture.content = catalog;
    const catalog_bytes = try encode(std.testing.allocator, catalog_fixture.view());
    defer std.testing.allocator.free(catalog_bytes);
    var parsed_catalog = try parseCompatible(
        std.testing.allocator,
        catalog_bytes,
        catalog,
    );
    defer parsed_catalog.deinit();
    try std.testing.expectEqual(catalog, parsed_catalog.content);

    var unsupported_ground = world;
    unsupported_ground.ground.?.position[0] = 1;
    try std.testing.expectError(
        error.UnsupportedGroundConfiguration,
        unsupported_ground.validate(),
    );

    // Treat replay-provided capacities as hostile input. In particular, a
    // maximum-width character count must be rejected before the simulation can
    // size its per-tick digest scratch from this value.
    var oversized = world;
    oversized.max_characters = std.math.maxInt(u32);
    try std.testing.expectError(
        error.WorldCapacityOutOfRange,
        oversized.validate(),
    );
    var invalid_interaction_capacity = world;
    invalid_interaction_capacity.max_interactions = 2;
    try std.testing.expectError(
        error.InvalidWorldCapacity,
        invalid_interaction_capacity.validate(),
    );
    var invalid_npc_capacity = world;
    invalid_npc_capacity.max_npcs -= 1;
    try std.testing.expectError(
        error.InvalidWorldCapacity,
        invalid_npc_capacity.validate(),
    );
    var excessive_virtual_characters = world;
    excessive_virtual_characters.max_characters =
        simulation_cohort_options.jolt_max_virtual_characters - max_world_npcs + 1;
    try std.testing.expectError(
        error.VirtualCharacterCapacityExceeded,
        excessive_virtual_characters.validate(),
    );
}

test "district ingress codec preserves bounded navigation and rejects hostile counts" {
    const west = switch (sandbox_recipe.build(
        sandbox_recipe.navigation_west_coord,
        sandbox_recipe.current_recipe_version,
    )) {
        .ready => |value| value,
        .failed => unreachable,
    };
    try west.validate();

    var storage: [1024]u8 = undefined;
    var sink = ByteSink{ .bytes = &storage };
    try encodeDistrictBuild(&sink, west);
    var reader = Reader{ .bytes = storage[0..sink.cursor] };
    const decoded = try decodeDistrictBuild(&reader);
    try decoded.validate();
    try std.testing.expect(std.meta.eql(west, decoded));
    try std.testing.expectEqual(sink.cursor, reader.cursor);

    // Counts follow coord(8), recipe(4), checksum(8), and decoded bytes(4).
    const node_count_offset: usize = 25;
    const edge_count_offset: usize = 26;
    const original_node_count = storage[node_count_offset];
    storage[node_count_offset] = district_contract.max_navigation_nodes + 1;
    var hostile_nodes = Reader{ .bytes = storage[0..sink.cursor] };
    try std.testing.expectError(
        error.DistrictNavigationNodeCapacityExceeded,
        decodeDistrictBuild(&hostile_nodes),
    );
    storage[node_count_offset] = original_node_count;

    storage[edge_count_offset] = district_contract.max_navigation_edges + 1;
    var hostile_edges = Reader{ .bytes = storage[0..sink.cursor] };
    try std.testing.expectError(
        error.DistrictNavigationEdgeCapacityExceeded,
        decodeDistrictBuild(&hostile_edges),
    );

    inline for (std.meta.tags(district_contract.BuildValidationFailure)) |failure| {
        try std.testing.expectEqual(
            failure,
            try decodeBuildValidationFailure(encodeBuildValidationFailure(failure)),
        );
    }
}

test "district command normalization strips and rematerializes presentation assets" {
    const coord = district_contract.ChunkCoord{ .x = 2, .z = -1 };
    const first = districts.Command{ .request_load = .{
        .request_id = 9,
        .coord = coord,
        .assets = .{ .scene = .{ .index = 3, .generation = 7 } },
    } };
    const second = districts.Command{ .request_load = .{
        .request_id = 9,
        .coord = coord,
        .assets = .{ .scene = .{ .index = 50, .generation = 99 } },
    } };
    const normalized_first = NormalizedDistrictCommand.fromFeature(first);
    const normalized_second = NormalizedDistrictCommand.fromFeature(second);
    try std.testing.expect(std.meta.eql(normalized_first, normalized_second));

    const replay_assets = districts.Assets{ .scene = .{ .index = 4, .generation = 12 } };
    const rematerialized = normalized_first.toFeature(replay_assets);
    switch (rematerialized) {
        .request_load => |request| {
            try std.testing.expectEqual(@as(u64, 9), request.request_id);
            try std.testing.expect(district_contract.ChunkCoord.eql(coord, request.coord));
            try std.testing.expectEqual(replay_assets.scene, request.assets.scene);
        },
        else => return error.UnexpectedDistrictCommand,
    }
}

test "exhaustive command and district ingress envelope round trips byte identically" {
    var fixture = try testCapture();
    const expected = fixture.view();
    const bytes = try encode(std.testing.allocator, expected);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &magic, bytes[0..magic.len]);
    try std.testing.expectEqual(format_version, getU16(bytes, 8));
    try std.testing.expectEqual(schema_cohort, getU16(bytes, 10));
    try std.testing.expectEqual(@as(u64, bytes.len), getU64(bytes, 16));
    try std.testing.expectEqual(@as(u32, fixture.bootstrap.len), getU32(bytes, 40));
    try std.testing.expectEqual(@as(u32, fixture.commands.len), getU32(bytes, 44));
    try std.testing.expectEqual(@as(u32, fixture.ingress.len), getU32(bytes, 48));
    try std.testing.expectEqual(@as(u32, fixture.digests.len), getU32(bytes, 52));

    var parsed = try parseCompatible(std.testing.allocator, bytes, fixture.content);
    defer parsed.deinit();
    try expectCaptureEqual(expected, parsed.view());

    const reencoded = try encode(std.testing.allocator, parsed.view());
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, bytes, reencoded);
}

test "replay cursor preserves commands-before-ingress order and finds exact divergence" {
    var fixture = try testCapture();
    var cursor = try ReplayCursor.init(fixture.view());
    try std.testing.expectEqual(@as(usize, 6), cursor.bootstrap().len);

    const tick_one = cursor.next() orelse return error.MissingReplayTick;
    try std.testing.expectEqual(@as(u64, 1), tick_one.tick_index);
    try std.testing.expectEqual(@as(usize, 0), tick_one.commands.len);
    try std.testing.expectEqual(@as(usize, 0), tick_one.district_ingress.len);
    const tick_two = cursor.next() orelse return error.MissingReplayTick;
    try std.testing.expectEqual(@as(usize, 5), tick_two.commands.len);
    try std.testing.expectEqual(@as(usize, 1), tick_two.district_ingress.len);
    const tick_three = cursor.next() orelse return error.MissingReplayTick;
    try std.testing.expectEqual(@as(usize, 5), tick_three.commands.len);
    try std.testing.expectEqual(@as(usize, 1), tick_three.district_ingress.len);
    const tick_four = cursor.next() orelse return error.MissingReplayTick;
    try std.testing.expectEqual(@as(usize, 8), tick_four.commands.len);
    try std.testing.expectEqual(@as(usize, 1), tick_four.district_ingress.len);
    try std.testing.expect(cursor.next() == null);

    var altered = tick_two.expected_digests;
    altered.vehicle[0] ^= 0xff;
    const divergence = firstDivergence(tick_two.expected_digests, altered) orelse
        return error.MissingReplayDivergence;
    try std.testing.expectEqual(DivergenceKind.category_digest, divergence.kind);
    try std.testing.expectEqual(@as(?DigestCategory, .vehicle), divergence.category);
    try std.testing.expectEqual(@as(u64, 2), divergence.tick_index);
    try std.testing.expect(firstDivergence(tick_one.expected_digests, tick_one.expected_digests) == null);

    var altered_interaction = tick_four.expected_digests;
    altered_interaction.interaction[0] ^= 0xff;
    const interaction_divergence = firstDivergence(
        tick_four.expected_digests,
        altered_interaction,
    ) orelse return error.MissingReplayDivergence;
    try std.testing.expectEqual(
        @as(?DigestCategory, .interaction),
        interaction_divergence.category,
    );

    var altered_npc = tick_four.expected_digests;
    altered_npc.npc[0] ^= 0xff;
    const npc_divergence = firstDivergence(
        tick_four.expected_digests,
        altered_npc,
    ) orelse return error.MissingReplayDivergence;
    try std.testing.expectEqual(@as(?DigestCategory, .npc), npc_divergence.category);
}

test "bounded recorder keeps immutable first incomplete reason and serializes partial evidence" {
    const world = try testWorldConfig();
    const content = try testContentCohort();
    var recorder = try Recorder.init(std.testing.allocator, world, content, .{
        .max_commands = 1,
    });
    defer recorder.deinit();

    try std.testing.expectEqual(RecordResult.recorded, recorder.recordBootstrap(.{
        .crate = .{ .spawn = .{ .request_id = 1, .pose = .{} } },
    }));
    try std.testing.expectEqual(RecordResult.recorded, recorder.recordCommand(2, .{
        .character = .{ .spawn = .{ .request_id = 2, .position = .{ 0, 0, 0 } } },
    }));
    try std.testing.expectEqual(RecordResult.capture_incomplete, recorder.recordCommand(2, .{
        .vehicle = .{ .spawn = .{ .request_id = 3 } },
    }));
    try std.testing.expectEqual(@as(?IncompleteReason, .command_capacity), recorder.incompleteReason());
    recorder.markIncomplete(.authority_failed);
    try std.testing.expectEqual(@as(?IncompleteReason, .command_capacity), recorder.incompleteReason());

    const bytes = try recorder.encode(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?IncompleteReason, .command_capacity), parsed.incomplete_reason);
    try std.testing.expectError(error.IncompleteCapture, ReplayCursor.init(parsed.view()));
}

test "recorder reserves every bounded list during cold admission" {
    const world = try testWorldConfig();
    const content = try testContentCohort();
    const limits = Limits{
        .max_bootstrap = 2,
        .max_commands = 3,
        .max_ingress = 4,
        .max_digests = 5,
    };
    var recorder = try Recorder.init(std.testing.allocator, world, content, limits);
    defer recorder.deinit();

    try std.testing.expectEqual(@as(usize, limits.max_bootstrap), recorder.bootstrap_commands.capacity);
    try std.testing.expectEqual(@as(usize, limits.max_commands), recorder.commands.capacity);
    try std.testing.expectEqual(@as(usize, limits.max_ingress), recorder.district_ingress.capacity);
    try std.testing.expectEqual(@as(usize, limits.max_digests), recorder.tick_digests.capacity);

    // If any record path attempts a late allocation, this allocator fails it.
    // Restoring the admission allocator before teardown keeps ownership exact.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const admission_allocator = recorder.allocator;
    recorder.allocator = failing.allocator();
    defer recorder.allocator = admission_allocator;

    try std.testing.expectEqual(RecordResult.recorded, recorder.recordBootstrap(.{
        .crate = .{ .spawn = .{ .request_id = 1, .pose = .{} } },
    }));
    try std.testing.expectEqual(RecordResult.recorded, recorder.recordCommand(2, .{
        .character = .{ .spawn = .{ .request_id = 2, .position = .{ 0, 0, 0 } } },
    }));
    try std.testing.expectEqual(RecordResult.recorded, recorder.recordDistrictCompletion(2, .{
        .cancelled = .{ .coord = .{ .x = 0, .z = 0 }, .generation = 1 },
    }));
    try std.testing.expectEqual(
        RecordResult.recorded,
        recorder.recordTickDigests(testTickDigests(1, 0x77)),
    );
    try std.testing.expect(!failing.has_induced_failure);

    var cold_failure = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(error.OutOfMemory, Recorder.init(
        cold_failure.allocator(),
        world,
        content,
        .{
            .max_bootstrap = 0,
            .max_commands = 1,
            .max_ingress = 0,
            .max_digests = 0,
        },
    ));
    try std.testing.expect(cold_failure.has_induced_failure);
}

test "every incomplete reason has a stable envelope tag" {
    var fixture = try testCapture();
    inline for (std.enums.values(IncompleteReason)) |reason| {
        var view = fixture.view();
        view.incomplete_reason = reason;
        const bytes = try encode(std.testing.allocator, view);
        defer std.testing.allocator.free(bytes);
        var parsed = try parse(std.testing.allocator, bytes);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(?IncompleteReason, reason), parsed.incomplete_reason);
    }
}

test "parser rejects corrupt integrity and truncation at envelope boundaries" {
    var fixture = try testCapture();
    const bytes = try encode(std.testing.allocator, fixture.view());
    defer std.testing.allocator.free(bytes);

    const corrupt = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt);
    corrupt[header_size + 7] ^= 0x80;
    try std.testing.expectError(
        error.ReplayIntegrityMismatch,
        parse(std.testing.allocator, corrupt),
    );

    for ([_]usize{ 0, magic.len - 1, header_size - 1, header_size + integrity_size - 1 }) |end| {
        try std.testing.expectError(
            error.TruncatedReplayEnvelope,
            parse(std.testing.allocator, bytes[0..end]),
        );
    }
    try std.testing.expectError(
        error.ReplaySizeMismatch,
        parse(std.testing.allocator, bytes[0 .. bytes.len - integrity_size - 1]),
    );
    try std.testing.expectError(
        error.ReplaySizeMismatch,
        parse(std.testing.allocator, bytes[0 .. bytes.len - 1]),
    );
}

test "parser preflights oversized and malformed headers before typed allocation" {
    const oversized = try std.testing.allocator.alloc(u8, max_envelope_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(
        error.ReplayEnvelopeTooLarge,
        parse(std.testing.allocator, oversized),
    );

    var fixture = try testCapture();
    const canonical = try encode(std.testing.allocator, fixture.view());
    defer std.testing.allocator.free(canonical);

    const bad_magic = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_magic);
    bad_magic[0] ^= 1;
    try std.testing.expectError(error.BadReplayMagic, parse(std.testing.allocator, bad_magic));

    const bad_version = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_version);
    putU16(bad_version, 8, format_version + 1);
    try std.testing.expectError(
        error.UnsupportedReplayFormat,
        parse(std.testing.allocator, bad_version),
    );

    const bad_schema = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_schema);
    putU16(bad_schema, 10, schema_cohort + 1);
    try std.testing.expectError(
        error.IncompatibleReplaySchema,
        parse(std.testing.allocator, bad_schema),
    );

    const bad_size = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_size);
    putU64(bad_size, 16, canonical.len + 1);
    try std.testing.expectError(error.ReplaySizeMismatch, parse(std.testing.allocator, bad_size));

    const reserved = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(reserved);
    putU32(reserved, 60, 1);
    refreshIntegrity(reserved);
    try std.testing.expectError(error.InvalidReplayHeader, parse(std.testing.allocator, reserved));

    const bad_flags = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_flags);
    bad_flags[57] = 0x80;
    refreshIntegrity(bad_flags);
    try std.testing.expectError(error.InvalidReplayHeader, parse(std.testing.allocator, bad_flags));

    const bad_incomplete = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(bad_incomplete);
    bad_incomplete[56] = 0xff;
    bad_incomplete[57] = 1;
    refreshIntegrity(bad_incomplete);
    try std.testing.expectError(
        error.InvalidIncompleteReason,
        parse(std.testing.allocator, bad_incomplete),
    );

    const excessive_count = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(excessive_count);
    putU32(excessive_count, 44, max_recorded_commands + 1);
    refreshIntegrity(excessive_count);
    try std.testing.expectError(
        error.ReplayRecordCapacityExceeded,
        parse(std.testing.allocator, excessive_count),
    );

    // A forged count can remain inside the configured limit while claiming
    // far more typed records than the payload could contain. Reject it from
    // the minimum encoded size before allocating any record arrays.
    const impossible_count = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(impossible_count);
    putU32(impossible_count, 44, max_recorded_commands);
    refreshIntegrity(impossible_count);
    try std.testing.expectError(
        error.TruncatedReplayPayload,
        parse(std.testing.allocator, impossible_count),
    );
}

test "parser rejects invalid tags domains and noncanonical float bytes after integrity" {
    var fixture = try testCapture();
    const canonical = try encode(std.testing.allocator, fixture.view());
    defer std.testing.allocator.free(canonical);
    const fixed_payload_size = try encodedFixedPayloadSize(
        current_simulation_cohort,
        fixture.world,
        fixture.content,
    );
    const first_command_offset = header_size + fixed_payload_size +
        try encodedRecordedCommandSize(fixture.bootstrap[0]);

    const invalid_tag = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(invalid_tag);
    invalid_tag[first_command_offset + 8] = 0xff;
    refreshIntegrity(invalid_tag);
    try std.testing.expectError(
        error.InvalidCommandSource,
        parse(std.testing.allocator, invalid_tag),
    );

    const invalid_domain = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(invalid_domain);
    invalid_domain[header_size] ^= 1;
    refreshIntegrity(invalid_domain);
    try std.testing.expectError(
        error.InvalidReplayDomain,
        parse(std.testing.allocator, invalid_domain),
    );

    var simulation_sizer = SizeSink{};
    try encodeSimulationCohort(&simulation_sizer, current_simulation_cohort);
    const fixed_delta_offset = header_size + simulation_sizer.size +
        "world-config-v3".len + 8;
    const negative_zero = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(negative_zero);
    putU32(negative_zero, fixed_delta_offset, 0x8000_0000);
    refreshIntegrity(negative_zero);
    try std.testing.expectError(
        error.NonCanonicalFloat,
        parse(std.testing.allocator, negative_zero),
    );
}

test "parser rejects unordered command records and trailing payload" {
    var fixture = try testCapture();
    const canonical = try encode(std.testing.allocator, fixture.view());
    defer std.testing.allocator.free(canonical);
    const fixed_payload_size = try encodedFixedPayloadSize(
        current_simulation_cohort,
        fixture.world,
        fixture.content,
    );
    var seventh_command_offset = header_size + fixed_payload_size;
    for (fixture.bootstrap) |record| {
        seventh_command_offset += try encodedRecordedCommandSize(record);
    }
    for (fixture.commands[0..6]) |record| {
        seventh_command_offset += try encodedRecordedCommandSize(record);
    }

    const unordered = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(unordered);
    putU64(unordered, seventh_command_offset, 2);
    refreshIntegrity(unordered);
    try std.testing.expectError(
        error.UnorderedCommands,
        parse(std.testing.allocator, unordered),
    );

    const old_payload_end = canonical.len - integrity_size;
    const trailing = try std.testing.allocator.alloc(u8, canonical.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..old_payload_end], canonical[0..old_payload_end]);
    trailing[old_payload_end] = 0xcc;
    @memset(trailing[old_payload_end + 1 ..], 0);
    putU64(trailing, 16, trailing.len);
    putU64(trailing, 32, getU64(canonical, 32) + 1);
    refreshIntegrity(trailing);
    try std.testing.expectError(
        error.TrailingReplayPayload,
        parse(std.testing.allocator, trailing),
    );
}

test "complete capture validation rejects missing digests out-of-range records and unordered views" {
    var fixture = try testCapture();
    var missing = fixture.view();
    missing.tick_digests = &.{};
    try std.testing.expectError(error.MissingTickDigests, missing.validate(.{}));

    var beyond_commands = fixture.commands;
    beyond_commands[beyond_commands.len - 1].eligible_tick = 5;
    var beyond = fixture.view();
    beyond.commands = &beyond_commands;
    try std.testing.expectError(error.RecordBeyondFinalTick, beyond.validate(.{}));

    var unordered_commands = fixture.commands;
    unordered_commands[6].eligible_tick = 2;
    var unordered = fixture.view();
    unordered.commands = &unordered_commands;
    try std.testing.expectError(error.UnorderedCommands, unordered.validate(.{}));

    var duplicate_ingress = fixture.ingress;
    duplicate_ingress[2].consumption_tick = 3;
    var duplicate = fixture.view();
    duplicate.district_ingress = &duplicate_ingress;
    try std.testing.expectError(error.UnorderedIngress, duplicate.validate(.{}));

    var bad_ingress = fixture.ingress;
    bad_ingress[0].completion.ready.ticket.coord.x += 1;
    var invalid = fixture.view();
    invalid.district_ingress = &bad_ingress;
    try std.testing.expectError(
        error.DistrictCompletionCoordinateMismatch,
        invalid.validate(.{}),
    );
}

test "compatible parser rejects changed simulation and content cohorts" {
    var fixture = try testCapture();
    var changed_simulation = fixture.view();
    changed_simulation.simulation_cohort.jolt_worker_count += 1;
    const simulation_bytes = try encode(std.testing.allocator, changed_simulation);
    defer std.testing.allocator.free(simulation_bytes);
    try std.testing.expectError(
        error.IncompatibleSimulationCohort,
        parseCompatible(std.testing.allocator, simulation_bytes, fixture.content),
    );

    const canonical = try encode(std.testing.allocator, fixture.view());
    defer std.testing.allocator.free(canonical);
    var changed_content = fixture.content;
    changed_content.integrity_digest[0] ^= 1;
    try std.testing.expectError(
        error.IncompatibleContentCohort,
        parseCompatible(std.testing.allocator, canonical, changed_content),
    );
}

test "recorder enforces byte capacity independently of record counts" {
    const world = try testWorldConfig();
    const content = try testContentCohort();
    const base_size = header_size + integrity_size + try encodedFixedPayloadSize(
        current_simulation_cohort,
        world,
        content,
    );
    var recorder = try Recorder.init(std.testing.allocator, world, content, .{
        .max_file_bytes = base_size,
    });
    defer recorder.deinit();
    try std.testing.expectEqual(RecordResult.capture_incomplete, recorder.recordBootstrap(.{
        .crate = .{ .spawn = .{ .request_id = 1, .pose = .{} } },
    }));
    try std.testing.expectEqual(
        @as(?IncompleteReason, .envelope_capacity),
        recorder.incompleteReason(),
    );
}
