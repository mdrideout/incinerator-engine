const std = @import("std");

const FlecsDebugMode = enum {
    sanitize,
    debug,
    depends_on_build,
    none,
};

const FlecsPrecision = enum { fp32, fp64 };

pub const cohort = struct {
    pub const zflecs_revision = "9c2771cf0cae508db622821bb7deac6e9370a9de";
    pub const joltc_zig_revision = "c7ff571d475ae4ef26e327e6ffcd81f158e93d97";
    pub const joltc_revision = "52d8c98df523f449eb3e01b1060a0fde052970d1";
    pub const jolt_revision = "23dadd0e603f1b321142d4c74df07fce85064989";
    pub const gns_revision = "fa489fd2cb0fc86ef2503e330935d3eb03a6a064";
    pub const jolt_no_exceptions = true;
    pub const jolt_object_layer_bits: u8 = 32;
    pub const jolt_cross_platform_deterministic = false;
    pub const jolt_worker_count: i32 = 1;
    pub const jolt_max_jobs: u32 = 2_048;
    pub const jolt_max_barriers: u32 = 8;
    pub const jolt_max_bodies: u32 = 10_240;
    pub const jolt_max_virtual_characters: usize = 128;
    pub const flecs_float_bits: u8 = 32;
    pub const flecs_time_bits: u8 = 32;
    pub const flecs_use_os_alloc = true;
    pub const flecs_hi_component_id: u16 = 256;
    pub const flecs_hi_id_record_id: u16 = 1_024;
};

/// Modules shared by the visual sandbox and cold authority products.
///
/// Keeping this graph in one place prevents a host from silently compiling a
/// different feature/contract composition. Visual-only adapters are added by
/// the client build after this graph is constructed.
pub const Graph = struct {
    contracts: *std.Build.Module,
    content: *std.Build.Module,
    headless_content_manifest: *std.Build.Module,
    engine: *std.Build.Module,
    simulation_cohort_options: *std.Build.Module,
    network_cohort_options: *std.Build.Module,
    jolt_c: *std.Build.Module,
    jolt_physics: *std.Build.Module,
    crate_contract: *std.Build.Module,
    crates: *std.Build.Module,
    driver_contract: *std.Build.Module,
    district_contract: *std.Build.Module,
    sandbox_district_recipe: *std.Build.Module,
    navigation_contract: *std.Build.Module,
    navigation_planner: *std.Build.Module,
    sandbox_navigation: *std.Build.Module,
    interaction_contract: *std.Build.Module,
    character_contract: *std.Build.Module,
    character: *std.Build.Module,
    vehicle_contract: *std.Build.Module,
    vehicle: *std.Build.Module,
    district_worker_contract: *std.Build.Module,
    district_worker: *std.Build.Module,
    district_replay_loader: *std.Build.Module,
    district_feature_contract: *std.Build.Module,
    district: *std.Build.Module,
    npc_contract: *std.Build.Module,
    npc_snapshot_validation: *std.Build.Module,
    npc: *std.Build.Module,
    vitals_contract: *std.Build.Module,
    vitals: *std.Build.Module,
    npc_encounter_contract: *std.Build.Module,
    npc_encounter: *std.Build.Module,
    ranged_combat_contract: *std.Build.Module,
    ranged_combat: *std.Build.Module,
    population_contract: *std.Build.Module,
    sandbox_population_catalog: *std.Build.Module,
    sandbox_population: *std.Build.Module,
    interaction_feature_contract: *std.Build.Module,
    interaction: *std.Build.Module,
    session_authority_diagnostics: *std.Build.Module,
    developer_controls: *std.Build.Module,
    developer_diagnostics: *std.Build.Module,
    sandbox_authoring: *std.Build.Module,
    sandbox_save: *std.Build.Module,
    save_slots: *std.Build.Module,
    sandbox_replay: *std.Build.Module,
    sandbox_diagnostics_contract: *std.Build.Module,
    simulation_diagnostics: *std.Build.Module,
    sandbox_host_contracts: *std.Build.Module,
    simulation_snapshot: *std.Build.Module,
    sandbox_simulation: *std.Build.Module,
    session_budgets: *std.Build.Module,
    session_identity: *std.Build.Module,
    session_protocol: *std.Build.Module,
    combat_presentation: *std.Build.Module,
    gameplay_admission: *std.Build.Module,
    snapshot_source: *std.Build.Module,
    session_transport_policy: *std.Build.Module,
    reconnect_policy: *std.Build.Module,
    client_clock: *std.Build.Module,
    session_prediction: *std.Build.Module,
    vehicle_prediction: *std.Build.Module,
    impaired_link: *std.Build.Module,
    session_local_link: *std.Build.Module,
    replicated_world: *std.Build.Module,
    session_client: *std.Build.Module,
    local_solo_session: *std.Build.Module,
    session_authority: *std.Build.Module,
};

pub const CohortVerification = struct {
    run: *std.Build.Step.Run,
    tests: *std.Build.Step.Run,
};

pub fn addCohortVerification(b: *std.Build) CohortVerification {
    const tool = b.addExecutable(.{
        .name = "dependency_cohort",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build/dependency_cohort.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(b.path("build.zig.zon"));
    run.addFileArg(b.path("third_party/joltc-zig/build.zig.zon"));
    run.addFileArg(b.path("third_party/joltc-zig/README.md"));
    run.addArgs(&.{
        cohort.zflecs_revision,
        cohort.joltc_zig_revision,
        cohort.joltc_revision,
        cohort.jolt_revision,
        cohort.gns_revision,
    });
    const verify_step = b.step(
        "verify-dependency-cohort",
        "Verify replay cohort identities match exact dependency pins",
    );
    verify_step.dependOn(&run.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = tool.root_module }));
    const test_step = b.step(
        "test-dependency-cohort",
        "Run dependency cohort manifest verifier tests",
    );
    test_step.dependOn(&tests.step);
    return .{ .run = run, .tests = tests };
}

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Graph {
    const contracts = b.createModule(.{
        .root_source_file = b.path("src/engine/contracts.zig"),
        .target = target,
        .optimize = optimize,
    });
    const content = b.createModule(.{
        .root_source_file = b.path("src/content/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const headless_manifest_files = b.addWriteFiles();
    _ = headless_manifest_files.addCopyFile(
        b.path("config/headless-content.json"),
        "headless-content.json",
    );
    const headless_manifest_source = headless_manifest_files.add(
        "headless_content_manifest.zig",
        "pub const bytes = @embedFile(\"headless-content.json\");\n",
    );
    const headless_content_manifest = b.createModule(.{
        .root_source_file = headless_manifest_source,
        .target = target,
        .optimize = optimize,
    });
    const engine = b.addModule("incinerator_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "engine_contracts", .module = contracts }},
    });

    // One generated source of truth for values serialized into replay cohort
    // headers and enforced by the concrete physics adapter. Product code does
    // not parse package manifests or import the Jolt implementation to learn
    // these build-selected identities and ceilings.
    const cohort_options = b.addOptions();
    cohort_options.addOption(
        []const u8,
        "zflecs_revision",
        cohort.zflecs_revision,
    );
    cohort_options.addOption(
        []const u8,
        "joltc_zig_revision",
        cohort.joltc_zig_revision,
    );
    cohort_options.addOption(
        []const u8,
        "joltc_revision",
        cohort.joltc_revision,
    );
    cohort_options.addOption(
        []const u8,
        "jolt_revision",
        cohort.jolt_revision,
    );
    cohort_options.addOption(bool, "jolt_no_exceptions", cohort.jolt_no_exceptions);
    cohort_options.addOption(u8, "jolt_object_layer_bits", cohort.jolt_object_layer_bits);
    cohort_options.addOption(
        bool,
        "jolt_cross_platform_deterministic",
        cohort.jolt_cross_platform_deterministic,
    );
    cohort_options.addOption(i32, "jolt_worker_count", cohort.jolt_worker_count);
    cohort_options.addOption(u32, "jolt_max_jobs", cohort.jolt_max_jobs);
    cohort_options.addOption(u32, "jolt_max_barriers", cohort.jolt_max_barriers);
    cohort_options.addOption(u32, "jolt_max_bodies", cohort.jolt_max_bodies);
    cohort_options.addOption(
        usize,
        "jolt_max_virtual_characters",
        cohort.jolt_max_virtual_characters,
    );
    cohort_options.addOption(u8, "flecs_float_bits", cohort.flecs_float_bits);
    cohort_options.addOption(u8, "flecs_time_bits", cohort.flecs_time_bits);
    cohort_options.addOption(bool, "flecs_use_os_alloc", cohort.flecs_use_os_alloc);
    cohort_options.addOption(
        u16,
        "flecs_hi_component_id",
        cohort.flecs_hi_component_id,
    );
    cohort_options.addOption(
        u16,
        "flecs_hi_id_record_id",
        cohort.flecs_hi_id_record_id,
    );
    const simulation_cohort_options = cohort_options.createModule();
    const network_options = b.addOptions();
    network_options.addOption(u16, "protocol_revision", 17);
    network_options.addOption(u64, "build_cohort", networkBuildCohort());
    network_options.addOption(
        u64,
        "content_cohort",
        std.hash.Wyhash.hash(0x494e_434e, "s15-four-district-content-v1"),
    );
    const network_cohort_options = network_options.createModule();

    const flecs_debug_mode: FlecsDebugMode = if (optimize == .Debug) .sanitize else .none;
    const flecs_float_precision: FlecsPrecision = switch (cohort.flecs_float_bits) {
        32 => .fp32,
        64 => .fp64,
        else => @panic("unsupported Flecs float width in simulation cohort"),
    };
    const flecs_time_precision: FlecsPrecision = switch (cohort.flecs_time_bits) {
        32 => .fp32,
        64 => .fp64,
        else => @panic("unsupported Flecs time width in simulation cohort"),
    };
    const zflecs = b.dependency("zflecs", .{
        .target = target,
        .optimize = optimize,
        .shared = false,
        .debug_mode = flecs_debug_mode,
        .debug_info = false,
        .float_t = flecs_float_precision,
        .ftime_t = flecs_time_precision,
        .accurate_counters = false,
        .disable_counters = false,
        .soft_assert = false,
        .keep_assert = false,
        .default_to_uncached_queries = false,
        .no_always_inline = false,
        .custom_build = .whitelist,
        // The engine owns scheduling and diagnostics. Flecs is private entity/
        // component storage; the default OS API implementation is its only
        // compiled addon.
        .toggle_os_api_impl_addon = true,
        .low_footprint = false,
        .use_os_alloc = cohort.flecs_use_os_alloc,
        .hi_component_id = cohort.flecs_hi_component_id,
        .hi_id_record_id = cohort.flecs_hi_id_record_id,
        .sparse_page_bits = 6,
        .entity_page_bits = 10,
        .id_desc_max = 32,
        .event_desc_max = 8,
        .variable_count_max = 64,
        .term_count_max = 32,
        .term_arg_count_max = 16,
        .query_variable_count_max = 64,
        .query_scope_nesting_max = 8,
        .dag_depth_max = 128,
    });
    engine.addImport("zflecs", zflecs.module("root"));

    const joltc = b.dependency("joltc", .{
        .target = target,
        .optimize = optimize,
        .no_exceptions = cohort.jolt_no_exceptions,
        .object_layer_bits = cohort.jolt_object_layer_bits,
        .cross_platform_deterministic = cohort.jolt_cross_platform_deterministic,
    });
    const jolt_c = b.createModule(.{
        .root_source_file = b.path("src/adapters/physics/jolt_c.zig"),
        .target = target,
        .optimize = optimize,
    });
    jolt_c.linkLibrary(joltc.artifact("joltc"));
    const jolt_physics = b.createModule(.{
        .root_source_file = b.path("src/physics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "jolt_c", .module = jolt_c },
            .{ .name = "simulation_cohort_options", .module = simulation_cohort_options },
        },
    });

    const crate_contract = b.createModule(.{
        .root_source_file = b.path("src/features/crates/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "engine_contracts", .module = contracts }},
    });
    const crates = b.createModule(.{
        .root_source_file = b.path("src/features/crates/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "crate_contract", .module = crate_contract },
        },
    });
    const driver_contract = b.createModule(.{
        .root_source_file = b.path("src/features/driver_contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "incinerator_engine", .module = engine }},
    });
    const district_contract = b.createModule(.{
        .root_source_file = b.path("src/features/district_contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "engine_contracts", .module = contracts }},
    });
    const navigation_contract = b.createModule(.{
        .root_source_file = b.path("src/features/navigation_contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "district_contract", .module = district_contract }},
    });
    const sandbox_district_recipe = b.createModule(.{
        .root_source_file = b.path("src/sandbox/district_recipe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "navigation_contract", .module = navigation_contract },
        },
    });
    const navigation_planner = b.createModule(.{
        .root_source_file = b.path("src/features/navigation_planner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "navigation_contract",
            .module = navigation_contract,
        }},
    });
    const sandbox_navigation = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_navigation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "navigation_contract", .module = navigation_contract },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
        },
    });
    const interaction_contract = b.createModule(.{
        .root_source_file = b.path("src/features/interaction_contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "district_contract", .module = district_contract },
        },
    });
    const character_contract = b.createModule(.{
        .root_source_file = b.path("src/features/character/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "driver_contract", .module = driver_contract },
        },
    });
    const character = b.createModule(.{
        .root_source_file = b.path("src/features/character/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "character_contract", .module = character_contract },
            .{ .name = "driver_contract", .module = driver_contract },
            .{ .name = "interaction_contract", .module = interaction_contract },
        },
    });
    const vehicle_contract = b.createModule(.{
        .root_source_file = b.path("src/features/vehicle/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "engine_contracts", .module = contracts }},
    });
    const vehicle = b.createModule(.{
        .root_source_file = b.path("src/features/vehicle/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "vehicle_contract", .module = vehicle_contract },
            .{ .name = "driver_contract", .module = driver_contract },
        },
    });
    const district_worker_contract = b.createModule(.{
        .root_source_file = b.path("src/district_worker_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const district_worker = b.createModule(.{
        .root_source_file = b.path("src/district_worker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "district_worker_contract", .module = district_worker_contract },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
        },
    });
    const district_replay_loader = b.createModule(.{
        .root_source_file = b.path("src/hosts/district_replay_loader.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "district_worker_contract", .module = district_worker_contract },
            .{ .name = "district_worker", .module = district_worker },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
        },
    });
    const district_feature_contract = b.createModule(.{
        .root_source_file = b.path("src/features/district/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "district_contract", .module = district_contract },
        },
    });
    const district = b.createModule(.{
        .root_source_file = b.path("src/features/district/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "district_feature_contract", .module = district_feature_contract },
            .{ .name = "interaction_contract", .module = interaction_contract },
            .{ .name = "navigation_contract", .module = navigation_contract },
        },
    });
    const npc_contract = b.createModule(.{
        .root_source_file = b.path("src/features/npc/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "navigation_contract", .module = navigation_contract },
            .{ .name = "navigation_planner", .module = navigation_planner },
        },
    });
    const npc_snapshot_validation = b.createModule(.{
        .root_source_file = b.path("src/features/npc/snapshot_validation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "navigation_contract", .module = navigation_contract },
            .{ .name = "navigation_planner", .module = navigation_planner },
            .{ .name = "npc_contract", .module = npc_contract },
        },
    });
    const npc = b.createModule(.{
        .root_source_file = b.path("src/features/npc/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "navigation_contract", .module = navigation_contract },
            .{ .name = "navigation_planner", .module = navigation_planner },
            .{ .name = "npc_snapshot_validation", .module = npc_snapshot_validation },
        },
    });
    const vitals_contract = b.createModule(.{
        .root_source_file = b.path("src/features/vitals/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "engine_contracts", .module = contracts }},
    });
    const vitals = b.createModule(.{
        .root_source_file = b.path("src/features/vitals/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "vitals_contract", .module = vitals_contract },
        },
    });
    const npc_encounter_contract = b.createModule(.{
        .root_source_file = b.path("src/features/npc_encounter/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "vitals_contract", .module = vitals_contract },
        },
    });
    const npc_encounter = b.createModule(.{
        .root_source_file = b.path("src/features/npc_encounter/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract },
            .{ .name = "vitals_contract", .module = vitals_contract },
        },
    });
    const ranged_combat_contract = b.createModule(.{
        .root_source_file = b.path("src/features/ranged_combat/contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ranged_combat = b.createModule(.{
        .root_source_file = b.path("src/features/ranged_combat/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "ranged_combat_contract",
            .module = ranged_combat_contract,
        }},
    });
    const population_contract = b.createModule(.{
        .root_source_file = b.path("src/features/population/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "npc_contract", .module = npc_contract },
        },
    });
    const sandbox_population_catalog = b.createModule(.{
        .root_source_file = b.path("src/sandbox/population_catalog.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "population_contract", .module = population_contract },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
        },
    });
    const sandbox_population = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_population.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "population_contract", .module = population_contract },
            .{ .name = "sandbox_population_catalog", .module = sandbox_population_catalog },
        },
    });
    const interaction_feature_contract = b.createModule(.{
        .root_source_file = b.path("src/features/interaction/contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "district_contract", .module = district_contract },
        },
    });
    const interaction = b.createModule(.{
        .root_source_file = b.path("src/features/interaction/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract },
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "interaction_contract", .module = interaction_contract },
        },
    });
    const developer_controls = b.createModule(.{
        .root_source_file = b.path("src/hosts/developer_controls.zig"),
        .target = target,
        .optimize = optimize,
    });
    const session_authority_diagnostics = b.createModule(.{
        .root_source_file = b.path("src/session/authority_diagnostics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "incinerator_engine", .module = engine }},
    });
    const developer_diagnostics = b.createModule(.{
        .root_source_file = b.path("src/hosts/developer_diagnostics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "developer_controls", .module = developer_controls },
            .{ .name = "session_authority_diagnostics", .module = session_authority_diagnostics },
        },
    });
    const sandbox_authoring = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_authoring.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "crate_contract", .module = crate_contract },
        },
    });
    const sandbox_save = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_save.zig"),
        .target = target,
        .optimize = optimize,
    });
    const save_slots = b.createModule(.{
        .root_source_file = b.path("src/adapters/storage/save_slots.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sandbox_diagnostics_contract = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_diagnostics_contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "crate_contract", .module = crate_contract },
            .{ .name = "character_contract", .module = character_contract },
            .{ .name = "vehicle_contract", .module = vehicle_contract },
            .{ .name = "district_feature_contract", .module = district_feature_contract },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "vitals_contract", .module = vitals_contract },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract },
            .{ .name = "population_contract", .module = population_contract },
            .{ .name = "district_worker_contract", .module = district_worker_contract },
        },
    });
    const simulation_diagnostics = b.createModule(.{
        .root_source_file = b.path("src/hosts/simulation_diagnostics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "sandbox_diagnostics_contract",
            .module = sandbox_diagnostics_contract,
        }},
    });
    const sandbox_host_contracts = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_host_contracts.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "crate_contract", .module = crate_contract },
            .{ .name = "character_contract", .module = character_contract },
            .{ .name = "vehicle_contract", .module = vehicle_contract },
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract },
        },
    });
    const sandbox_replay = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_replay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "crate_contract", .module = crate_contract },
            .{ .name = "character_contract", .module = character_contract },
            .{ .name = "vehicle_contract", .module = vehicle_contract },
            .{ .name = "district_feature_contract", .module = district_feature_contract },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "vitals_contract", .module = vitals_contract },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract },
            .{ .name = "population_contract", .module = population_contract },
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts },
            .{ .name = "content", .module = content },
            .{ .name = "simulation_cohort_options", .module = simulation_cohort_options },
        },
    });
    const simulation_snapshot = b.createModule(.{
        .root_source_file = b.path("src/hosts/simulation_snapshot.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "crate_contract", .module = crate_contract },
            .{ .name = "character_contract", .module = character_contract },
            .{ .name = "vehicle_contract", .module = vehicle_contract },
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "district_feature_contract", .module = district_feature_contract },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "vitals_contract", .module = vitals_contract },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract },
            .{ .name = "npc_snapshot_validation", .module = npc_snapshot_validation },
            .{ .name = "population_contract", .module = population_contract },
            .{ .name = "sandbox_population_catalog", .module = sandbox_population_catalog },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
            .{ .name = "sandbox_navigation", .module = sandbox_navigation },
            .{ .name = "sandbox_replay", .module = sandbox_replay },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts },
            .{ .name = "simulation_cohort_options", .module = simulation_cohort_options },
        },
    });
    const sandbox_simulation = b.createModule(.{
        .root_source_file = b.path("src/hosts/simulation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "crate_contract", .module = crate_contract },
            .{ .name = "character_contract", .module = character_contract },
            .{ .name = "vehicle_contract", .module = vehicle_contract },
            .{ .name = "crate_feature", .module = crates },
            .{ .name = "character_feature", .module = character },
            .{ .name = "vehicle_feature", .module = vehicle },
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "district_feature_contract", .module = district_feature_contract },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
            .{ .name = "sandbox_navigation", .module = sandbox_navigation },
            .{ .name = "district_feature", .module = district },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract },
            .{ .name = "interaction_feature", .module = interaction },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "npc_feature", .module = npc },
            .{ .name = "vitals_contract", .module = vitals_contract },
            .{ .name = "vitals_feature", .module = vitals },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract },
            .{ .name = "npc_encounter_feature", .module = npc_encounter },
            .{ .name = "population_contract", .module = population_contract },
            .{ .name = "sandbox_population_catalog", .module = sandbox_population_catalog },
            .{ .name = "sandbox_population", .module = sandbox_population },
            .{ .name = "district_worker_contract", .module = district_worker_contract },
            .{ .name = "district_replay_loader", .module = district_replay_loader },
            .{ .name = "jolt_physics", .module = jolt_physics },
            .{ .name = "sandbox_replay", .module = sandbox_replay },
            .{ .name = "simulation_snapshot", .module = simulation_snapshot },
            .{ .name = "simulation_diagnostics", .module = simulation_diagnostics },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts },
        },
    });
    const session_budgets = b.createModule(.{
        .root_source_file = b.path("src/session/budgets.zig"),
        .target = target,
        .optimize = optimize,
    });
    const session_identity = b.createModule(.{
        .root_source_file = b.path("src/session/identity.zig"),
        .target = target,
        .optimize = optimize,
    });
    const session_protocol = b.createModule(.{
        .root_source_file = b.path("src/session/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
            .{ .name = "network_cohort_options", .module = network_cohort_options },
        },
    });
    const combat_presentation = b.createModule(.{
        .root_source_file = b.path("src/session/combat_presentation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
            .{ .name = "session_protocol", .module = session_protocol },
        },
    });
    const gameplay_admission = b.createModule(.{
        .root_source_file = b.path("src/session/gameplay_admission.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
        },
    });
    const snapshot_source = b.createModule(.{
        .root_source_file = b.path("src/session/snapshot_source.zig"),
        .target = target,
        .optimize = optimize,
    });
    const session_transport_policy = b.createModule(.{
        .root_source_file = b.path("src/session/transport_policy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "session_protocol", .module = session_protocol }},
    });
    const reconnect_policy = b.createModule(.{
        .root_source_file = b.path("src/session/reconnect_policy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const client_clock = b.createModule(.{
        .root_source_file = b.path("src/session/client_clock.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "session_budgets", .module = session_budgets }},
    });
    const session_prediction = b.createModule(.{
        .root_source_file = b.path("src/session/prediction.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
            .{ .name = "session_protocol", .module = session_protocol },
        },
    });
    const vehicle_prediction = b.createModule(.{
        .root_source_file = b.path("src/session/vehicle_prediction.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
            .{ .name = "session_protocol", .module = session_protocol },
        },
    });
    const impaired_link = b.createModule(.{
        .root_source_file = b.path("src/session/impaired_link.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_protocol", .module = session_protocol },
            .{ .name = "session_transport_policy", .module = session_transport_policy },
        },
    });
    const session_local_link = b.createModule(.{
        .root_source_file = b.path("src/session/local_link.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_protocol", .module = session_protocol },
        },
    });
    const replicated_world = b.createModule(.{
        .root_source_file = b.path("src/session/replicated_world.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts },
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
            .{ .name = "session_protocol", .module = session_protocol },
        },
    });
    const session_client = b.createModule(.{
        .root_source_file = b.path("src/session/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
            .{ .name = "session_protocol", .module = session_protocol },
            .{ .name = "replicated_world", .module = replicated_world },
            .{ .name = "session_prediction", .module = session_prediction },
            .{ .name = "vehicle_prediction", .module = vehicle_prediction },
        },
    });
    const local_solo_session = b.createModule(.{
        .root_source_file = b.path("src/session/local_solo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts },
            .{ .name = "crate_contract", .module = crate_contract },
            .{ .name = "character_contract", .module = character_contract },
            .{ .name = "vehicle_contract", .module = vehicle_contract },
            .{ .name = "district_feature_contract", .module = district_feature_contract },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "population_contract", .module = population_contract },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract },
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
            .{ .name = "session_protocol", .module = session_protocol },
            .{ .name = "combat_presentation", .module = combat_presentation },
            .{ .name = "snapshot_source", .module = snapshot_source },
            .{ .name = "session_local_link", .module = session_local_link },
            .{ .name = "session_client", .module = session_client },
            .{ .name = "replicated_world", .module = replicated_world },
            .{ .name = "session_authority_diagnostics", .module = session_authority_diagnostics },
            .{ .name = "sandbox_replay", .module = sandbox_replay },
        },
    });
    const session_authority = b.createModule(.{
        .root_source_file = b.path("src/session/authority.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = engine },
            .{ .name = "sandbox_simulation", .module = sandbox_simulation },
            .{ .name = "simulation_snapshot", .module = simulation_snapshot },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts },
            .{ .name = "crate_contract", .module = crate_contract },
            .{ .name = "character_contract", .module = character_contract },
            .{ .name = "vehicle_contract", .module = vehicle_contract },
            .{ .name = "district_contract", .module = district_contract },
            .{ .name = "district_feature_contract", .module = district_feature_contract },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract },
            .{ .name = "npc_contract", .module = npc_contract },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract },
            .{ .name = "population_contract", .module = population_contract },
            .{ .name = "sandbox_population_catalog", .module = sandbox_population_catalog },
            .{ .name = "vitals_contract", .module = vitals_contract },
            .{ .name = "ranged_combat_contract", .module = ranged_combat_contract },
            .{ .name = "ranged_combat", .module = ranged_combat },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract },
            .{ .name = "session_budgets", .module = session_budgets },
            .{ .name = "session_identity", .module = session_identity },
            .{ .name = "session_protocol", .module = session_protocol },
            .{ .name = "gameplay_admission", .module = gameplay_admission },
            .{ .name = "snapshot_source", .module = snapshot_source },
            .{ .name = "session_transport_policy", .module = session_transport_policy },
            .{ .name = "session_authority_diagnostics", .module = session_authority_diagnostics },
            .{ .name = "sandbox_replay", .module = sandbox_replay },
        },
    });
    local_solo_session.addImport("session_authority", session_authority);

    return .{
        .contracts = contracts,
        .content = content,
        .headless_content_manifest = headless_content_manifest,
        .engine = engine,
        .simulation_cohort_options = simulation_cohort_options,
        .network_cohort_options = network_cohort_options,
        .jolt_c = jolt_c,
        .jolt_physics = jolt_physics,
        .crate_contract = crate_contract,
        .crates = crates,
        .driver_contract = driver_contract,
        .district_contract = district_contract,
        .sandbox_district_recipe = sandbox_district_recipe,
        .navigation_contract = navigation_contract,
        .navigation_planner = navigation_planner,
        .sandbox_navigation = sandbox_navigation,
        .interaction_contract = interaction_contract,
        .character_contract = character_contract,
        .character = character,
        .vehicle_contract = vehicle_contract,
        .vehicle = vehicle,
        .district_worker_contract = district_worker_contract,
        .district_worker = district_worker,
        .district_replay_loader = district_replay_loader,
        .district_feature_contract = district_feature_contract,
        .district = district,
        .npc_contract = npc_contract,
        .npc_snapshot_validation = npc_snapshot_validation,
        .npc = npc,
        .vitals_contract = vitals_contract,
        .vitals = vitals,
        .npc_encounter_contract = npc_encounter_contract,
        .npc_encounter = npc_encounter,
        .ranged_combat_contract = ranged_combat_contract,
        .ranged_combat = ranged_combat,
        .population_contract = population_contract,
        .sandbox_population_catalog = sandbox_population_catalog,
        .sandbox_population = sandbox_population,
        .interaction_feature_contract = interaction_feature_contract,
        .interaction = interaction,
        .session_authority_diagnostics = session_authority_diagnostics,
        .developer_controls = developer_controls,
        .developer_diagnostics = developer_diagnostics,
        .sandbox_authoring = sandbox_authoring,
        .sandbox_save = sandbox_save,
        .save_slots = save_slots,
        .sandbox_replay = sandbox_replay,
        .sandbox_diagnostics_contract = sandbox_diagnostics_contract,
        .simulation_diagnostics = simulation_diagnostics,
        .sandbox_host_contracts = sandbox_host_contracts,
        .simulation_snapshot = simulation_snapshot,
        .sandbox_simulation = sandbox_simulation,
        .session_budgets = session_budgets,
        .session_identity = session_identity,
        .session_protocol = session_protocol,
        .combat_presentation = combat_presentation,
        .gameplay_admission = gameplay_admission,
        .snapshot_source = snapshot_source,
        .session_transport_policy = session_transport_policy,
        .reconnect_policy = reconnect_policy,
        .client_clock = client_clock,
        .session_prediction = session_prediction,
        .vehicle_prediction = vehicle_prediction,
        .impaired_link = impaired_link,
        .session_local_link = session_local_link,
        .replicated_world = replicated_world,
        .session_client = session_client,
        .local_solo_session = local_solo_session,
        .session_authority = session_authority,
    };
}

fn networkBuildCohort() u64 {
    var fingerprint: u64 = 0x4d50_3200_0000_0001;
    inline for (.{
        "zig-0.16.0",
        cohort.zflecs_revision,
        cohort.joltc_zig_revision,
        cohort.joltc_revision,
        cohort.jolt_revision,
        cohort.gns_revision,
        "authority-60hz",
        "snapshot-20hz",
        "protocol-v16",
    }) |part| fingerprint = std.hash.Wyhash.hash(fingerprint, part);
    return fingerprint;
}
