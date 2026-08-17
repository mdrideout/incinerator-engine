const std = @import("std");
const headless_product = @import("tools/build/headless_product.zig");
const gamenetworking_sockets = @import("tools/build/gamenetworking_sockets.zig");
const macos = @import("tools/build/macos.zig");
const simulation_graph = @import("tools/build/simulation_graph.zig");
const zgui_sdl3_gpu = @import("tools/build/zgui_sdl3_gpu.zig");

const CookedContent = struct {
    step: *std.Build.Step,
    output: std.Build.LazyPath,
};

const CookDependency = struct {
    semantic_id: []const u8,
    bundle: std.Build.LazyPath,
};

const SourceIdentity = struct {
    revision: []const u8,
    dirty: bool,
    dirty_fingerprint: []const u8,
};

fn sourceIdentity(b: *std.Build) SourceIdentity {
    var code: u8 = 0;
    const revision_output = b.runAllowFail(
        &.{ "git", "rev-parse", "--verify", "HEAD" },
        &code,
        .ignore,
    ) catch return .{
        .revision = "source-package",
        .dirty = false,
        .dirty_fingerprint = "unavailable",
    };
    if (code != 0) return .{
        .revision = "source-package",
        .dirty = false,
        .dirty_fingerprint = "unavailable",
    };
    const revision = std.mem.trim(u8, revision_output, " \t\r\n");
    code = 0;
    const status_output = b.runAllowFail(
        &.{ "git", "status", "--porcelain=v1", "--untracked-files=normal" },
        &code,
        .ignore,
    ) catch return .{
        .revision = revision,
        .dirty = true,
        .dirty_fingerprint = "status-unavailable",
    };
    if (code != 0) return .{
        .revision = revision,
        .dirty = true,
        .dirty_fingerprint = "status-unavailable",
    };
    const status = std.mem.trim(u8, status_output, " \t\r\n");
    if (status.len == 0) return .{
        .revision = revision,
        .dirty = false,
        .dirty_fingerprint = "clean",
    };
    code = 0;
    const fingerprint_input = b.runAllowFail(
        &.{
            "sh",
            "-c",
            "git diff --binary --no-ext-diff HEAD -- . && " ++
                "git ls-files --others --exclude-standard | " ++
                "while IFS= read -r path; do " ++
                "printf '%s\\n' \"$path\"; git hash-object -- \"$path\"; done",
        },
        &code,
        .ignore,
    ) catch return .{
        .revision = revision,
        .dirty = true,
        .dirty_fingerprint = "content-unavailable",
    };
    if (code != 0) return .{
        .revision = revision,
        .dirty = true,
        .dirty_fingerprint = "content-unavailable",
    };
    var fingerprint: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fingerprint_input, &fingerprint, .{});
    return .{
        .revision = revision,
        .dirty = true,
        .dirty_fingerprint = b.fmt(
            "sha256-{s}",
            .{&std.fmt.bytesToHex(fingerprint, .lower)},
        ),
    };
}

fn runContentCooker(
    b: *std.Build,
    cooker: *std.Build.Step.Compile,
    source_path: []const u8,
    provenance_path: []const u8,
    output_name: []const u8,
    bundle_key: []const u8,
    coord_x: i32,
    coord_z: i32,
    dependencies: []const CookDependency,
) CookedContent {
    const run = b.addRunArtifact(cooker);
    run.addFileArg(b.path(source_path));
    run.addFileArg(b.path(provenance_path));
    const output = run.addOutputFileArg(output_name);
    run.addArg(bundle_key);
    run.addArg(b.fmt("{d}", .{coord_x}));
    run.addArg(b.fmt("{d}", .{coord_z}));
    for (dependencies) |dependency| {
        run.addArg(dependency.semantic_id);
        run.addFileArg(dependency.bundle);
    }
    return .{ .step = &run.step, .output = output };
}

fn runContentCatalogCooker(
    b: *std.Build,
    cooker: *std.Build.Step.Compile,
    spec_path: []const u8,
    output_name: []const u8,
    bundles: []const std.Build.LazyPath,
) CookedContent {
    const run = b.addRunArtifact(cooker);
    run.addFileArg(b.path(spec_path));
    const output = run.addOutputFileArg(output_name);
    for (bundles) |bundle| run.addFileArg(bundle);
    return .{ .step = &run.step, .output = output };
}

const Product = enum {
    client,
    headless,
};

fn addClientImport(
    product: *std.Build.Step.Compile,
    validation: *std.Build.Step.Compile,
    name: []const u8,
    module: *std.Build.Module,
) void {
    product.root_module.addImport(name, module);
    validation.root_module.addImport(name, module);
}

fn linkClientLibrary(
    product: *std.Build.Step.Compile,
    validation: *std.Build.Step.Compile,
    library: *std.Build.Step.Compile,
) void {
    product.root_module.linkLibrary(library);
    validation.root_module.linkLibrary(library);
}

fn addValidationCommand(
    b: *std.Build,
    install_step: *std.Build.Step,
    argv: []const []const u8,
) *std.Build.Step.Run {
    const command = b.addSystemCommand(argv);
    command.step.dependOn(install_step);
    return command;
}

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    macos.requireToolchain();
    // The active product contract is deliberately narrow. Keeping the target
    // option is useful for selecting an SDK/version floor, but every product
    // rejects non-Apple-Silicon macOS targets at graph construction time.
    const target = b.standardTargetOptions(.{});
    macos.requireAppleSilicon(b, target);
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const product = b.option(
        Product,
        "product",
        "Build product (client is the default; headless is the cold Apple Silicon authority product)",
    ) orelse .client;
    if (product == .headless) {
        headless_product.build(b, target, optimize);
        return;
    }

    const glslc_path = b.option(
        []const u8,
        "glslc",
        "Path to the host glslc executable",
    ) orelse "glslc";
    const spirv_cross_path = b.option(
        []const u8,
        "spirv-cross",
        "Path to the host spirv-cross executable",
    ) orelse "spirv-cross";
    // ---------------------------------------------------------
    // Editor Build Option
    // ---------------------------------------------------------
    // The editor (ImGui debug UI and tools) is enabled by default in Debug
    // builds but can be explicitly disabled. In Release builds, it defaults to
    // off but can be explicitly enabled for profiling/debugging release builds.
    //
    // Usage:
    //   zig build                    # Debug with editor
    //   zig build -Deditor=false     # Debug without editor
    //   zig build -Doptimize=ReleaseFast              # Release without editor
    //   zig build -Doptimize=ReleaseFast -Deditor=true # Release with editor
    const default_editor_enabled = optimize == .Debug;
    const editor_enabled = b.option(
        bool,
        "editor",
        "Enable the editor UI (ImGui tools). Defaults to true in Debug, false in Release.",
    ) orelse default_editor_enabled;
    const incident_capture_enabled = b.option(
        bool,
        "incident-capture",
        "Enable bounded local human-test incident bundles. Defaults to true in Debug.",
    ) orelse (optimize == .Debug);

    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    const graph = simulation_graph.create(b, target, optimize);
    const gns = gamenetworking_sockets.create(b, optimize) orelse return;
    const cohort_verification = simulation_graph.addCohortVerification(b);
    const contracts_module = graph.contracts;
    const content_module = graph.content;
    const mod = graph.engine;
    const jolt_physics_module = graph.jolt_physics;
    const crate_contract_module = graph.crate_contract;
    const crate_feature_module = graph.crates;
    const driver_contract_module = graph.driver_contract;
    const district_contract_module = graph.district_contract;
    const sandbox_district_recipe_module = graph.sandbox_district_recipe;
    const navigation_contract_module = graph.navigation_contract;
    const navigation_planner_module = graph.navigation_planner;
    const sandbox_navigation_module = graph.sandbox_navigation;
    const interaction_contract_module = graph.interaction_contract;
    const character_contract_module = graph.character_contract;
    const character_feature_module = graph.character;
    const vehicle_contract_module = graph.vehicle_contract;
    const vehicle_feature_module = graph.vehicle;
    const district_worker_contract_module = graph.district_worker_contract;
    const district_worker_module = graph.district_worker;
    const district_replay_loader_module = graph.district_replay_loader;
    const district_feature_contract_module = graph.district_feature_contract;
    const district_feature_module = graph.district;
    const npc_contract_module = graph.npc_contract;
    const npc_feature_module = graph.npc;
    const vitals_contract_module = graph.vitals_contract;
    const vitals_feature_module = graph.vitals;
    const npc_encounter_contract_module = graph.npc_encounter_contract;
    const npc_encounter_feature_module = graph.npc_encounter;
    const population_contract_module = graph.population_contract;
    const sandbox_population_catalog_module = graph.sandbox_population_catalog;
    const sandbox_population_module = graph.sandbox_population;
    const interaction_feature_contract_module = graph.interaction_feature_contract;
    const interaction_feature_module = graph.interaction;
    const session_authority_diagnostics_module = graph.session_authority_diagnostics;
    const developer_controls_module = graph.developer_controls;
    const developer_diagnostics_module = graph.developer_diagnostics;
    const sandbox_authoring_module = graph.sandbox_authoring;
    const sandbox_save_module = graph.sandbox_save;
    const save_slots_module = graph.save_slots;
    const sandbox_replay_module = graph.sandbox_replay;
    const sandbox_diagnostics_contract_module = graph.sandbox_diagnostics_contract;
    const simulation_snapshot_module = graph.simulation_snapshot;
    const sandbox_simulation_module = graph.sandbox_simulation;
    const session_budgets_module = graph.session_budgets;
    const session_identity_module = graph.session_identity;
    const session_protocol_module = graph.session_protocol;
    const combat_presentation_module = graph.combat_presentation;
    const gameplay_admission_module = graph.gameplay_admission;
    const snapshot_source_module = graph.snapshot_source;
    const session_transport_policy_module = graph.session_transport_policy;
    const reconnect_policy_module = graph.reconnect_policy;
    const client_clock_module = graph.client_clock;
    const session_prediction_module = graph.session_prediction;
    const vehicle_prediction_module = graph.vehicle_prediction;
    const impaired_link_module = graph.impaired_link;
    const session_local_link_module = graph.session_local_link;
    const replicated_world_module = graph.replicated_world;
    const session_client_module = graph.session_client;
    const local_solo_session_module = graph.local_solo_session;
    const session_authority_module = graph.session_authority;
    const session_room_module = b.createModule(.{
        .root_source_file = b.path("src/session/room.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_identity", .module = session_identity_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
        },
    });
    const room_coordinator_module = b.createModule(.{
        .root_source_file = b.path("src/session/room_coordinator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_identity", .module = session_identity_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_room", .module = session_room_module },
        },
    });
    const room_ticket_module = b.createModule(.{
        .root_source_file = b.path("src/session/room_ticket.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_identity", .module = session_identity_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_room", .module = session_room_module },
        },
    });
    const gns_direct_module = b.createModule(.{
        .root_source_file = b.path("src/adapters/transport/gns_direct.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "session_budgets", .module = session_budgets_module }},
    });
    gns_direct_module.addIncludePath(b.path("src/adapters/transport"));
    gns_direct_module.addIncludePath(gns.include);

    const content_host_module = b.createModule(.{
        .root_source_file = b.path("src/content/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const district_contract_host_module = b.createModule(.{
        .root_source_file = b.path("src/features/district_contract.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "engine_contracts", .module = contracts_module }},
    });
    const navigation_contract_host_module = b.createModule(.{
        .root_source_file = b.path("src/features/navigation_contract.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{
            .name = "district_contract",
            .module = district_contract_host_module,
        }},
    });
    const sandbox_district_recipe_host_module = b.createModule(.{
        .root_source_file = b.path("src/sandbox/district_recipe.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "district_contract", .module = district_contract_host_module },
            .{ .name = "navigation_contract", .module = navigation_contract_host_module },
        },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    // ---------------------------------------------------------
    // Build Options Module
    // ---------------------------------------------------------
    // Creates an importable module containing build-time configuration.
    // Code can access these via: const options = @import("build_options");
    const options = b.addOptions();
    const source_identity = sourceIdentity(b);
    options.addOption(bool, "editor_enabled", editor_enabled);
    options.addOption(bool, "validation_mode", false);
    options.addOption(bool, "incident_capture_enabled", incident_capture_enabled);
    options.addOption([]const u8, "source_revision", source_identity.revision);
    options.addOption(bool, "source_dirty", source_identity.dirty);
    options.addOption([]const u8, "source_dirty_fingerprint", source_identity.dirty_fingerprint);

    const validation_options = b.addOptions();
    validation_options.addOption(bool, "editor_enabled", editor_enabled);
    validation_options.addOption(bool, "validation_mode", true);
    validation_options.addOption(bool, "incident_capture_enabled", false);
    validation_options.addOption([]const u8, "source_revision", source_identity.revision);
    validation_options.addOption(bool, "source_dirty", source_identity.dirty);
    validation_options.addOption([]const u8, "source_dirty_fingerprint", source_identity.dirty_fingerprint);

    const exe = b.addExecutable(.{
        .name = "incinerator_engine",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "incinerator_engine" is the name you will use in your source code to
                // import this module (e.g. `@import("incinerator_engine")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "incinerator_engine", .module = mod },
                // Build options module - provides compile-time access to build flags
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    const validation_exe = b.addExecutable(.{
        .name = "incinerator_validation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "incinerator_engine", .module = mod },
                .{ .name = "build_options", .module = validation_options.createModule() },
            },
        }),
    });
    // NR-0001's macOS adapter is present only in graphical products. Cold
    // authority, replay, measurement, and server graphs never acquire Core ML.
    for ([_]*std.Build.Step.Compile{ exe, validation_exe }) |graphical| {
        graphical.root_module.addCSourceFiles(.{
            .files = &.{"src/adapters/neural_rendering/macos.m"},
            .flags = &.{"-fobjc-arc"},
            .language = .objective_c,
        });
        graphical.root_module.link_libc = true;
        graphical.root_module.linkFramework("Foundation", .{});
        graphical.root_module.linkFramework("CoreML", .{});
    }
    addClientImport(exe, validation_exe, "content", content_module);
    addClientImport(exe, validation_exe, "engine_contracts", contracts_module);
    addClientImport(exe, validation_exe, "session_protocol", session_protocol_module);
    const sandbox_host_contracts_module = graph.sandbox_host_contracts;
    addClientImport(
        exe,
        validation_exe,
        "sandbox_host_contracts",
        sandbox_host_contracts_module,
    );
    const sandbox_invocation_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_invocation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "content", .module = content_module },
            .{ .name = "save_slots", .module = save_slots_module },
        },
    });
    addClientImport(
        exe,
        validation_exe,
        "sandbox_invocation",
        sandbox_invocation_module,
    );
    const sandbox_persistence_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_persistence.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_save", .module = sandbox_save_module },
            .{ .name = "save_slots", .module = save_slots_module },
            .{ .name = "snapshot_source", .module = graph.snapshot_source },
        },
    });
    addClientImport(
        exe,
        validation_exe,
        "sandbox_persistence",
        sandbox_persistence_module,
    );

    // ---------------------------------------------------------
    // SDL3 (castholm/SDL)
    // ---------------------------------------------------------
    const sdl_dep = b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
    }) orelse return;
    const sdl_lib = sdl_dep.artifact("SDL3");
    linkClientLibrary(exe, validation_exe, sdl_lib);

    const district_gpu_registry_module = b.createModule(.{
        .root_source_file = b.path("src/district_gpu_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    district_gpu_registry_module.addImport("incinerator_engine", mod);
    district_gpu_registry_module.linkLibrary(sdl_lib);
    const district_scene_adapter_module = b.createModule(.{
        .root_source_file = b.path("src/district_scene_adapter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "content", .module = content_module },
            .{ .name = "incinerator_engine", .module = mod },
        },
    });
    district_scene_adapter_module.linkLibrary(sdl_lib);

    const district_presentation_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/district_presentation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts_module },
            .{ .name = "session_budgets", .module = graph.session_budgets },
        },
    });
    addClientImport(
        exe,
        validation_exe,
        "district_presentation",
        district_presentation_module,
    );

    // ---------------------------------------------------------
    // ImGui (zgui) debug UI
    // ---------------------------------------------------------
    // zgui wraps Dear ImGui for immediate-mode debug UI.
    // We use the SDL3 GPU backend to integrate with our existing renderer.
    var editor_gui_module: ?*std.Build.Module = null;
    if (editor_enabled) {
        const zgui = b.lazyDependency("zgui", .{
            .target = target,
            .optimize = optimize,
            .shared = false,
            .with_implot = false,
            .with_gizmo = false,
            .with_node_editor = false,
            .with_te = false,
            .with_freetype = false,
            .with_knobs = false,
            .use_wchar32 = false,
            .use_32bit_draw_idx = false,
            .disable_obsolete = true,
            // The engine owns the backend compilation below so it can use the
            // same SDL 3.4.12 headers as the runtime library. Upstream zgui's
            // sdl3_gpu option currently pulls an independent SDL 3.2 snapshot.
            .backend = .no_backend,
        }) orelse return;
        const editor_gui = zgui_sdl3_gpu.build(b, zgui, sdl_dep, target, optimize);
        editor_gui_module = editor_gui.module;
        addClientImport(exe, validation_exe, "zgui", editor_gui.module);
        linkClientLibrary(exe, validation_exe, editor_gui.library);
    }

    // ---------------------------------------------------------
    // Math (zmath)
    // ---------------------------------------------------------
    const zmath = b.lazyDependency("zmath", .{
        .target = target,
        .optimize = optimize,
        .enable_cross_platform_determinism = false,
    }) orelse return;
    addClientImport(exe, validation_exe, "zmath", zmath.module("root"));

    // Source glTF decoding exists only in this host cooker. Shipped runtime
    // content code imports the renderer-neutral codec/explicit-root reader and
    // never links zmesh, zstbi, SDL, or a source-format parser.
    const host_zmesh = b.lazyDependency("zmesh", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .shape_use_32bit_indices = true,
        .shared = false,
    }) orelse return;
    const host_zstbi = b.lazyDependency("zstbi", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) orelse return;
    const content_cooker = b.addExecutable(.{
        .name = "incinerator_content_cooker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/content_cooker.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "content", .module = content_host_module },
                .{ .name = "district_contract", .module = district_contract_host_module },
                .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_host_module },
                .{ .name = "zmesh", .module = host_zmesh.module("root") },
                .{ .name = "zstbi", .module = host_zstbi.module("root") },
            },
        }),
    });
    content_cooker.root_module.linkLibrary(host_zmesh.artifact("zmesh"));

    const cooked_fixture = runContentCooker(
        b,
        content_cooker,
        "fixtures/s3_district/district.gltf",
        "fixtures/s3_district/PROVENANCE.md",
        "s3_fixture.icdb",
        "district/s3_fixture",
        0,
        0,
        &.{},
    );
    const cooked_fixture_repeat = runContentCooker(
        b,
        content_cooker,
        "fixtures/s3_district/district.gltf",
        "fixtures/s3_district/PROVENANCE.md",
        "s3_fixture_repeat.icdb",
        "district/s3_fixture",
        0,
        0,
        &.{},
    );
    const cooked_east = runContentCooker(
        b,
        content_cooker,
        "fixtures/s6_east/district.gltf",
        "fixtures/s6_east/PROVENANCE.md",
        "s6_east.icdb",
        "district/s6_east",
        1,
        0,
        &.{.{
            .semantic_id = "district.west",
            .bundle = cooked_fixture.output,
        }},
    );
    const cooked_east_repeat = runContentCooker(
        b,
        content_cooker,
        "fixtures/s6_east/district.gltf",
        "fixtures/s6_east/PROVENANCE.md",
        "s6_east_repeat.icdb",
        "district/s6_east",
        1,
        0,
        &.{.{
            .semantic_id = "district.west",
            .bundle = cooked_fixture_repeat.output,
        }},
    );
    const cooked_s12_west = runContentCooker(
        b,
        content_cooker,
        "fixtures/s12_world_west/district.gltf",
        "fixtures/s12_world_west/PROVENANCE.md",
        "s12_world_west.icdb",
        "district/s12_world_west",
        0,
        0,
        &.{},
    );
    const cooked_s12_east = runContentCooker(
        b,
        content_cooker,
        "fixtures/s12_world_east/district.gltf",
        "fixtures/s12_world_east/PROVENANCE.md",
        "s12_world_east.icdb",
        "district/s12_world_east",
        1,
        0,
        &.{.{
            .semantic_id = "district.west",
            .bundle = cooked_s12_west.output,
        }},
    );
    const cooked_s12_west_repeat = runContentCooker(
        b,
        content_cooker,
        "fixtures/s12_world_west/district.gltf",
        "fixtures/s12_world_west/PROVENANCE.md",
        "s12_world_west_repeat.icdb",
        "district/s12_world_west",
        0,
        0,
        &.{},
    );
    const cooked_s12_east_repeat = runContentCooker(
        b,
        content_cooker,
        "fixtures/s12_world_east/district.gltf",
        "fixtures/s12_world_east/PROVENANCE.md",
        "s12_world_east_repeat.icdb",
        "district/s12_world_east",
        1,
        0,
        &.{.{
            .semantic_id = "district.west",
            .bundle = cooked_s12_west_repeat.output,
        }},
    );
    const content_catalog_cooker = b.addExecutable(.{
        .name = "incinerator_content_catalog_cooker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/content_catalog_cooker.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "content", .module = content_host_module },
                .{ .name = "district_contract", .module = district_contract_host_module },
                .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_host_module },
            },
        }),
    });
    const cooked_s12_catalog = runContentCatalogCooker(
        b,
        content_catalog_cooker,
        "fixtures/s12_world_catalog/catalog.txt",
        "s12_catalog.icat",
        &.{ cooked_s12_west.output, cooked_s12_east.output },
    );
    const cooked_s12_catalog_repeat = runContentCatalogCooker(
        b,
        content_catalog_cooker,
        "fixtures/s12_world_catalog/catalog.txt",
        "s12_catalog_repeat.icat",
        &.{ cooked_s12_west_repeat.output, cooked_s12_east_repeat.output },
    );
    const cook_content_step = b.step(
        "cook-content",
        "Cook the two self-authored district fixtures and declared dependency closure",
    );
    cook_content_step.dependOn(cooked_s12_catalog.step);
    const install_cooked_fixture = b.addInstallFile(
        cooked_fixture.output,
        "share/incinerator/content/district/s3_fixture.icdb",
    );
    const install_fixture_provenance = b.addInstallFile(
        b.path("fixtures/s3_district/PROVENANCE.md"),
        "share/incinerator/content/district/s3_fixture.PROVENANCE.md",
    );
    const install_cooked_east = b.addInstallFile(
        cooked_east.output,
        "share/incinerator/content/district/s6_east.icdb",
    );
    const install_cooked_s12_west = b.addInstallFile(
        cooked_s12_west.output,
        "share/incinerator/content/district/s12_world_west.icdb",
    );
    const install_s12_west_provenance = b.addInstallFile(
        b.path("fixtures/s12_world_west/PROVENANCE.md"),
        "share/incinerator/content/district/s12_world_west.PROVENANCE.md",
    );
    const install_cooked_s12_east = b.addInstallFile(
        cooked_s12_east.output,
        "share/incinerator/content/district/s12_world_east.icdb",
    );
    const install_s12_east_provenance = b.addInstallFile(
        b.path("fixtures/s12_world_east/PROVENANCE.md"),
        "share/incinerator/content/district/s12_world_east.PROVENANCE.md",
    );
    const install_east_provenance = b.addInstallFile(
        b.path("fixtures/s6_east/PROVENANCE.md"),
        "share/incinerator/content/district/s6_east.PROVENANCE.md",
    );
    const install_cooked_catalog = b.addInstallFile(
        cooked_s12_catalog.output,
        "share/incinerator/content/district/catalog.icat",
    );
    b.getInstallStep().dependOn(&install_cooked_fixture.step);
    b.getInstallStep().dependOn(&install_fixture_provenance.step);
    b.getInstallStep().dependOn(&install_cooked_east.step);
    b.getInstallStep().dependOn(&install_east_provenance.step);
    b.getInstallStep().dependOn(&install_cooked_s12_west.step);
    b.getInstallStep().dependOn(&install_s12_west_provenance.step);
    b.getInstallStep().dependOn(&install_cooked_s12_east.step);
    b.getInstallStep().dependOn(&install_s12_east_provenance.step);
    b.getInstallStep().dependOn(&install_cooked_catalog.step);

    const content_tests = b.addTest(.{ .root_module = content_host_module });
    const run_content_tests = b.addRunArtifact(content_tests);
    const content_test_step = b.step(
        "test-content",
        "Run cooked bundle, explicit-root loader, and async worker tests",
    );
    content_test_step.dependOn(&run_content_tests.step);

    const content_bundle_verify = b.addExecutable(.{
        .name = "content_bundle_verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/content_bundle_verify.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "content", .module = content_host_module },
                .{ .name = "district_contract", .module = district_contract_module },
                .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_module },
            },
        }),
    });
    const verify_cooked_bundle = b.addRunArtifact(content_bundle_verify);
    verify_cooked_bundle.addFileArg(cooked_fixture.output);
    verify_cooked_bundle.addFileArg(cooked_fixture_repeat.output);
    verify_cooked_bundle.addFileArg(cooked_east.output);
    verify_cooked_bundle.addFileArg(cooked_east_repeat.output);
    const content_cooker_test_step = b.step(
        "test-content-cooker",
        "Prove deterministic glTF cooking and preserved fixture semantics",
    );
    content_cooker_test_step.dependOn(&verify_cooked_bundle.step);
    const content_cooker_tests = b.addTest(.{ .root_module = content_cooker.root_module });
    const run_content_cooker_tests = b.addRunArtifact(content_cooker_tests);
    content_cooker_test_step.dependOn(&run_content_cooker_tests.step);
    const content_catalog_cooker_tests = b.addTest(.{
        .root_module = content_catalog_cooker.root_module,
    });
    const run_content_catalog_cooker_tests = b.addRunArtifact(
        content_catalog_cooker_tests,
    );
    content_cooker_test_step.dependOn(&run_content_catalog_cooker_tests.step);
    const content_catalog_verify = b.addExecutable(.{
        .name = "content_catalog_verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/content_catalog_verify.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "content", .module = content_module },
                .{ .name = "district_contract", .module = district_contract_module },
                .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_module },
                .{ .name = "sandbox_replay", .module = sandbox_replay_module },
            },
        }),
    });
    const verify_cooked_catalog = b.addRunArtifact(content_catalog_verify);
    verify_cooked_catalog.addFileArg(cooked_s12_catalog.output);
    verify_cooked_catalog.addFileArg(cooked_s12_catalog_repeat.output);
    verify_cooked_catalog.addFileArg(cooked_s12_west.output);
    verify_cooked_catalog.addFileArg(cooked_s12_east.output);
    verify_cooked_catalog.addFileArg(b.path("config/headless-content.json"));
    verify_cooked_catalog.addFileArg(b.path("config/headless.example.json"));
    content_cooker_test_step.dependOn(&verify_cooked_catalog.step);

    const content_relocation_test = b.addExecutable(.{
        .name = "content_relocation_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/content_relocation_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "content", .module = content_host_module }},
        }),
    });
    const install_content_relocation_test = b.addInstallArtifact(content_relocation_test, .{
        .dest_dir = .{ .override = .{ .custom = "libexec/incinerator" } },
    });
    const installed_content_relocation_path = b.getInstallPath(
        .{ .custom = "libexec/incinerator" },
        content_relocation_test.out_filename,
    );
    const run_content_relocation = b.addSystemCommand(&.{installed_content_relocation_path});
    run_content_relocation.addArg(b.getInstallPath(.prefix, "share/incinerator/content"));
    run_content_relocation.setCwd(.{ .cwd_relative = "/tmp" });
    run_content_relocation.step.dependOn(&install_cooked_fixture.step);
    run_content_relocation.step.dependOn(&install_fixture_provenance.step);
    run_content_relocation.step.dependOn(&install_content_relocation_test.step);
    const content_relocation_step = b.step(
        "smoke-installed-content",
        "Load installed cooked content from /tmp through an explicit root",
    );
    content_relocation_step.dependOn(&run_content_relocation.step);

    addClientImport(exe, validation_exe, "population_contract", population_contract_module);
    addClientImport(
        exe,
        validation_exe,
        "sandbox_population_catalog",
        sandbox_population_catalog_module,
    );
    addClientImport(exe, validation_exe, "session_budgets", session_budgets_module);
    const sandbox_product_character_lifecycle_module = b.createModule(.{
        .root_source_file = b.path("src/sandbox/product_character_lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts_module },
            .{ .name = "session_identity", .module = session_identity_module },
        },
    });
    addClientImport(
        exe,
        validation_exe,
        "sandbox_product_character_lifecycle",
        sandbox_product_character_lifecycle_module,
    );
    const sandbox_product_population_host_test_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_product_population_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "local_solo_session", .module = local_solo_session_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "population_contract", .module = population_contract_module },
            .{ .name = "sandbox_replay", .module = sandbox_replay_module },
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_module },
        },
    });
    const sandbox_population_catalog_host_test_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_population_catalog_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "jolt_physics", .module = jolt_physics_module },
            .{ .name = "district_contract", .module = district_contract_module },
            .{ .name = "population_contract", .module = population_contract_module },
            .{ .name = "sandbox_population_catalog", .module = sandbox_population_catalog_module },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_module },
        },
    });
    const sandbox_gameplay_scenarios_module = b.createModule(.{
        .root_source_file = b.path("src/sandbox/gameplay_scenarios.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "incinerator_engine", .module = mod }},
    });
    const sandbox_controls_module = b.createModule(.{
        .root_source_file = b.path("src/sandbox_controls.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "sandbox_gameplay_scenarios",
            .module = sandbox_gameplay_scenarios_module,
        }},
    });
    addClientImport(
        exe,
        validation_exe,
        "sandbox_gameplay_scenarios",
        sandbox_gameplay_scenarios_module,
    );
    const developer_profile_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/developer_profile.zig"),
        .target = target,
        .optimize = optimize,
    });
    const developer_visualization_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/developer_visualization.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "engine_contracts", .module = contracts_module }},
    });
    addClientImport(exe, validation_exe, "developer_controls", developer_controls_module);
    addClientImport(
        exe,
        validation_exe,
        "session_authority_diagnostics",
        session_authority_diagnostics_module,
    );
    addClientImport(exe, validation_exe, "developer_diagnostics", developer_diagnostics_module);
    addClientImport(exe, validation_exe, "developer_profile", developer_profile_module);
    addClientImport(
        exe,
        validation_exe,
        "developer_visualization",
        developer_visualization_module,
    );
    addClientImport(exe, validation_exe, "sandbox_authoring", sandbox_authoring_module);
    addClientImport(exe, validation_exe, "sandbox_replay", sandbox_replay_module);
    const district_content_catalog_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/district_content_catalog.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "content", .module = content_module },
            .{ .name = "district_contract", .module = district_contract_module },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_module },
            .{ .name = "sandbox_replay", .module = sandbox_replay_module },
        },
    });
    addClientImport(
        exe,
        validation_exe,
        "district_content_catalog",
        district_content_catalog_module,
    );
    const district_streaming_host_module = b.createModule(.{
        .root_source_file = b.path("src/district_streaming_host_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "content", .module = content_module },
            .{ .name = "district_contract", .module = district_contract_module },
            .{ .name = "district_feature_contract", .module = district_feature_contract_module },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "district_content_catalog", .module = district_content_catalog_module },
            .{ .name = "district_presentation", .module = district_presentation_module },
            .{ .name = "developer_diagnostics", .module = developer_diagnostics_module },
        },
    });
    district_streaming_host_module.linkLibrary(sdl_lib);
    addClientImport(exe, validation_exe, "district_contract", district_contract_module);
    addClientImport(
        exe,
        validation_exe,
        "sandbox_district_recipe",
        sandbox_district_recipe_module,
    );
    addClientImport(
        exe,
        validation_exe,
        "district_feature_contract",
        district_feature_contract_module,
    );
    const content_catalog_relocation_test = b.addExecutable(.{
        .name = "content_catalog_relocation_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/content_catalog_relocation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "content", .module = content_module },
                .{ .name = "district_content_catalog", .module = district_content_catalog_module },
            },
        }),
    });
    const install_content_catalog_relocation_test = b.addInstallArtifact(
        content_catalog_relocation_test,
        .{ .dest_dir = .{ .override = .{ .custom = "libexec/incinerator" } } },
    );
    const installed_content_catalog_relocation_path = b.getInstallPath(
        .{ .custom = "libexec/incinerator" },
        content_catalog_relocation_test.out_filename,
    );
    const run_content_catalog_relocation = b.addSystemCommand(
        &.{installed_content_catalog_relocation_path},
    );
    run_content_catalog_relocation.addArg(
        b.getInstallPath(.prefix, "share/incinerator/content"),
    );
    run_content_catalog_relocation.setCwd(.{ .cwd_relative = "/tmp" });
    run_content_catalog_relocation.step.dependOn(&install_cooked_fixture.step);
    run_content_catalog_relocation.step.dependOn(&install_cooked_east.step);
    run_content_catalog_relocation.step.dependOn(&install_cooked_catalog.step);
    run_content_catalog_relocation.step.dependOn(
        &install_content_catalog_relocation_test.step,
    );
    content_relocation_step.dependOn(&run_content_catalog_relocation.step);
    addClientImport(exe, validation_exe, "local_solo_session", local_solo_session_module);
    addClientImport(exe, validation_exe, "combat_presentation", combat_presentation_module);
    const sandbox_interaction_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_interaction.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract_module },
        },
    });
    addClientImport(exe, validation_exe, "sandbox_interaction", sandbox_interaction_module);

    // ---------------------------------------------------------
    // Shader Compilation (GLSL → target backend format)
    // ---------------------------------------------------------
    // Shader outputs live in the Zig cache and are exposed as a generated
    // module. This makes the exact generated files dependencies of every
    // executable/test compilation that embeds them without mutating `src/`.
    const shaders = buildShaders(b, target, optimize, .{
        .glslc = glslc_path,
        .spirv_cross = spirv_cross_path,
    });
    addClientImport(exe, validation_exe, "shader_assets", shaders.module);
    exe.step.dependOn(shaders.step);
    validation_exe.step.dependOn(shaders.step);

    const physics_debug_gpu_module = b.createModule(.{
        .root_source_file = b.path("src/physics_debug_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts_module },
            .{ .name = "zmath", .module = zmath.module("root") },
            .{ .name = "shader_assets", .module = shaders.module },
        },
    });
    physics_debug_gpu_module.linkLibrary(sdl_lib);

    const sandbox_developer_host_test_module = b.createModule(.{
        .root_source_file = b.path("src/sandbox_developer_host_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "engine_contracts", .module = contracts_module },
            .{ .name = "zmath", .module = zmath.module("root") },
            .{ .name = "shader_assets", .module = shaders.module },
            .{ .name = "developer_controls", .module = developer_controls_module },
            .{ .name = "developer_diagnostics", .module = developer_diagnostics_module },
            .{ .name = "developer_profile", .module = developer_profile_module },
            .{ .name = "developer_visualization", .module = developer_visualization_module },
            .{ .name = "session_authority_diagnostics", .module = session_authority_diagnostics_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "sandbox_replay", .module = sandbox_replay_module },
        },
    });
    if (editor_gui_module) |module| {
        sandbox_developer_host_test_module.addImport("zgui", module);
    }
    sandbox_developer_host_test_module.linkLibrary(sdl_lib);

    const shader_contract_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shader_contract_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shader_reflections", .module = shaders.reflection_module },
                .{ .name = "shader_assets", .module = shaders.validation_module },
            },
        }),
    });
    const run_shader_contract_tests = b.addRunArtifact(shader_contract_tests);
    const shader_test_step = b.step("test-shaders", "Validate SDL GPU shader contracts");
    shader_test_step.dependOn(&run_shader_contract_tests.step);

    const physics_debug_gpu_tests = b.addTest(.{
        .root_module = physics_debug_gpu_module,
    });
    const run_physics_debug_gpu_tests = b.addRunArtifact(physics_debug_gpu_tests);
    const physics_debug_gpu_test_step = b.step(
        "test-physics-debug-gpu",
        "Run persistent bounded SDL GPU physics-overlay tests",
    );
    physics_debug_gpu_test_step.dependOn(&run_physics_debug_gpu_tests.step);

    const mp2_server_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/mp2_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_transport_policy", .module = session_transport_policy_module },
            .{ .name = "session_authority", .module = session_authority_module },
            .{ .name = "gns_direct", .module = gns_direct_module },
        },
    });
    const mp2_server_exe = b.addExecutable(.{
        .name = "incinerator_mp2_server",
        .root_module = mp2_server_module,
    });
    gns.link(mp2_server_exe);

    const mp2_presentation_module = b.createModule(.{
        .root_source_file = b.path("src/mp2_presentation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath.module("root") },
            .{ .name = "shader_assets", .module = shaders.module },
        },
    });
    mp2_presentation_module.linkLibrary(sdl_lib);

    const client_scene_module = b.createModule(.{
        .root_source_file = b.path("src/client_scene.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath.module("root") },
            .{ .name = "engine_contracts", .module = contracts_module },
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "combat_presentation", .module = combat_presentation_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "replicated_world", .module = replicated_world_module },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_module },
            .{ .name = "mp2_presentation", .module = mp2_presentation_module },
        },
    });
    client_scene_module.linkLibrary(sdl_lib);

    const mp2_client_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/mp2_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zmath", .module = zmath.module("root") },
            .{ .name = "shader_assets", .module = shaders.module },
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "replicated_world", .module = replicated_world_module },
            .{ .name = "session_transport_policy", .module = session_transport_policy_module },
            .{ .name = "reconnect_policy", .module = reconnect_policy_module },
            .{ .name = "client_clock", .module = client_clock_module },
            .{ .name = "room_coordinator", .module = room_coordinator_module },
            .{ .name = "room_ticket", .module = room_ticket_module },
            .{ .name = "gns_direct", .module = gns_direct_module },
            .{ .name = "mp2_presentation", .module = mp2_presentation_module },
            .{ .name = "client_scene", .module = client_scene_module },
            .{ .name = "sandbox_gameplay_scenarios", .module = sandbox_gameplay_scenarios_module },
        },
    });
    mp2_client_module.linkLibrary(sdl_lib);
    const mp2_client_exe = b.addExecutable(.{
        .name = "incinerator_mp2_client",
        .root_module = mp2_client_module,
    });
    mp2_client_exe.step.dependOn(shaders.step);
    gns.link(mp2_client_exe);

    const mp6_server_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/mp6_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_identity", .module = session_identity_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_room", .module = session_room_module },
            .{ .name = "room_ticket", .module = room_ticket_module },
            .{ .name = "session_authority", .module = session_authority_module },
            .{ .name = "direct_server", .module = mp2_server_module },
        },
    });
    const mp6_server_exe = b.addExecutable(.{
        .name = "incinerator_mp6_server",
        .root_module = mp6_server_module,
    });

    const mp6_listen_room_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/mp6_listen_room.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_identity", .module = session_identity_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "combat_presentation", .module = combat_presentation_module },
            .{ .name = "session_room", .module = session_room_module },
            .{ .name = "room_coordinator", .module = room_coordinator_module },
            .{ .name = "room_ticket", .module = room_ticket_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_authority", .module = session_authority_module },
            .{ .name = "session_local_link", .module = session_local_link_module },
            .{ .name = "session_transport_policy", .module = session_transport_policy_module },
            .{ .name = "gns_direct", .module = gns_direct_module },
        },
    });
    const mp6_listen_client_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/mp6_listen_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "mp6_listen_room", .module = mp6_listen_room_module },
            .{ .name = "client_scene", .module = client_scene_module },
            .{ .name = "mp2_presentation", .module = mp2_presentation_module },
            .{ .name = "sandbox_gameplay_scenarios", .module = sandbox_gameplay_scenarios_module },
        },
    });
    mp6_listen_client_module.linkLibrary(sdl_lib);
    const mp6_listen_client_exe = b.addExecutable(.{
        .name = "incinerator_mp6_listen",
        .root_module = mp6_listen_client_module,
    });
    mp6_listen_client_exe.step.dependOn(shaders.step);

    const check_mp2_step = b.step(
        "check-mp2",
        "Compile the MP2 direct-IP authority and graphical client",
    );
    check_mp2_step.dependOn(&mp2_server_exe.step);
    check_mp2_step.dependOn(&mp2_client_exe.step);

    const check_mp6_step = b.step(
        "check-mp6",
        "Compile the MP6 ticketed room server and graphical client",
    );
    check_mp6_step.dependOn(&mp6_server_exe.step);
    check_mp6_step.dependOn(&mp2_client_exe.step);
    check_mp6_step.dependOn(&mp6_listen_client_exe.step);

    const install_mp2_server = b.addInstallArtifact(mp2_server_exe, .{});
    const install_mp2_client = b.addInstallArtifact(mp2_client_exe, .{});
    const install_mp2_step = b.step(
        "install-mp2",
        "Install the MP2 server and graphical client",
    );
    install_mp2_step.dependOn(&install_mp2_server.step);
    install_mp2_step.dependOn(&install_mp2_client.step);

    const install_mp6_server = b.addInstallArtifact(mp6_server_exe, .{});
    const install_mp6_client = b.addInstallArtifact(mp2_client_exe, .{});
    const install_mp6_listen = b.addInstallArtifact(mp6_listen_client_exe, .{});
    const install_mp6_step = b.step(
        "install-mp6",
        "Install the MP6 room server and ticket-capable graphical client",
    );
    install_mp6_step.dependOn(&install_mp6_server.step);
    install_mp6_step.dependOn(&install_mp6_client.step);
    install_mp6_step.dependOn(&install_mp6_listen.step);

    const run_mp2_server = b.addRunArtifact(mp2_server_exe);
    if (b.args) |args| run_mp2_server.addArgs(args);
    const run_mp2_server_step = b.step(
        "run-mp2-server",
        "Run the MP2 dedicated direct-IP authority",
    );
    run_mp2_server_step.dependOn(&run_mp2_server.step);

    const run_mp2_client = b.addRunArtifact(mp2_client_exe);
    if (b.args) |args| run_mp2_client.addArgs(args);
    const run_mp2_client_step = b.step(
        "run-mp2-client",
        "Run one MP2 graphical direct-IP client",
    );
    run_mp2_client_step.dependOn(&run_mp2_client.step);

    const run_mp6_server = b.addRunArtifact(mp6_server_exe);
    if (b.args) |args| run_mp6_server.addArgs(args);
    const run_mp6_server_step = b.step(
        "run-mp6-server",
        "Run the MP6 room-owning ticketed authority",
    );
    run_mp6_server_step.dependOn(&run_mp6_server.step);
    const run_mp6_listen = b.addRunArtifact(mp6_listen_client_exe);
    if (b.args) |args| run_mp6_listen.addArgs(args);
    const run_mp6_listen_step = b.step(
        "run-mp6-listen",
        "Create and play a graphical MP6 private listen room",
    );
    run_mp6_listen_step.dependOn(&run_mp6_listen.step);

    const mp2_server_tests = b.addTest(.{ .root_module = mp2_server_module });
    const run_mp2_server_tests = b.addRunArtifact(mp2_server_tests);
    const mp2_client_tests = b.addTest(.{ .root_module = mp2_client_module });
    const run_mp2_client_tests = b.addRunArtifact(mp2_client_tests);
    const mp2_host_test_step = b.step(
        "test-mp2-hosts",
        "Run MP2 server/client composition tests",
    );
    mp2_host_test_step.dependOn(&run_mp2_server_tests.step);
    mp2_host_test_step.dependOn(&run_mp2_client_tests.step);
    const mp6_server_tests = b.addTest(.{ .root_module = mp6_server_module });
    const run_mp6_server_tests = b.addRunArtifact(mp6_server_tests);
    const mp6_listen_room_tests = b.addTest(.{ .root_module = mp6_listen_room_module });
    gns.link(mp6_listen_room_tests);
    const run_mp6_listen_room_tests = b.addRunArtifact(mp6_listen_room_tests);
    const mp6_listen_client_tests = b.addTest(.{ .root_module = mp6_listen_client_module });
    const run_mp6_listen_client_tests = b.addRunArtifact(mp6_listen_client_tests);
    const mp6_host_test_step = b.step(
        "test-mp6-hosts",
        "Run MP6 room-server and ticket-capable client composition tests",
    );
    mp6_host_test_step.dependOn(&run_mp6_server_tests.step);
    mp6_host_test_step.dependOn(&run_mp6_listen_room_tests.step);
    mp6_host_test_step.dependOn(&run_mp6_listen_client_tests.step);
    mp6_host_test_step.dependOn(&run_mp2_client_tests.step);
    const verify_mp6_process = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_mp6_process.sh"),
    });
    verify_mp6_process.addFileArg(mp6_server_exe.getEmittedBin());
    verify_mp6_process.addFileArg(mp2_client_exe.getEmittedBin());
    const verify_mp6_dedicated_step = b.step(
        "verify-mp6-dedicated",
        "Run the real-GNS two-client graphical MP6 dedicated room proof",
    );
    verify_mp6_dedicated_step.dependOn(&verify_mp6_process.step);
    verify_mp6_dedicated_step.dependOn(mp6_host_test_step);
    const verify_mp6_listen_process = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_mp6_listen_process.sh"),
    });
    verify_mp6_listen_process.addFileArg(mp6_listen_client_exe.getEmittedBin());
    verify_mp6_listen_process.addFileArg(mp2_client_exe.getEmittedBin());
    const verify_mp6_listen_step = b.step(
        "verify-mp6-listen",
        "Run the graphical host-local-link plus real-GNS guest MP6 proof",
    );
    verify_mp6_listen_step.dependOn(&verify_mp6_listen_process.step);
    verify_mp6_listen_step.dependOn(mp6_host_test_step);
    const verify_s10_listen_process = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_s10_listen_process.sh"),
    });
    verify_s10_listen_process.addFileArg(mp6_listen_client_exe.getEmittedBin());
    verify_s10_listen_process.addFileArg(mp2_client_exe.getEmittedBin());
    const verify_s10_listen_step = b.step(
        "verify-s10-listen",
        "Run the two-client graphical listen damage/death/respawn proof",
    );
    verify_s10_listen_step.dependOn(&verify_s10_listen_process.step);
    verify_s10_listen_step.dependOn(mp6_host_test_step);
    const verify_s10_dedicated_process = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_s10_dedicated_process.sh"),
    });
    verify_s10_dedicated_process.addFileArg(mp6_server_exe.getEmittedBin());
    verify_s10_dedicated_process.addFileArg(mp2_client_exe.getEmittedBin());
    const verify_s10_dedicated_step = b.step(
        "verify-s10-dedicated",
        "Run the two-client graphical dedicated damage/death/respawn proof",
    );
    verify_s10_dedicated_step.dependOn(&verify_s10_dedicated_process.step);
    verify_s10_dedicated_step.dependOn(mp6_host_test_step);
    const verify_s11_listen_process = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_s11_listen_process.sh"),
    });
    verify_s11_listen_process.addFileArg(mp6_listen_client_exe.getEmittedBin());
    verify_s11_listen_process.addFileArg(mp2_client_exe.getEmittedBin());
    const verify_s11_listen_step = b.step(
        "verify-s11-listen",
        "Run two-client graphical listen NPC damage/death/replacement",
    );
    verify_s11_listen_step.dependOn(&verify_s11_listen_process.step);
    verify_s11_listen_step.dependOn(mp6_host_test_step);
    const verify_s11_dedicated_process = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_s11_dedicated_process.sh"),
    });
    verify_s11_dedicated_process.addFileArg(mp6_server_exe.getEmittedBin());
    verify_s11_dedicated_process.addFileArg(mp2_client_exe.getEmittedBin());
    const verify_s11_dedicated_step = b.step(
        "verify-s11-dedicated",
        "Run two-client graphical dedicated NPC damage/death/replacement",
    );
    verify_s11_dedicated_step.dependOn(&verify_s11_dedicated_process.step);
    verify_s11_dedicated_step.dependOn(mp6_host_test_step);
    const mp6_lifecycle_acceptance_module = b.createModule(.{
        .root_source_file = b.path("tools/mp6_lifecycle_acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_room", .module = session_room_module },
            .{ .name = "room_coordinator", .module = room_coordinator_module },
            .{ .name = "impaired_link", .module = impaired_link_module },
        },
    });
    const mp6_lifecycle_acceptance_exe = b.addExecutable(.{
        .name = "incinerator_mp6_lifecycle_acceptance",
        .root_module = mp6_lifecycle_acceptance_module,
    });
    const mp6_lifecycle_tests = b.addTest(.{
        .root_module = mp6_lifecycle_acceptance_module,
    });
    const run_mp6_lifecycle_tests = b.addRunArtifact(mp6_lifecycle_tests);
    const verify_mp6_lifecycle_step = b.step(
        "verify-mp6-lifecycle",
        "Run selectable clean/nominal/adverse/blackout room lifecycle proofs",
    );
    verify_mp6_lifecycle_step.dependOn(&run_mp6_lifecycle_tests.step);
    inline for (.{ "clean", "nominal", "adverse", "blackout" }) |profile| {
        const run = b.addRunArtifact(mp6_lifecycle_acceptance_exe);
        run.addArgs(&.{ "--impairment", profile });
        verify_mp6_lifecycle_step.dependOn(&run.step);
    }

    const mp2_loopback_module = b.createModule(.{
        .root_source_file = b.path("tools/mp2_loopback.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_authority", .module = session_authority_module },
            .{ .name = "session_transport_policy", .module = session_transport_policy_module },
            .{ .name = "gns_direct", .module = gns_direct_module },
        },
    });
    const mp2_loopback_exe = b.addExecutable(.{
        .name = "incinerator_mp2_loopback",
        .root_module = mp2_loopback_module,
    });
    gns.link(mp2_loopback_exe);
    const run_mp2_loopback = b.addRunArtifact(mp2_loopback_exe);
    if (b.args) |args| run_mp2_loopback.addArgs(args);
    const verify_mp2_step = b.step(
        "verify-mp2",
        "Run the real-GNS two-client MP2 acceptance proof",
    );
    verify_mp2_step.dependOn(&run_mp2_server_tests.step);
    verify_mp2_step.dependOn(&run_mp2_client_tests.step);
    verify_mp2_step.dependOn(&run_mp2_loopback.step);

    const mp3_acceptance_module = b.createModule(.{
        .root_source_file = b.path("tools/mp3_acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_authority", .module = session_authority_module },
            .{ .name = "impaired_link", .module = impaired_link_module },
        },
    });
    const mp3_acceptance_exe = b.addExecutable(.{
        .name = "incinerator_mp3_acceptance",
        .root_module = mp3_acceptance_module,
    });
    const run_mp3_acceptance = b.addRunArtifact(mp3_acceptance_exe);
    const mp3_shutdown_client_module = b.createModule(.{
        .root_source_file = b.path("tools/mp3_shutdown_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_transport_policy", .module = session_transport_policy_module },
            .{ .name = "gns_direct", .module = gns_direct_module },
        },
    });
    const mp3_shutdown_client_exe = b.addExecutable(.{
        .name = "incinerator_mp3_shutdown_client",
        .root_module = mp3_shutdown_client_module,
    });
    gns.link(mp3_shutdown_client_exe);
    const verify_mp3_process = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_mp3_process.sh"),
    });
    verify_mp3_process.addFileArg(mp2_server_exe.getEmittedBin());
    verify_mp3_process.addFileArg(mp3_shutdown_client_exe.getEmittedBin());
    const verify_mp3_step = b.step(
        "verify-mp3",
        "Run deterministic prediction/fault acceptance and the real-GNS regression",
    );
    verify_mp3_step.dependOn(&run_mp3_acceptance.step);
    verify_mp3_step.dependOn(&verify_mp3_process.step);
    verify_mp3_step.dependOn(&run_mp2_loopback.step);
    verify_mp3_step.dependOn(&run_mp2_server_tests.step);
    verify_mp3_step.dependOn(&run_mp2_client_tests.step);

    const interaction_validation_module = b.createModule(.{
        .root_source_file = b.path("tools/interaction_validation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_authority", .module = session_authority_module },
            .{ .name = "impaired_link", .module = impaired_link_module },
            .{ .name = "sandbox_gameplay_scenarios", .module = sandbox_gameplay_scenarios_module },
        },
    });
    const interaction_validation_exe = b.addExecutable(.{
        .name = "incinerator_interaction_validation",
        .root_module = interaction_validation_module,
    });
    const interaction_validation_tests = b.addTest(.{
        .root_module = interaction_validation_module,
    });
    const run_interaction_validation_tests = b.addRunArtifact(interaction_validation_tests);
    const run_interaction_validation = b.addRunArtifact(interaction_validation_exe);
    if (b.args) |args| run_interaction_validation.addArgs(args);
    const run_interaction_validation_step = b.step(
        "run-interaction-validation",
        "Run one replayable IV5 gameplay journey/fault/fuzz configuration",
    );
    run_interaction_validation_step.dependOn(&run_interaction_validation.step);

    const interaction_matrix_step = b.step(
        "verify-interaction-matrix",
        "Run deterministic clean/fault/reconnect gameplay journey matrix",
    );
    interaction_matrix_step.dependOn(&run_interaction_validation_tests.step);
    inline for (.{
        .{ "clean", "20753", true },
        .{ "nominal", "20754", false },
        .{ "nominal", "20755", false },
        .{ "nominal", "20756", false },
        .{ "adverse", "20757", false },
        .{ "adverse", "20758", false },
        .{ "adverse", "20759", false },
        .{ "blackout", "20760", false },
    }) |trial| {
        const run = b.addRunArtifact(interaction_validation_exe);
        run.addArgs(&.{
            "--profile",
            trial[0],
            "--seed",
            trial[1],
            "--ticks",
            "4800",
            "--reconnect",
        });
        if (trial[2]) run.addArg("--repeat");
        interaction_matrix_step.dependOn(&run.step);
    }
    const run_interaction_routine_soak = b.addRunArtifact(interaction_validation_exe);
    run_interaction_routine_soak.addArgs(&.{
        "--profile",
        "adverse",
        "--seed",
        "20817",
        "--ticks",
        "8192",
        "--fuzz",
        "--reconnect",
    });
    const interaction_routine_soak_step = b.step(
        "soak-interactions",
        "Run the routine 8,192-tick seeded gameplay interaction soak",
    );
    interaction_routine_soak_step.dependOn(&run_interaction_routine_soak.step);
    const run_interaction_long_soak = b.addRunArtifact(interaction_validation_exe);
    run_interaction_long_soak.addArgs(&.{
        "--profile",
        "adverse",
        "--seed",
        "20818",
        "--ticks",
        "32768",
        "--fuzz",
        "--reconnect",
    });
    const interaction_long_soak_step = b.step(
        "soak-interactions-long",
        "Run the opt-in 32,768-tick seeded gameplay interaction soak",
    );
    interaction_long_soak_step.dependOn(&run_interaction_long_soak.step);

    const mp4_acceptance_module = b.createModule(.{
        .root_source_file = b.path("tools/mp4_acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_authority", .module = session_authority_module },
            .{ .name = "impaired_link", .module = impaired_link_module },
        },
    });
    const mp4_acceptance_exe = b.addExecutable(.{
        .name = "incinerator_mp4_acceptance",
        .root_module = mp4_acceptance_module,
    });
    const run_mp4_acceptance = b.addRunArtifact(mp4_acceptance_exe);
    const verify_mp4_step = b.step(
        "verify-mp4",
        "Run authoritative vehicle replication under deterministic faults and real GNS",
    );
    verify_mp4_step.dependOn(&run_mp4_acceptance.step);
    verify_mp4_step.dependOn(verify_mp3_step);

    const mp4b_acceptance_module = b.createModule(.{
        .root_source_file = b.path("tools/mp4b_acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_authority", .module = session_authority_module },
            .{ .name = "impaired_link", .module = impaired_link_module },
        },
    });
    const mp4b_acceptance_exe = b.addExecutable(.{
        .name = "incinerator_mp4b_acceptance",
        .root_module = mp4b_acceptance_module,
    });
    const run_mp4b_acceptance = b.addRunArtifact(mp4b_acceptance_exe);
    const verify_mp4b_step = b.step(
        "verify-mp4b",
        "Run carry interaction faults, teardown cleanup, and real-GNS contention",
    );
    verify_mp4b_step.dependOn(&run_mp4b_acceptance.step);
    verify_mp4b_step.dependOn(verify_mp4_step);
    const verify_mp4c_step = b.step(
        "verify-mp4c",
        "Run acknowledged district-baseline, hysteresis, JIP, reconnect, and relevance proofs",
    );
    verify_mp4c_step.dependOn(verify_mp4b_step);
    verify_mp4c_step.dependOn(&run_mp2_loopback.step);
    const verify_mp4d_step = b.step(
        "verify-mp4d",
        "Run 64-NPC relevant projection, lower-rate interpolation, JIP, reconnect, and fault proofs",
    );
    verify_mp4d_step.dependOn(verify_mp4c_step);
    verify_mp4d_step.dependOn(&run_mp3_acceptance.step);
    const mp4e_acceptance_module = b.createModule(.{
        .root_source_file = b.path("tools/mp4e_acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_authority", .module = session_authority_module },
        },
    });
    const mp4e_acceptance_exe = b.addExecutable(.{
        .name = "incinerator_mp4e_acceptance",
        .root_module = mp4e_acceptance_module,
    });
    const run_mp4e_acceptance = b.addRunArtifact(mp4e_acceptance_exe);
    const verify_mp4e_step = b.step(
        "verify-mp4e",
        "Run acknowledged-delta, bandwidth-priority, fallback, and overload proofs",
    );
    verify_mp4e_step.dependOn(&run_mp4e_acceptance.step);
    verify_mp4e_step.dependOn(verify_mp4d_step);
    const verify_mp4_architecture = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_mp4_architecture.sh"),
    });
    const verify_mp4_complete_step = b.step(
        "verify-mp4-complete",
        "Run the complete MP4 feature replication and architecture closeout gate",
    );
    verify_mp4_complete_step.dependOn(verify_mp4e_step);
    verify_mp4_complete_step.dependOn(&verify_mp4_architecture.step);
    const mp5_acceptance_module = b.createModule(.{
        .root_source_file = b.path("tools/mp5_acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session_protocol", .module = session_protocol_module },
            .{ .name = "session_room", .module = session_room_module },
            .{ .name = "session_client", .module = session_client_module },
            .{ .name = "session_authority", .module = session_authority_module },
        },
    });
    const mp5_acceptance_exe = b.addExecutable(.{
        .name = "incinerator_mp5_acceptance",
        .root_module = mp5_acceptance_module,
    });
    const run_mp5_acceptance = b.addRunArtifact(mp5_acceptance_exe);
    const run_mp5_acceptance_step = b.step(
        "run-mp5-acceptance",
        "Run the focused open room/invite acceptance proof",
    );
    run_mp5_acceptance_step.dependOn(&run_mp5_acceptance.step);
    const verify_mp5_step = b.step(
        "verify-mp5",
        "Run open room, invite, identity-bound admission, placement, and service-outage proofs",
    );
    verify_mp5_step.dependOn(&run_mp5_acceptance.step);
    verify_mp5_step.dependOn(verify_mp4_complete_step);

    // The headless host is intentionally not installed by the default build.
    // Its allowlisted module graph has no SDL, editor, asset, or shader edge.
    const external_producers_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/external_producers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const headless_config_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/headless_config.zig"),
        .target = target,
        .optimize = optimize,
    });
    const headless_content_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/headless_content.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "headless_config", .module = headless_config_module },
            .{ .name = "headless_content_manifest", .module = graph.headless_content_manifest },
            .{ .name = "sandbox_district_recipe", .module = graph.sandbox_district_recipe },
        },
    });
    const headless_clock_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/headless_clock.zig"),
        .target = target,
        .optimize = optimize,
    });
    const macos_signals_module = b.createModule(.{
        .root_source_file = b.path("src/adapters/platform/macos_signals.zig"),
        .target = target,
        .optimize = optimize,
    });
    const headless_authority_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/headless_authority.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "crate_contract", .module = crate_contract_module },
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
            .{ .name = "simulation_snapshot", .module = simulation_snapshot_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract_module },
            .{ .name = "npc_contract", .module = npc_contract_module },
            .{ .name = "external_producers", .module = external_producers_module },
            .{ .name = "sandbox_save", .module = sandbox_save_module },
        },
    });
    const m3_soak_module = b.createModule(.{
        .root_source_file = b.path("tools/m3_soak.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
            .{ .name = "simulation_snapshot", .module = simulation_snapshot_module },
            .{ .name = "crate_contract", .module = crate_contract_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract_module },
            .{ .name = "headless_authority", .module = headless_authority_module },
            .{ .name = "external_producers", .module = external_producers_module },
            .{ .name = "sandbox_save", .module = sandbox_save_module },
        },
    });
    const headless_root_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/headless.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
            .{ .name = "simulation_snapshot", .module = simulation_snapshot_module },
            .{ .name = "crate_contract", .module = crate_contract_module },
            .{ .name = "character_contract", .module = character_contract_module },
            .{ .name = "vehicle_contract", .module = vehicle_contract_module },
            .{ .name = "district_contract", .module = district_contract_module },
            .{ .name = "district_feature_contract", .module = district_feature_contract_module },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract_module },
            .{ .name = "npc_contract", .module = npc_contract_module },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract_module },
            .{ .name = "vitals_contract", .module = vitals_contract_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract_module },
            .{ .name = "sandbox_replay", .module = sandbox_replay_module },
            .{ .name = "sandbox_authoring", .module = sandbox_authoring_module },
            .{ .name = "developer_diagnostics", .module = developer_diagnostics_module },
            .{ .name = "sandbox_save", .module = sandbox_save_module },
            .{ .name = "save_slots", .module = save_slots_module },
            .{ .name = "headless_config", .module = headless_config_module },
            .{ .name = "headless_content", .module = headless_content_module },
            .{ .name = "headless_clock", .module = headless_clock_module },
            .{ .name = "macos_signals", .module = macos_signals_module },
            .{ .name = "headless_authority", .module = headless_authority_module },
        },
    });
    const headless_exe = b.addExecutable(.{
        .name = "incinerator_headless",
        .root_module = headless_root_module,
    });
    const m3_soak_exe = b.addExecutable(.{
        .name = "incinerator_m3_soak",
        .root_module = m3_soak_module,
    });
    const check_m3_soak_step = b.step(
        "check-m3-soak",
        "Compile the SDL-free M3 virtual-time soak",
    );
    check_m3_soak_step.dependOn(&m3_soak_exe.step);
    const run_m3_soak = b.addRunArtifact(m3_soak_exe);
    run_m3_soak.addArg("routine");
    const measure_m3_step = b.step(
        "measure-m3",
        "Run the ReleaseFast 32,768-tick M3 readiness soak",
    );
    measure_m3_step.dependOn(&run_m3_soak.step);
    const run_m3_long = b.addRunArtifact(m3_soak_exe);
    run_m3_long.addArg("long");
    const measure_m3_long_step = b.step(
        "measure-m3-long",
        "Run the opt-in ReleaseFast 131,072-tick M3 soak",
    );
    measure_m3_long_step.dependOn(&run_m3_long.step);
    const headless_boundary_exe = b.addExecutable(.{
        .name = "headless_boundary_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_boundary_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const verify_headless_boundary = b.addRunArtifact(headless_boundary_exe);
    verify_headless_boundary.setCwd(b.path("."));
    const verify_headless_boundary_step = b.step(
        "verify-headless-boundary",
        "Reject visual imports from the headless source graph",
    );
    verify_headless_boundary_step.dependOn(&verify_headless_boundary.step);

    const headless_linkage_exe = b.addExecutable(.{
        .name = "headless_linkage_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_linkage_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const verify_headless_linkage = b.addRunArtifact(headless_linkage_exe);
    verify_headless_linkage.addFileArg(headless_exe.getEmittedBin());
    const verify_headless_linkage_step = b.step(
        "verify-headless-linkage",
        "Reject visual dependencies from the final headless binary",
    );
    verify_headless_linkage_step.dependOn(&verify_headless_linkage.step);
    const verify_mp2_server_linkage = b.addRunArtifact(headless_linkage_exe);
    verify_mp2_server_linkage.addFileArg(mp2_server_exe.getEmittedBin());
    const verify_mp2_server_boundary_step = b.step(
        "verify-mp2-server-boundary",
        "Reject visual/editor dependencies from the final MP2 authority binary",
    );
    verify_mp2_server_boundary_step.dependOn(&verify_mp2_server_linkage.step);
    verify_mp2_step.dependOn(&verify_mp2_server_linkage.step);

    const headless_boundary_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_boundary_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_headless_boundary_tests = b.addRunArtifact(headless_boundary_tests);
    const headless_linkage_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_linkage_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_headless_linkage_tests = b.addRunArtifact(headless_linkage_tests);
    const headless_tool_test_step = b.step(
        "test-headless-tools",
        "Run portable headless boundary verifier tests",
    );
    headless_tool_test_step.dependOn(&run_headless_boundary_tests.step);
    headless_tool_test_step.dependOn(&run_headless_linkage_tests.step);

    // Same-cohort replay is a separate SDL/editor/GPU-free product. It reads
    // and validates the complete envelope/content cohorts before constructing
    // the process's one authoritative simulation world.
    const replay_tool_module = b.createModule(.{
        .root_source_file = b.path("tools/s4_replay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "content", .module = content_module },
            .{ .name = "district_content_catalog", .module = district_content_catalog_module },
            .{ .name = "sandbox_replay", .module = sandbox_replay_module },
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "npc_contract", .module = npc_contract_module },
            .{ .name = "interaction_feature", .module = interaction_feature_module },
        },
    });
    const replay_tool_exe = b.addExecutable(.{
        .name = "incinerator_replay",
        .root_module = replay_tool_module,
    });
    b.installArtifact(replay_tool_exe);
    const check_replay_tool_step = b.step(
        "check-replay",
        "Compile the standalone SDL-free same-cohort replay verifier",
    );
    check_replay_tool_step.dependOn(&replay_tool_exe.step);
    const verify_replay_linkage = b.addRunArtifact(headless_linkage_exe);
    verify_replay_linkage.addFileArg(replay_tool_exe.getEmittedBin());
    const verify_replay_linkage_step = b.step(
        "verify-replay-boundary",
        "Reject visual dependencies from the final replay verifier binary",
    );
    verify_replay_linkage_step.dependOn(&verify_replay_linkage.step);
    check_replay_tool_step.dependOn(&verify_replay_linkage.step);
    const run_replay_tool = b.addRunArtifact(replay_tool_exe);
    if (b.args) |args| run_replay_tool.addArgs(args);
    const run_replay_tool_step = b.step(
        "run-replay",
        "Run the standalone replay tool",
    );
    run_replay_tool_step.dependOn(&run_replay_tool.step);

    const replay_incident = b.addRunArtifact(replay_tool_exe);
    replay_incident.addArg("verify-incident");
    if (b.args) |args| replay_incident.addArgs(args);
    const replay_incident_step = b.step(
        "replay-incident",
        "Verify an incident bundle replay: zig build replay-incident -- <run-folder> <installed-content-root>",
    );
    replay_incident_step.dependOn(&replay_incident.step);

    const incident_inspect_module = b.createModule(.{
        .root_source_file = b.path("tools/incident_inspect.zig"),
        .target = target,
        .optimize = optimize,
    });
    const incident_inspect_exe = b.addExecutable(.{
        .name = "incinerator_incident_inspect",
        .root_module = incident_inspect_module,
    });
    b.installArtifact(incident_inspect_exe);
    const run_incident_inspect = b.addRunArtifact(incident_inspect_exe);
    if (b.args) |args| run_incident_inspect.addArgs(args);
    const inspect_incident_step = b.step(
        "inspect-incident",
        "Validate and summarize a run: zig build inspect-incident -- <run-folder>",
    );
    inspect_incident_step.dependOn(&run_incident_inspect.step);

    const verify_incident_hardening = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("tools/verify_incident_hardening.sh"),
    });
    verify_incident_hardening.addFileArg(exe.getEmittedBin());
    verify_incident_hardening.addFileArg(incident_inspect_exe.getEmittedBin());
    verify_incident_hardening.addFileArg(replay_tool_exe.getEmittedBin());
    verify_incident_hardening.addArg(
        b.getInstallPath(.prefix, "share/incinerator/content"),
    );
    verify_incident_hardening.step.dependOn(&install_cooked_fixture.step);
    verify_incident_hardening.step.dependOn(&install_fixture_provenance.step);
    verify_incident_hardening.step.dependOn(&install_cooked_east.step);
    verify_incident_hardening.step.dependOn(&install_east_provenance.step);
    verify_incident_hardening.step.dependOn(&install_cooked_catalog.step);
    const verify_incident_hardening_step = b.step(
        "verify-incident-hardening",
        "Run the five installed Metal IC5-G evidence-failure journeys",
    );
    verify_incident_hardening_step.dependOn(&verify_incident_hardening.step);

    const incident_visual_report = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/incident_visual_report.py"),
    });
    if (b.args) |args| incident_visual_report.addArgs(args);
    const incident_visual_report_step = b.step(
        "incident-visual-report",
        "Create read-only PNG contact sheets: zig build incident-visual-report -- <run-folder> <new-output-folder>",
    );
    incident_visual_report_step.dependOn(&incident_visual_report.step);

    const nr0_capture_inspect = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/neural-rendering/inspect_nr0_capture.py"),
    });
    if (b.args) |args| nr0_capture_inspect.addArgs(args);
    const nr0_capture_inspect_step = b.step(
        "inspect-nr0-capture",
        "Validate native neural-input capture integrity: zig build inspect-nr0-capture -- <capture-root>...",
    );
    nr0_capture_inspect_step.dependOn(&nr0_capture_inspect.step);

    const nr0_visual_report = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/neural-rendering/nr0_visual_report.py"),
    });
    if (b.args) |args| nr0_visual_report.addArgs(args);
    const nr0_visual_report_step = b.step(
        "nr0-visual-report",
        "Create an external NR0 frame contact sheet: zig build nr0-visual-report -- <capture-root> <new-output.ppm>",
    );
    nr0_visual_report_step.dependOn(&nr0_visual_report.step);

    const title_renderer_contracts = b.addSystemCommand(&.{
        "python3",
        "-m",
        "unittest",
        b.pathFromRoot("tools/neural-rendering/title_renderer/test_contracts.py"),
        "-v",
    });
    title_renderer_contracts.setEnvironmentVariable(
        "PYTHONPATH",
        b.pathFromRoot("tools/neural-rendering"),
    );
    const title_renderer_contracts_step = b.step(
        "test-title-renderer-contracts",
        "Run cold NR4-E/NR5 corpus and sealed-test contracts without training dependencies",
    );
    title_renderer_contracts_step.dependOn(&title_renderer_contracts.step);

    const inspect_title_renderer_run = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/neural-rendering/title_renderer/inspect_run.py"),
    });
    inspect_title_renderer_run.setEnvironmentVariable(
        "PYTHONPATH",
        b.pathFromRoot("tools/neural-rendering"),
    );
    if (b.args) |args| inspect_title_renderer_run.addArgs(args);
    const inspect_title_renderer_run_step = b.step(
        "inspect-title-renderer-run",
        "Validate an external NR5 run: zig build inspect-title-renderer-run -- <absolute-run-root>",
    );
    inspect_title_renderer_run_step.dependOn(&inspect_title_renderer_run.step);

    const inspect_title_renderer_candidate = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/neural-rendering/title_renderer/inspect_candidate.py"),
    });
    inspect_title_renderer_candidate.setEnvironmentVariable(
        "PYTHONPATH",
        b.pathFromRoot("tools/neural-rendering"),
    );
    if (b.args) |args| inspect_title_renderer_candidate.addArgs(args);
    const inspect_title_renderer_candidate_step = b.step(
        "inspect-title-renderer-candidate",
        "Validate external NR5-C/D evidence: zig build inspect-title-renderer-candidate -- <absolute-run-root>",
    );
    inspect_title_renderer_candidate_step.dependOn(&inspect_title_renderer_candidate.step);

    const inspect_rf10_trial_bundle = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/neural-rendering/title_renderer/inspect_trial_bundle.py"),
    });
    inspect_rf10_trial_bundle.setEnvironmentVariable(
        "PYTHONPATH",
        b.pathFromRoot("tools/neural-rendering"),
    );
    if (b.args) |args| inspect_rf10_trial_bundle.addArgs(args);
    const inspect_rf10_trial_bundle_step = b.step(
        "inspect-rf10-trial-bundle",
        "Validate an external RF10 Core ML trial bundle: zig build inspect-rf10-trial-bundle -- <absolute-bundle-root>",
    );
    inspect_rf10_trial_bundle_step.dependOn(&inspect_rf10_trial_bundle.step);

    const verify_rf10_trial = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("tools/verify_rf10_trial.sh"),
    });
    verify_rf10_trial.addFileArg(validation_exe.getEmittedBin());
    verify_rf10_trial.addArg(b.getInstallPath(.prefix, "share/incinerator/content"));
    if (b.args) |args| verify_rf10_trial.addArgs(args);
    verify_rf10_trial.step.dependOn(&install_cooked_fixture.step);
    verify_rf10_trial.step.dependOn(&install_fixture_provenance.step);
    verify_rf10_trial.step.dependOn(&install_cooked_east.step);
    verify_rf10_trial.step.dependOn(&install_east_provenance.step);
    verify_rf10_trial.step.dependOn(&install_cooked_catalog.step);
    const verify_rf10_trial_step = b.step(
        "verify-rf10-trial",
        "Run the live six-channel RF10 Core ML graphical acceptance: zig build verify-rf10-trial -- <absolute-bundle-root>",
    );
    verify_rf10_trial_step.dependOn(&verify_rf10_trial.step);

    const verify_nr0_ab = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("tools/verify_nr0_ab.sh"),
    });
    verify_nr0_ab.addFileArg(validation_exe.getEmittedBin());
    verify_nr0_ab.addArg(b.getInstallPath(.prefix, "share/incinerator/content"));
    verify_nr0_ab.addArg(b.pathFromRoot("."));
    verify_nr0_ab.step.dependOn(&install_cooked_fixture.step);
    verify_nr0_ab.step.dependOn(&install_fixture_provenance.step);
    verify_nr0_ab.step.dependOn(&install_cooked_east.step);
    verify_nr0_ab.step.dependOn(&install_east_provenance.step);
    verify_nr0_ab.step.dependOn(&install_cooked_catalog.step);
    const verify_nr0_ab_step = b.step(
        "verify-nr0-ab",
        "Run deterministic macOS Metal NR0-A/B capture acceptance and retain /tmp evidence",
    );
    verify_nr0_ab_step.dependOn(&verify_nr0_ab.step);

    // Durable authoring/save verification is a separate cold, SDL/editor/GPU-
    // free product. The installed smoke invokes it twice so restore occurs in
    // a genuinely fresh process.
    const save_tool_module = b.createModule(.{
        .root_source_file = b.path("tools/s5_save.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "content", .module = content_module },
            .{ .name = "district_content_catalog", .module = district_content_catalog_module },
            .{ .name = "sandbox_replay", .module = sandbox_replay_module },
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
            .{ .name = "simulation_snapshot", .module = simulation_snapshot_module },
            .{ .name = "crate_contract", .module = crate_contract_module },
            .{ .name = "npc_contract", .module = npc_contract_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "interaction_feature", .module = interaction_feature_module },
            .{ .name = "sandbox_authoring", .module = sandbox_authoring_module },
            .{ .name = "sandbox_save", .module = sandbox_save_module },
            .{ .name = "save_slots", .module = save_slots_module },
        },
    });
    const save_tool_exe = b.addExecutable(.{
        .name = "incinerator_save",
        .root_module = save_tool_module,
    });
    b.installArtifact(save_tool_exe);
    const check_save_tool_step = b.step(
        "check-s5-save",
        "Compile and linkage-check the standalone durable save/restart verifier",
    );
    check_save_tool_step.dependOn(&save_tool_exe.step);
    const verify_save_linkage = b.addRunArtifact(headless_linkage_exe);
    verify_save_linkage.addFileArg(save_tool_exe.getEmittedBin());
    check_save_tool_step.dependOn(&verify_save_linkage.step);
    const run_save_tool = b.addRunArtifact(save_tool_exe);
    if (b.args) |args| run_save_tool.addArgs(args);
    const run_save_tool_step = b.step(
        "run-s5-save",
        "Run the standalone durable save/restart tool",
    );
    run_save_tool_step.dependOn(&run_save_tool.step);

    const s7_measure_root_module = b.createModule(.{
        .root_source_file = b.path("tools/s7_measure.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
            .{ .name = "character_contract", .module = character_contract_module },
            .{ .name = "district_feature_contract", .module = district_feature_contract_module },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract_module },
        },
    });
    const s7_measure_exe = b.addExecutable(.{
        .name = "incinerator_s7_measure",
        .root_module = s7_measure_root_module,
    });
    const run_s7_measure = b.addRunArtifact(s7_measure_exe);
    if (b.args) |args| run_s7_measure.addArgs(args);
    const s7_measure_step = b.step(
        "measure-s7",
        "Measure 128 S7 ownership cycles as versioned SDL-free JSON",
    );
    s7_measure_step.dependOn(&run_s7_measure.step);
    const s7_measure_tests = b.addTest(.{ .root_module = s7_measure_root_module });
    const run_s7_measure_tests = b.addRunArtifact(s7_measure_tests);
    const s7_measure_test_step = b.step(
        "test-s7-measure",
        "Run S7 measurement argument and report-statistic tests",
    );
    s7_measure_test_step.dependOn(&run_s7_measure_tests.step);

    const s8_measure_root_module = b.createModule(.{
        .root_source_file = b.path("tools/s8_measure.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
            .{ .name = "simulation_snapshot", .module = simulation_snapshot_module },
            .{ .name = "district_feature_contract", .module = district_feature_contract_module },
            .{ .name = "npc_contract", .module = npc_contract_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract_module },
            .{ .name = "sandbox_replay", .module = sandbox_replay_module },
            .{ .name = "sandbox_save", .module = sandbox_save_module },
            .{ .name = "population_contract", .module = population_contract_module },
            .{ .name = "district_contract", .module = district_contract_module },
            .{ .name = "jolt_physics", .module = jolt_physics_module },
            .{ .name = "content", .module = content_module },
            .{ .name = "district_content_catalog", .module = district_content_catalog_module },
        },
    });
    const s8_measure_exe = b.addExecutable(.{
        .name = "incinerator_s8_measure",
        .root_module = s8_measure_root_module,
    });
    const s8_measure_check_step = b.step(
        "check-s8-measure",
        "Compile the SDL-free S8 population measurement",
    );
    s8_measure_check_step.dependOn(&s8_measure_exe.step);
    const run_s8_measure = b.addRunArtifact(s8_measure_exe);
    run_s8_measure.addArg(b.getInstallPath(
        .prefix,
        "share/incinerator/content",
    ));
    run_s8_measure.step.dependOn(b.getInstallStep());
    const s8_measure_step = b.step(
        "measure-s8",
        "Run the ReleaseFast S8 replay proof and paired scale measurement",
    );
    s8_measure_step.dependOn(&run_s8_measure.step);
    const s8_measure_tests = b.addTest(.{ .root_module = s8_measure_root_module });
    const run_s8_measure_tests = b.addRunArtifact(s8_measure_tests);
    const s8_measure_test_step = b.step(
        "test-s8-measure",
        "Run S8 methodology and report-statistic tests",
    );
    s8_measure_test_step.dependOn(&run_s8_measure_tests.step);

    const s11_measure_root_module = b.createModule(.{
        .root_source_file = b.path("tools/s11_measure.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "npc_encounter_feature", .module = npc_encounter_feature_module },
            .{ .name = "npc_encounter_contract", .module = npc_encounter_contract_module },
            .{ .name = "vitals_contract", .module = vitals_contract_module },
        },
    });
    const s11_measure_exe = b.addExecutable(.{
        .name = "incinerator_s11_measure",
        .root_module = s11_measure_root_module,
    });
    const s11_measure_check_step = b.step(
        "check-s11-measure",
        "Compile the SDL-free S11 encounter measurement",
    );
    s11_measure_check_step.dependOn(&s11_measure_exe.step);
    const run_s11_measure = b.addRunArtifact(s11_measure_exe);
    const s11_measure_step = b.step(
        "measure-s11",
        "Run the ReleaseFast paired S11 encounter measurement",
    );
    s11_measure_step.dependOn(&run_s11_measure.step);
    const s11_measure_tests = b.addTest(.{ .root_module = s11_measure_root_module });
    const run_s11_measure_tests = b.addRunArtifact(s11_measure_tests);
    const s11_measure_test_step = b.step(
        "test-s11-measure",
        "Run S11 measurement methodology and statistic tests",
    );
    s11_measure_test_step.dependOn(&run_s11_measure_tests.step);

    const vehicle_dynamics_module = b.createModule(.{
        .root_source_file = b.path("tools/vehicle_dynamics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine_contracts", .module = contracts_module },
            .{ .name = "jolt_physics", .module = jolt_physics_module },
            .{ .name = "vehicle_contract", .module = vehicle_contract_module },
        },
    });
    const vehicle_dynamics_exe = b.addExecutable(.{
        .name = "incinerator_vehicle_dynamics",
        .root_module = vehicle_dynamics_module,
    });
    const run_vehicle_dynamics = b.addRunArtifact(vehicle_dynamics_exe);
    const vehicle_dynamics_step = b.step(
        "vehicle-dynamics-report",
        "Measure the legacy and current vehicle handling cohorts on real Jolt",
    );
    vehicle_dynamics_step.dependOn(&run_vehicle_dynamics.step);
    const vehicle_dynamics_tests = b.addTest(.{ .root_module = vehicle_dynamics_module });
    const run_vehicle_dynamics_tests = b.addRunArtifact(vehicle_dynamics_tests);
    const vehicle_dynamics_test_step = b.step(
        "test-vehicle-dynamics",
        "Run deterministic vehicle dynamics methodology tests",
    );
    vehicle_dynamics_test_step.dependOn(&run_vehicle_dynamics_tests.step);

    const headless_tests = b.addTest(.{ .root_module = headless_root_module });
    const run_headless_tests = b.addRunArtifact(headless_tests);
    const external_producers_tests = b.addTest(.{ .root_module = external_producers_module });
    const run_external_producers_tests = b.addRunArtifact(external_producers_tests);
    const external_producers_test_step = b.step(
        "test-external-producers",
        "Run bounded external producer router tests",
    );
    external_producers_test_step.dependOn(&run_external_producers_tests.step);
    const headless_authority_tests = b.addTest(.{ .root_module = headless_authority_module });
    const run_headless_authority_tests = b.addRunArtifact(headless_authority_tests);
    const headless_authority_test_step = b.step(
        "test-headless-authority",
        "Run one-world headless authority tests",
    );
    headless_authority_test_step.dependOn(&run_headless_authority_tests.step);
    const m3_soak_tests = b.addTest(.{ .root_module = m3_soak_module });
    const run_m3_soak_tests = b.addRunArtifact(m3_soak_tests);
    const m3_soak_test_step = b.step(
        "test-m3-soak",
        "Run M3 soak argument and cohort contract tests",
    );
    m3_soak_test_step.dependOn(&run_m3_soak_tests.step);
    const headless_test_step = b.step(
        "test-headless",
        "Run the isolated Flecs/Jolt sandbox lifecycle tests",
    );
    headless_test_step.dependOn(&run_headless_tests.step);
    headless_test_step.dependOn(&run_external_producers_tests.step);
    headless_test_step.dependOn(&run_headless_authority_tests.step);
    headless_test_step.dependOn(&verify_headless_boundary.step);
    headless_test_step.dependOn(&verify_headless_linkage.step);
    headless_test_step.dependOn(&run_headless_boundary_tests.step);
    headless_test_step.dependOn(&run_headless_linkage_tests.step);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // Native Tier-1 runtime gates execute the installed Mach-O directly from
    // outside the repository. They intentionally reject cross builds so a
    // successful compile cannot be mistaken for macOS/Metal runtime evidence.
    const native_apple_silicon = target.query.isNative() and
        target.result.os.tag == .macos and target.result.cpu.arch == .aarch64;
    const install_validation_artifact = b.addInstallArtifact(validation_exe, .{
        .dest_dir = .{ .override = .{ .custom = "libexec/incinerator" } },
    });
    const install_validation_step = b.step(
        "install-validation",
        "Install the visual-validation host outside the product bin directory",
    );
    install_validation_step.dependOn(b.getInstallStep());
    install_validation_step.dependOn(&install_validation_artifact.step);
    const check_validation_step = b.step(
        "check-validation",
        "Compile the visual-validation host without installing it",
    );
    check_validation_step.dependOn(&validation_exe.step);
    const validation_boundary_tool = b.addExecutable(.{
        .name = "validation_boundary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build/validation_boundary.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const verify_validation_boundary = b.addRunArtifact(validation_boundary_tool);
    verify_validation_boundary.addFileArg(exe.getEmittedBin());
    verify_validation_boundary.addFileArg(validation_exe.getEmittedBin());
    const verify_validation_boundary_step = b.step(
        "verify-validation-boundary",
        "Prove validation scenarios are absent from the product binary",
    );
    verify_validation_boundary_step.dependOn(&verify_validation_boundary.step);
    const validation_boundary_tests = b.addTest(.{
        .root_module = validation_boundary_tool.root_module,
    });
    const run_validation_boundary_tests = b.addRunArtifact(validation_boundary_tests);
    const test_validation_boundary_step = b.step(
        "test-validation-boundary",
        "Run product/validation marker scanner tests",
    );
    test_validation_boundary_step.dependOn(&run_validation_boundary_tests.step);
    const installed_validation_path = b.getInstallPath(
        .{ .custom = "libexec/incinerator" },
        validation_exe.out_filename,
    );
    const verify_installed_validation_step = b.step(
        "verify-installed-validation",
        "Verify validation-host relocation and executable-relative content discovery",
    );

    const installed_s1_smoke_step = b.step(
        "smoke-installed-s1-macos",
        "Run the installed S1 Metal smoke from /tmp (native Apple Silicon only)",
    );
    const installed_s2_smoke_step = b.step(
        "smoke-installed-s2-macos",
        "Run installed S2 Metal smokes above/below tick rate from /tmp (native Apple Silicon only)",
    );
    const installed_s3_smoke_step = b.step(
        "smoke-installed-s3-macos",
        "Run installed S3 cooked-content/Metal smokes above/below tick rate from /tmp (native Apple Silicon only)",
    );
    const installed_s6_smoke_step = b.step(
        "smoke-installed-s6-macos",
        "Run installed S6 two-district overlap/drain Metal smokes at 240/80 Hz from /tmp (native Apple Silicon only)",
    );
    const installed_s7_smoke_step = b.step(
        "smoke-installed-s7-macos",
        "Run installed S7 carry/ownership Metal smokes at 240/80 Hz from /tmp (native Apple Silicon only)",
    );
    const installed_s8_smoke_step = b.step(
        "smoke-installed-s8-macos",
        "Run installed S8 route/residency lifecycle Metal smokes at 240/80 Hz from /tmp (native Apple Silicon only)",
    );
    const installed_s11_smoke_step = b.step(
        "smoke-installed-s11-macos",
        "Run installed S11 combat-presentation Metal smokes at 240/80 Hz from /tmp (native Apple Silicon only)",
    );
    const installed_s13_smoke_step = b.step(
        "smoke-installed-s13-macos",
        "Run the ordinary twelve-member S13 Metal smoke above/below 60 Hz from /tmp (native Apple Silicon only)",
    );
    const s13_incident_benchmark_step = b.step(
        "benchmark-s13-incident-macos",
        "Measure incident capture in the ordinary S13 Metal product (native Apple Silicon only)",
    );
    const installed_s4_diagnostics_smoke_step = b.step(
        "smoke-installed-s4-diagnostics-macos",
        "Run the installed S4 diagnostics/fault-inspection Metal smoke from /tmp (native Apple Silicon only)",
    );
    const installed_s4_replay_smoke_step = b.step(
        "smoke-installed-s4-replay-macos",
        "Capture and verify a full installed same-cohort replay from /tmp (native Apple Silicon only)",
    );
    const installed_s4_physics_debug_smoke_step = b.step(
        "smoke-installed-s4-physics-debug-macos",
        "Run the installed bounded physics-debug/profiling Metal smoke from /tmp (native Apple Silicon only)",
    );
    const installed_s5_save_smoke_step = b.step(
        "smoke-installed-s5-save-macos",
        "Write and cold-restore an installed durable authoring save from /tmp (native Apple Silicon only)",
    );
    const installed_s5_authoring_smoke_step = b.step(
        "smoke-installed-s5-authoring-macos",
        "Run installed S5 editor authoring/save authority smoke from /tmp (native Apple Silicon, editor enabled)",
    );
    const window_lifecycle_smoke_step = b.step(
        "smoke-window-lifecycle-macos",
        "Exercise installed macOS minimize/restore suspension (native Apple Silicon only)",
    );
    const init_failure_smoke_step = b.step(
        "smoke-init-failures-macos",
        "Exercise installed SDL/Metal init cleanup and restart (native Apple Silicon only)",
    );
    const macos_readiness_step = b.step(
        "test-macos-readiness",
        "Run installed visual, streaming, diagnostics, authoring/save, window lifecycle, and init cleanup Tier-1 gates",
    );

    if (native_apple_silicon) {
        const verify_installed_validation = addValidationCommand(
            b,
            install_validation_step,
            &.{ installed_validation_path, "--verify-install" },
        );
        verify_installed_validation.setCwd(.{ .cwd_relative = "/tmp" });
        verify_installed_validation.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        verify_installed_validation_step.dependOn(
            &verify_installed_validation.step,
        );

        const installed_s1_smoke = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s1-visual-smoke",
            "--frames=160",
            "--virtual-render-hz=80",
        });
        installed_s1_smoke.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s1_smoke.step.dependOn(b.getInstallStep());
        installed_s1_smoke_step.dependOn(&installed_s1_smoke.step);

        const installed_s2_smoke_below = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s2-visual-smoke",
            "--frames=480",
            "--virtual-render-hz=80",
        });
        installed_s2_smoke_below.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s2_smoke_below.step.dependOn(b.getInstallStep());
        const installed_s2_smoke_above = b.addSystemCommand(&.{
            installed_validation_path,
            "--s2-visual-smoke",
            "--frames=1440",
            "--virtual-render-hz=240",
        });
        installed_s2_smoke_above.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s2_smoke_above.step.dependOn(&installed_s2_smoke_below.step);
        installed_s2_smoke_step.dependOn(&installed_s2_smoke_above.step);

        const installed_s3_smoke_above = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s3-streaming-smoke",
            "--frames=1200",
            "--virtual-render-hz=240",
        });
        installed_s3_smoke_above.setCwd(.{ .cwd_relative = "/tmp" });
        // Relocation evidence must exercise executable-relative content
        // discovery rather than a development-shell override.
        installed_s3_smoke_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        // The install step also cooks and installs the S3 fixture/provenance.
        installed_s3_smoke_above.step.dependOn(b.getInstallStep());
        const installed_s3_smoke_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s3-streaming-smoke",
            "--frames=1200",
            "--virtual-render-hz=80",
        });
        installed_s3_smoke_below.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s3_smoke_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s3_smoke_below.step.dependOn(&installed_s3_smoke_above.step);
        installed_s3_smoke_step.dependOn(&installed_s3_smoke_below.step);

        const installed_s6_smoke_above = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s6-streaming-smoke",
            "--frames=240",
            "--virtual-render-hz=240",
        });
        installed_s6_smoke_above.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s6_smoke_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s6_smoke_above.step.dependOn(b.getInstallStep());
        const installed_s6_smoke_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s6-streaming-smoke",
            "--frames=96",
            "--virtual-render-hz=80",
        });
        installed_s6_smoke_below.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s6_smoke_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s6_smoke_below.step.dependOn(&installed_s6_smoke_above.step);
        installed_s6_smoke_step.dependOn(&installed_s6_smoke_below.step);

        const installed_s7_smoke_above = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s7-interaction-smoke",
            "--frames=1200",
            "--virtual-render-hz=240",
        });
        installed_s7_smoke_above.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s7_smoke_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s7_smoke_above.step.dependOn(b.getInstallStep());
        const installed_s7_smoke_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s7-interaction-smoke",
            "--frames=1200",
            "--virtual-render-hz=80",
        });
        installed_s7_smoke_below.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s7_smoke_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s7_smoke_below.step.dependOn(&installed_s7_smoke_above.step);
        installed_s7_smoke_step.dependOn(&installed_s7_smoke_below.step);

        const installed_s8_smoke_above = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s8-population-smoke",
            "--frames=1920",
            "--virtual-render-hz=240",
        });
        installed_s8_smoke_above.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s8_smoke_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s8_smoke_above.step.dependOn(b.getInstallStep());
        const installed_s8_smoke_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s8-population-smoke",
            "--frames=640",
            "--virtual-render-hz=80",
        });
        installed_s8_smoke_below.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s8_smoke_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s8_smoke_below.step.dependOn(&installed_s8_smoke_above.step);
        installed_s8_smoke_step.dependOn(&installed_s8_smoke_below.step);

        const installed_s11_smoke_above = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s11-combat-smoke",
            "--frames=3840",
            "--virtual-render-hz=240",
        });
        installed_s11_smoke_above.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s11_smoke_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s11_smoke_above.step.dependOn(b.getInstallStep());
        const installed_s11_smoke_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s11-combat-smoke",
            "--frames=1280",
            "--virtual-render-hz=80",
        });
        installed_s11_smoke_below.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s11_smoke_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s11_smoke_below.step.dependOn(&installed_s11_smoke_above.step);
        installed_s11_smoke_step.dependOn(&installed_s11_smoke_below.step);

        const installed_s13_smoke_above = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s13-population-smoke",
            "--frames=3840",
            "--virtual-render-hz=240",
        });
        installed_s13_smoke_above.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s13_smoke_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s13_smoke_above.step.dependOn(b.getInstallStep());
        const installed_s13_smoke_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s13-population-smoke",
            "--frames=640",
            "--virtual-render-hz=40",
        });
        installed_s13_smoke_below.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s13_smoke_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s13_smoke_below.step.dependOn(&installed_s13_smoke_above.step);
        installed_s13_smoke_step.dependOn(&installed_s13_smoke_below.step);

        if (incident_capture_enabled) {
            const installed_product_path = b.getInstallPath(.bin, exe.out_filename);
            const benchmark_root = "/tmp/incinerator-s13-incident-benchmark";
            const benchmark_prepare = b.addSystemCommand(&.{
                "rm",
                "-rf",
                benchmark_root,
            });
            benchmark_prepare.step.dependOn(b.getInstallStep());
            const benchmark_incident = b.addSystemCommand(&.{
                installed_product_path,
                "--incident-benchmark",
            });
            benchmark_incident.setCwd(.{ .cwd_relative = "/tmp" });
            benchmark_incident.removeEnvironmentVariable(
                "INCINERATOR_CONTENT_ROOT",
            );
            benchmark_incident.setEnvironmentVariable(
                "INCINERATOR_INCIDENT_ROOT",
                benchmark_root,
            );
            benchmark_incident.step.dependOn(&benchmark_prepare.step);
            s13_incident_benchmark_step.dependOn(&benchmark_incident.step);
        } else {
            const incident_required = b.addFail(
                "S13 incident benchmark requires -Dincident-capture=true",
            );
            s13_incident_benchmark_step.dependOn(&incident_required.step);
        }

        const installed_s4_diagnostics_smoke = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s4-diagnostics-smoke",
        });
        installed_s4_diagnostics_smoke.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s4_diagnostics_smoke.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s4_diagnostics_smoke.step.dependOn(b.getInstallStep());
        installed_s4_diagnostics_smoke_step.dependOn(
            &installed_s4_diagnostics_smoke.step,
        );

        const installed_s4_physics_debug_smoke = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s4-physics-debug-smoke",
            "--frames=600",
            "--virtual-render-hz=80",
        });
        installed_s4_physics_debug_smoke.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s4_physics_debug_smoke.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        installed_s4_physics_debug_smoke.step.dependOn(b.getInstallStep());
        installed_s4_physics_debug_smoke_step.dependOn(
            &installed_s4_physics_debug_smoke.step,
        );

        const installed_replay_path = b.getInstallPath(
            .bin,
            replay_tool_exe.out_filename,
        );
        const replay_capture_path = "/tmp/incinerator-s4b-smoke.icrp";
        const installed_content_root = b.getInstallPath(
            .prefix,
            "share/incinerator/content",
        );
        const installed_s4_replay_record = b.addSystemCommand(&.{
            installed_replay_path,
            "record-smoke",
            replay_capture_path,
            installed_content_root,
        });
        installed_s4_replay_record.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s4_replay_record.step.dependOn(b.getInstallStep());
        const installed_s4_replay_verify = b.addSystemCommand(&.{
            installed_replay_path,
            "verify-smoke",
            replay_capture_path,
            installed_content_root,
        });
        installed_s4_replay_verify.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s4_replay_verify.step.dependOn(
            &installed_s4_replay_record.step,
        );
        const installed_s4_replay_cleanup = b.addSystemCommand(&.{
            "rm",
            "-f",
            replay_capture_path,
        });
        installed_s4_replay_cleanup.step.dependOn(
            &installed_s4_replay_verify.step,
        );
        installed_s4_replay_smoke_step.dependOn(
            &installed_s4_replay_cleanup.step,
        );

        const installed_save_path = b.getInstallPath(
            .bin,
            save_tool_exe.out_filename,
        );
        const save_root = "/tmp/incinerator-s5-save-smoke";
        const installed_s5_save_prepare = b.addSystemCommand(&.{
            "rm",
            "-rf",
            save_root,
        });
        installed_s5_save_prepare.step.dependOn(b.getInstallStep());
        const installed_s5_save_mkdir = b.addSystemCommand(&.{
            "mkdir",
            "-p",
            save_root,
        });
        installed_s5_save_mkdir.step.dependOn(&installed_s5_save_prepare.step);
        const installed_s5_save_write = b.addSystemCommand(&.{
            installed_save_path,
            "write-smoke",
            save_root,
            installed_content_root,
        });
        installed_s5_save_write.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s5_save_write.step.dependOn(&installed_s5_save_mkdir.step);
        const installed_s5_save_verify = b.addSystemCommand(&.{
            installed_save_path,
            "verify-smoke",
            save_root,
            installed_content_root,
        });
        installed_s5_save_verify.setCwd(.{ .cwd_relative = "/tmp" });
        installed_s5_save_verify.step.dependOn(&installed_s5_save_write.step);
        const installed_s5_save_cleanup = b.addSystemCommand(&.{
            "rm",
            "-rf",
            save_root,
        });
        installed_s5_save_cleanup.step.dependOn(&installed_s5_save_verify.step);
        installed_s5_save_smoke_step.dependOn(&installed_s5_save_cleanup.step);

        if (editor_enabled) {
            const authoring_save_root = "/tmp/incinerator-s5-authoring-smoke";
            const installed_s5_authoring_prepare = b.addSystemCommand(&.{
                "rm",
                "-rf",
                authoring_save_root,
            });
            installed_s5_authoring_prepare.step.dependOn(b.getInstallStep());
            const installed_s5_authoring_mkdir = b.addSystemCommand(&.{
                "mkdir",
                "-p",
                authoring_save_root,
            });
            installed_s5_authoring_mkdir.step.dependOn(
                &installed_s5_authoring_prepare.step,
            );
            const installed_s5_authoring = addValidationCommand(b, install_validation_step, &.{
                installed_validation_path,
                "--s5-authoring-smoke",
                "--save-root=" ++ authoring_save_root,
            });
            installed_s5_authoring.setCwd(.{ .cwd_relative = "/tmp" });
            installed_s5_authoring.removeEnvironmentVariable(
                "INCINERATOR_CONTENT_ROOT",
            );
            installed_s5_authoring.step.dependOn(&installed_s5_authoring_mkdir.step);
            const installed_s5_authoring_verify = b.addSystemCommand(&.{
                installed_save_path,
                "verify-authoring-smoke",
                authoring_save_root,
                installed_content_root,
            });
            installed_s5_authoring_verify.setCwd(.{ .cwd_relative = "/tmp" });
            installed_s5_authoring_verify.step.dependOn(
                &installed_s5_authoring.step,
            );
            const installed_s5_authoring_cleanup = b.addSystemCommand(&.{
                "rm",
                "-rf",
                authoring_save_root,
            });
            installed_s5_authoring_cleanup.step.dependOn(
                &installed_s5_authoring_verify.step,
            );
            installed_s5_authoring_smoke_step.dependOn(
                &installed_s5_authoring_cleanup.step,
            );
        } else {
            const editor_required = b.addFail(
                "S5 authoring smoke requires -Deditor=true",
            );
            installed_s5_authoring_smoke_step.dependOn(&editor_required.step);
        }

        const window_lifecycle_smoke = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--window-lifecycle-smoke",
        });
        window_lifecycle_smoke.setCwd(.{ .cwd_relative = "/tmp" });
        window_lifecycle_smoke.step.dependOn(b.getInstallStep());
        window_lifecycle_smoke_step.dependOn(&window_lifecycle_smoke.step);

        const init_failure_smoke = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--init-failure-smoke",
        });
        init_failure_smoke.setCwd(.{ .cwd_relative = "/tmp" });
        init_failure_smoke.step.dependOn(b.getInstallStep());
        init_failure_smoke_step.dependOn(&init_failure_smoke.step);

        // The aggregate gate is serialized deliberately. Concurrent GUI
        // processes would make WindowServer/Metal failures environmental and
        // weaken the signal from these native checks.
        const readiness_s2_below = addValidationCommand(b, install_validation_step, &.{
            installed_validation_path,
            "--s2-visual-smoke",
            "--frames=480",
            "--virtual-render-hz=80",
        });
        readiness_s2_below.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s2_below.step.dependOn(&verify_installed_validation.step);
        const readiness_s2_above = b.addSystemCommand(&.{
            installed_validation_path,
            "--s2-visual-smoke",
            "--frames=1440",
            "--virtual-render-hz=240",
        });
        readiness_s2_above.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s2_above.step.dependOn(&readiness_s2_below.step);

        const readiness_s3_above = b.addSystemCommand(&.{
            installed_validation_path,
            "--s3-streaming-smoke",
            "--frames=1200",
            "--virtual-render-hz=240",
        });
        readiness_s3_above.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s3_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s3_above.step.dependOn(&readiness_s2_above.step);
        const readiness_s3_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s3-streaming-smoke",
            "--frames=1200",
            "--virtual-render-hz=80",
        });
        readiness_s3_below.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s3_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s3_below.step.dependOn(&readiness_s3_above.step);

        const readiness_s6_above = b.addSystemCommand(&.{
            installed_validation_path,
            "--s6-streaming-smoke",
            "--frames=240",
            "--virtual-render-hz=240",
        });
        readiness_s6_above.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s6_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s6_above.step.dependOn(&readiness_s3_below.step);
        const readiness_s6_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s6-streaming-smoke",
            "--frames=96",
            "--virtual-render-hz=80",
        });
        readiness_s6_below.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s6_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s6_below.step.dependOn(&readiness_s6_above.step);

        const readiness_s7_above = b.addSystemCommand(&.{
            installed_validation_path,
            "--s7-interaction-smoke",
            "--frames=1200",
            "--virtual-render-hz=240",
        });
        readiness_s7_above.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s7_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s7_above.step.dependOn(&readiness_s6_below.step);
        const readiness_s7_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s7-interaction-smoke",
            "--frames=1200",
            "--virtual-render-hz=80",
        });
        readiness_s7_below.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s7_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s7_below.step.dependOn(&readiness_s7_above.step);

        const readiness_s8_above = b.addSystemCommand(&.{
            installed_validation_path,
            "--s8-population-smoke",
            "--frames=1920",
            "--virtual-render-hz=240",
        });
        readiness_s8_above.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s8_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s8_above.step.dependOn(&readiness_s7_below.step);
        const readiness_s8_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s8-population-smoke",
            "--frames=640",
            "--virtual-render-hz=80",
        });
        readiness_s8_below.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s8_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s8_below.step.dependOn(&readiness_s8_above.step);

        const readiness_s11_above = b.addSystemCommand(&.{
            installed_validation_path,
            "--s11-combat-smoke",
            "--frames=3840",
            "--virtual-render-hz=240",
        });
        readiness_s11_above.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s11_above.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s11_above.step.dependOn(&readiness_s8_below.step);
        const readiness_s11_below = b.addSystemCommand(&.{
            installed_validation_path,
            "--s11-combat-smoke",
            "--frames=1280",
            "--virtual-render-hz=80",
        });
        readiness_s11_below.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s11_below.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s11_below.step.dependOn(&readiness_s11_above.step);

        const readiness_window = b.addSystemCommand(&.{
            installed_validation_path,
            "--window-lifecycle-smoke",
        });
        readiness_window.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_window.step.dependOn(&readiness_s11_below.step);

        const readiness_init = b.addSystemCommand(&.{
            installed_validation_path,
            "--init-failure-smoke",
        });
        readiness_init.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_init.step.dependOn(&readiness_window.step);
        const readiness_s4_diagnostics = b.addSystemCommand(&.{
            installed_validation_path,
            "--s4-diagnostics-smoke",
        });
        readiness_s4_diagnostics.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s4_diagnostics.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s4_diagnostics.step.dependOn(&readiness_init.step);
        const readiness_s4_replay_record = b.addSystemCommand(&.{
            installed_replay_path,
            "record-smoke",
            replay_capture_path,
            installed_content_root,
        });
        readiness_s4_replay_record.setCwd(.{ .cwd_relative = "/tmp" });
        const readiness_s4_physics_debug = b.addSystemCommand(&.{
            installed_validation_path,
            "--s4-physics-debug-smoke",
            "--frames=600",
            "--virtual-render-hz=80",
        });
        readiness_s4_physics_debug.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s4_physics_debug.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s4_physics_debug.step.dependOn(
            &readiness_s4_diagnostics.step,
        );
        readiness_s4_replay_record.step.dependOn(
            &readiness_s4_physics_debug.step,
        );
        const readiness_s4_replay_verify = b.addSystemCommand(&.{
            installed_replay_path,
            "verify-smoke",
            replay_capture_path,
            installed_content_root,
        });
        readiness_s4_replay_verify.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s4_replay_verify.step.dependOn(
            &readiness_s4_replay_record.step,
        );
        const readiness_s4_replay_cleanup = b.addSystemCommand(&.{
            "rm",
            "-f",
            replay_capture_path,
        });
        readiness_s4_replay_cleanup.step.dependOn(
            &readiness_s4_replay_verify.step,
        );
        const readiness_s5_authoring_root =
            "/tmp/incinerator-s5-readiness-authoring";
        const readiness_s5_authoring_prepare = b.addSystemCommand(&.{
            "rm",
            "-rf",
            readiness_s5_authoring_root,
        });
        readiness_s5_authoring_prepare.step.dependOn(
            &readiness_s4_replay_cleanup.step,
        );
        const readiness_s5_authoring_mkdir = b.addSystemCommand(&.{
            "mkdir",
            "-p",
            readiness_s5_authoring_root,
        });
        readiness_s5_authoring_mkdir.step.dependOn(
            &readiness_s5_authoring_prepare.step,
        );
        const readiness_s5_authoring = b.addSystemCommand(&.{
            installed_validation_path,
            "--s5-authoring-smoke",
            "--save-root=" ++ readiness_s5_authoring_root,
        });
        readiness_s5_authoring.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s5_authoring.removeEnvironmentVariable(
            "INCINERATOR_CONTENT_ROOT",
        );
        readiness_s5_authoring.step.dependOn(
            &readiness_s5_authoring_mkdir.step,
        );
        const readiness_s5_authoring_verify = b.addSystemCommand(&.{
            installed_save_path,
            "verify-authoring-smoke",
            readiness_s5_authoring_root,
            installed_content_root,
        });
        readiness_s5_authoring_verify.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s5_authoring_verify.step.dependOn(
            &readiness_s5_authoring.step,
        );
        const readiness_s5_authoring_cleanup = b.addSystemCommand(&.{
            "rm",
            "-rf",
            readiness_s5_authoring_root,
        });
        readiness_s5_authoring_cleanup.step.dependOn(
            &readiness_s5_authoring_verify.step,
        );

        const readiness_s5_save_root = "/tmp/incinerator-s5-readiness-save";
        const readiness_s5_save_prepare = b.addSystemCommand(&.{
            "rm",
            "-rf",
            readiness_s5_save_root,
        });
        readiness_s5_save_prepare.step.dependOn(
            &readiness_s5_authoring_cleanup.step,
        );
        const readiness_s5_save_mkdir = b.addSystemCommand(&.{
            "mkdir",
            "-p",
            readiness_s5_save_root,
        });
        readiness_s5_save_mkdir.step.dependOn(&readiness_s5_save_prepare.step);
        const readiness_s5_save_write = b.addSystemCommand(&.{
            installed_save_path,
            "write-smoke",
            readiness_s5_save_root,
            installed_content_root,
        });
        readiness_s5_save_write.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s5_save_write.step.dependOn(&readiness_s5_save_mkdir.step);
        const readiness_s5_save_verify = b.addSystemCommand(&.{
            installed_save_path,
            "verify-smoke",
            readiness_s5_save_root,
            installed_content_root,
        });
        readiness_s5_save_verify.setCwd(.{ .cwd_relative = "/tmp" });
        readiness_s5_save_verify.step.dependOn(&readiness_s5_save_write.step);
        const readiness_s5_save_cleanup = b.addSystemCommand(&.{
            "rm",
            "-rf",
            readiness_s5_save_root,
        });
        readiness_s5_save_cleanup.step.dependOn(&readiness_s5_save_verify.step);
        if (editor_enabled) {
            macos_readiness_step.dependOn(&readiness_s5_save_cleanup.step);
        } else {
            const editor_required = b.addFail(
                "S5 macOS readiness requires -Deditor=true",
            );
            macos_readiness_step.dependOn(&editor_required.step);
        }
    } else {
        const native_only = b.addFail(
            "macOS readiness smokes require a native aarch64-macos target",
        );
        installed_s1_smoke_step.dependOn(&native_only.step);
        installed_s2_smoke_step.dependOn(&native_only.step);
        installed_s3_smoke_step.dependOn(&native_only.step);
        installed_s6_smoke_step.dependOn(&native_only.step);
        installed_s7_smoke_step.dependOn(&native_only.step);
        installed_s8_smoke_step.dependOn(&native_only.step);
        installed_s11_smoke_step.dependOn(&native_only.step);
        installed_s13_smoke_step.dependOn(&native_only.step);
        s13_incident_benchmark_step.dependOn(&native_only.step);
        installed_s4_diagnostics_smoke_step.dependOn(&native_only.step);
        installed_s4_replay_smoke_step.dependOn(&native_only.step);
        installed_s4_physics_debug_smoke_step.dependOn(&native_only.step);
        installed_s5_save_smoke_step.dependOn(&native_only.step);
        installed_s5_authoring_smoke_step.dependOn(&native_only.step);
        window_lifecycle_smoke_step.dependOn(&native_only.step);
        init_failure_smoke_step.dependOn(&native_only.step);
        verify_installed_validation_step.dependOn(&native_only.step);
        macos_readiness_step.dependOn(&native_only.step);
    }

    const verify_m4_architecture = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_m4_architecture.sh"),
    });
    const verify_m4_step = b.step(
        "verify-m4",
        "Run the macOS multiplayer foundation, graphical, placement, and architecture gate",
    );
    verify_m4_step.dependOn(verify_mp5_step);
    verify_m4_step.dependOn(check_mp2_step);
    verify_m4_step.dependOn(verify_mp2_server_boundary_step);
    verify_m4_step.dependOn(verify_headless_boundary_step);
    verify_m4_step.dependOn(verify_validation_boundary_step);
    verify_m4_step.dependOn(installed_s8_smoke_step);
    verify_m4_step.dependOn(&verify_m4_architecture.step);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // Keep the installation current before launching the cache artifact. Use
    // the dedicated installed-smoke steps above when cwd/relocation matters.
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.setEnvironmentVariable(
        "INCINERATOR_CONTENT_ROOT",
        b.getInstallPath(.prefix, "share/incinerator/content"),
    );

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const contracts_tests = b.addTest(.{ .root_module = contracts_module });
    const run_contracts_tests = b.addRunArtifact(contracts_tests);
    const contracts_test_step = b.step(
        "test-contracts",
        "Run backend-neutral contract tests",
    );
    contracts_test_step.dependOn(&run_contracts_tests.step);

    const sandbox_value_contracts_module = b.createModule(.{
        .root_source_file = b.path("src/hosts/sandbox_value_contracts_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "crate_contract", .module = crate_contract_module },
            .{ .name = "character_contract", .module = character_contract_module },
            .{ .name = "vehicle_contract", .module = vehicle_contract_module },
            .{ .name = "district_feature_contract", .module = district_feature_contract_module },
            .{ .name = "interaction_feature_contract", .module = interaction_feature_contract_module },
            .{ .name = "npc_contract", .module = npc_contract_module },
            .{ .name = "district_worker_contract", .module = district_worker_contract_module },
            .{ .name = "sandbox_diagnostics_contract", .module = sandbox_diagnostics_contract_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
        },
    });
    const sandbox_value_contracts_tests = b.addTest(.{
        .root_module = sandbox_value_contracts_module,
    });
    const run_sandbox_value_contracts_tests = b.addRunArtifact(
        sandbox_value_contracts_tests,
    );
    const sandbox_value_contracts_test_step = b.step(
        "test-sandbox-value-contracts",
        "Run canonical sandbox DTO identity and implementation-closure tests",
    );
    sandbox_value_contracts_test_step.dependOn(
        &run_sandbox_value_contracts_tests.step,
    );

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const kernel_test_step = b.step("test-kernel", "Run the SDL-free public kernel tests");
    kernel_test_step.dependOn(&run_mod_tests.step);

    const crate_feature_tests = b.addTest(.{ .root_module = crate_feature_module });
    const run_crate_feature_tests = b.addRunArtifact(crate_feature_tests);
    const crate_feature_test_step = b.step(
        "test-crate-feature",
        "Run the backend-neutral crate feature tests",
    );
    crate_feature_test_step.dependOn(&run_crate_feature_tests.step);

    const character_feature_tests = b.addTest(.{ .root_module = character_feature_module });
    const run_character_feature_tests = b.addRunArtifact(character_feature_tests);
    const character_feature_test_step = b.step(
        "test-character-feature",
        "Run the backend-neutral character feature tests",
    );
    character_feature_test_step.dependOn(&run_character_feature_tests.step);

    const vitals_contract_tests = b.addTest(.{ .root_module = vitals_contract_module });
    const run_vitals_contract_tests = b.addRunArtifact(vitals_contract_tests);
    const vitals_feature_tests = b.addTest(.{ .root_module = vitals_feature_module });
    const run_vitals_feature_tests = b.addRunArtifact(vitals_feature_tests);
    const vitals_feature_test_step = b.step(
        "test-vitals-feature",
        "Run deterministic bounded vitals contract and feature tests",
    );
    vitals_feature_test_step.dependOn(&run_vitals_contract_tests.step);
    vitals_feature_test_step.dependOn(&run_vitals_feature_tests.step);

    const npc_encounter_contract_tests = b.addTest(.{
        .root_module = npc_encounter_contract_module,
    });
    const run_npc_encounter_contract_tests = b.addRunArtifact(
        npc_encounter_contract_tests,
    );
    const npc_encounter_feature_tests = b.addTest(.{
        .root_module = npc_encounter_feature_module,
    });
    const run_npc_encounter_feature_tests = b.addRunArtifact(
        npc_encounter_feature_tests,
    );
    const npc_encounter_test_step = b.step(
        "test-npc-encounter",
        "Run bounded authoritative NPC encounter tests",
    );
    npc_encounter_test_step.dependOn(&run_npc_encounter_contract_tests.step);
    npc_encounter_test_step.dependOn(&run_npc_encounter_feature_tests.step);
    const driver_contract_tests = b.addTest(.{ .root_module = driver_contract_module });
    const run_driver_contract_tests = b.addRunArtifact(driver_contract_tests);
    const driver_contract_test_step = b.step(
        "test-driver-contract",
        "Run the character/vehicle driver-port contract tests",
    );
    driver_contract_test_step.dependOn(&run_driver_contract_tests.step);

    const interaction_contract_tests = b.addTest(.{
        .root_module = interaction_contract_module,
    });
    const run_interaction_contract_tests = b.addRunArtifact(
        interaction_contract_tests,
    );
    const interaction_contract_test_step = b.step(
        "test-interaction-contract",
        "Run carrier/district interaction-port contract tests",
    );
    interaction_contract_test_step.dependOn(
        &run_interaction_contract_tests.step,
    );

    const vehicle_feature_tests = b.addTest(.{ .root_module = vehicle_feature_module });
    const run_vehicle_feature_tests = b.addRunArtifact(vehicle_feature_tests);
    const vehicle_feature_test_step = b.step(
        "test-vehicle-feature",
        "Run the backend-neutral vehicle feature tests",
    );
    vehicle_feature_test_step.dependOn(&run_vehicle_feature_tests.step);

    const district_contract_tests = b.addTest(.{ .root_module = district_contract_module });
    const run_district_contract_tests = b.addRunArtifact(district_contract_tests);
    const district_contract_test_step = b.step(
        "test-district-contract",
        "Run renderer-neutral district build/loader contract tests",
    );
    district_contract_test_step.dependOn(&run_district_contract_tests.step);

    const navigation_contract_tests = b.addTest(.{
        .root_module = navigation_contract_module,
    });
    const run_navigation_contract_tests = b.addRunArtifact(
        navigation_contract_tests,
    );
    const navigation_contract_test_step = b.step(
        "test-navigation-contract",
        "Run generation-aware copied-value navigation contract tests",
    );
    navigation_contract_test_step.dependOn(
        &run_navigation_contract_tests.step,
    );

    const navigation_planner_tests = b.addTest(.{
        .root_module = navigation_planner_module,
    });
    const run_navigation_planner_tests = b.addRunArtifact(
        navigation_planner_tests,
    );
    const navigation_planner_test_step = b.step(
        "test-navigation-planner",
        "Run deterministic semantic-destination route planner tests",
    );
    navigation_planner_test_step.dependOn(&run_navigation_planner_tests.step);

    const sandbox_navigation_tests = b.addTest(.{
        .root_module = sandbox_navigation_module,
    });
    const run_sandbox_navigation_tests = b.addRunArtifact(
        sandbox_navigation_tests,
    );
    const sandbox_navigation_test_step = b.step(
        "test-sandbox-navigation",
        "Run pure exact-cohort navigation preflight tests",
    );
    sandbox_navigation_test_step.dependOn(&run_sandbox_navigation_tests.step);

    const district_worker_tests = b.addTest(.{ .root_module = district_worker_module });
    const run_district_worker_tests = b.addRunArtifact(district_worker_tests);
    const district_worker_test_step = b.step(
        "test-district-worker",
        "Run bounded procedural district worker tests",
    );
    district_worker_test_step.dependOn(&run_district_worker_tests.step);

    const district_replay_loader_tests = b.addTest(.{
        .root_module = district_replay_loader_module,
    });
    const run_district_replay_loader_tests = b.addRunArtifact(
        district_replay_loader_tests,
    );
    const district_replay_loader_test_step = b.step(
        "test-district-replay-loader",
        "Run logical district completion capture/injection seam tests",
    );
    district_replay_loader_test_step.dependOn(
        &run_district_replay_loader_tests.step,
    );

    const district_feature_tests = b.addTest(.{ .root_module = district_feature_module });
    const run_district_feature_tests = b.addRunArtifact(district_feature_tests);
    const district_feature_test_step = b.step(
        "test-district-feature",
        "Run backend-neutral district lifecycle tests",
    );
    district_feature_test_step.dependOn(&run_district_feature_tests.step);

    const interaction_feature_tests = b.addTest(.{
        .root_module = interaction_feature_module,
    });
    const run_interaction_feature_tests = b.addRunArtifact(
        interaction_feature_tests,
    );
    const interaction_feature_test_step = b.step(
        "test-interaction-feature",
        "Run bounded interaction ownership and rollback tests",
    );
    interaction_feature_test_step.dependOn(
        &run_interaction_feature_tests.step,
    );

    const npc_feature_tests = b.addTest(.{
        .root_module = npc_feature_module,
    });
    const run_npc_feature_tests = b.addRunArtifact(npc_feature_tests);
    const npc_feature_test_step = b.step(
        "test-npc-feature",
        "Run bounded navigation-driven NPC authority tests",
    );
    npc_feature_test_step.dependOn(&run_npc_feature_tests.step);

    const population_contract_tests = b.addTest(.{
        .root_module = population_contract_module,
    });
    const run_population_contract_tests = b.addRunArtifact(
        population_contract_tests,
    );
    const population_contract_test_step = b.step(
        "test-population-contract",
        "Run authored population value contract tests",
    );
    population_contract_test_step.dependOn(&run_population_contract_tests.step);

    const sandbox_population_catalog_tests = b.addTest(.{
        .root_module = sandbox_population_catalog_module,
    });
    const run_sandbox_population_catalog_tests = b.addRunArtifact(
        sandbox_population_catalog_tests,
    );
    const sandbox_population_catalog_test_step = b.step(
        "test-sandbox-population-catalog",
        "Run exact authored roster, activity, destination, and placement admission tests",
    );
    sandbox_population_catalog_test_step.dependOn(
        &run_sandbox_population_catalog_tests.step,
    );

    const sandbox_population_catalog_host_tests = b.addTest(.{
        .root_module = sandbox_population_catalog_host_test_module,
    });
    const run_sandbox_population_catalog_host_tests = b.addRunArtifact(
        sandbox_population_catalog_host_tests,
    );
    const sandbox_population_catalog_host_test_step = b.step(
        "test-sandbox-population-placement",
        "Run native Jolt placement proof for sixteen authored activity poses",
    );
    sandbox_population_catalog_host_test_step.dependOn(
        &run_sandbox_population_catalog_host_tests.step,
    );

    const sandbox_population_tests = b.addTest(.{
        .root_module = sandbox_population_module,
    });
    const run_sandbox_population_tests = b.addRunArtifact(
        sandbox_population_tests,
    );
    const sandbox_population_test_step = b.step(
        "test-sandbox-population",
        "Run deterministic member, activity, slot, and replacement intent authority tests",
    );
    sandbox_population_test_step.dependOn(&run_sandbox_population_tests.step);

    const test_s13_population_step = b.step(
        "test-s13-population",
        "Run S13 authored population contracts and catalog admission",
    );
    test_s13_population_step.dependOn(population_contract_test_step);
    test_s13_population_step.dependOn(sandbox_population_catalog_test_step);
    test_s13_population_step.dependOn(sandbox_population_catalog_host_test_step);
    test_s13_population_step.dependOn(sandbox_population_test_step);
    test_s13_population_step.dependOn(sandbox_navigation_test_step);

    const district_gpu_registry_tests = b.addTest(.{
        .root_module = district_gpu_registry_module,
    });
    const run_district_gpu_registry_tests = b.addRunArtifact(district_gpu_registry_tests);
    const district_gpu_registry_test_step = b.step(
        "test-district-gpu-registry",
        "Run bounded streamed district GPU registry tests",
    );
    district_gpu_registry_test_step.dependOn(&run_district_gpu_registry_tests.step);

    const district_scene_adapter_tests = b.addTest(.{
        .root_module = district_scene_adapter_module,
    });
    const run_district_scene_adapter_tests = b.addRunArtifact(district_scene_adapter_tests);
    const district_scene_adapter_test_step = b.step(
        "test-district-scene-adapter",
        "Run cooked-scene to GPU-staging adapter tests",
    );
    district_scene_adapter_test_step.dependOn(&run_district_scene_adapter_tests.step);

    const district_presentation_tests = b.addTest(.{
        .root_module = district_presentation_module,
    });
    const run_district_presentation_tests = b.addRunArtifact(district_presentation_tests);
    const district_presentation_test_step = b.step(
        "test-district-presentation",
        "Run district visual-host lifecycle coordination tests",
    );
    district_presentation_test_step.dependOn(&run_district_presentation_tests.step);

    const district_streaming_host_tests = b.addTest(.{
        .root_module = district_streaming_host_module,
    });
    const run_district_streaming_host_tests = b.addRunArtifact(
        district_streaming_host_tests,
    );
    const district_streaming_host_test_step = b.step(
        "test-district-streaming-host",
        "Run district streaming host ownership and lifecycle tests",
    );
    district_streaming_host_test_step.dependOn(
        &run_district_streaming_host_tests.step,
    );

    const sandbox_controls_tests = b.addTest(.{ .root_module = sandbox_controls_module });
    const run_sandbox_controls_tests = b.addRunArtifact(sandbox_controls_tests);
    const sandbox_controls_test_step = b.step(
        "test-sandbox-controls",
        "Run frame-to-tick action latch tests",
    );
    sandbox_controls_test_step.dependOn(&run_sandbox_controls_tests.step);

    const sandbox_product_population_host_tests = b.addTest(.{
        .root_module = sandbox_product_population_host_test_module,
    });
    const run_sandbox_product_population_host_tests = b.addRunArtifact(
        sandbox_product_population_host_tests,
    );
    const sandbox_product_population_host_test_step = b.step(
        "test-sandbox-product-population-host",
        "Run authored product population through the host-managed local session",
    );
    sandbox_product_population_host_test_step.dependOn(
        &run_sandbox_product_population_host_tests.step,
    );

    const sandbox_invocation_tests = b.addTest(.{
        .root_module = sandbox_invocation_module,
    });
    const run_sandbox_invocation_tests = b.addRunArtifact(sandbox_invocation_tests);
    const sandbox_invocation_test_step = b.step(
        "test-sandbox-invocation",
        "Run graphical sandbox invocation and installed-layout policy tests",
    );
    sandbox_invocation_test_step.dependOn(&run_sandbox_invocation_tests.step);

    const sandbox_host_contracts_tests = b.addTest(.{
        .root_module = sandbox_host_contracts_module,
    });
    const run_sandbox_host_contracts_tests = b.addRunArtifact(
        sandbox_host_contracts_tests,
    );
    const sandbox_host_contracts_test_step = b.step(
        "test-sandbox-host-contracts",
        "Run the immutable graphical sandbox DTO boundary tests",
    );
    sandbox_host_contracts_test_step.dependOn(
        &run_sandbox_host_contracts_tests.step,
    );

    const developer_controls_tests = b.addTest(.{ .root_module = developer_controls_module });
    const run_developer_controls_tests = b.addRunArtifact(developer_controls_tests);
    const developer_controls_test_step = b.step(
        "test-developer-controls",
        "Run host-only pause, step, and time-scale control tests",
    );
    developer_controls_test_step.dependOn(&run_developer_controls_tests.step);

    const developer_diagnostics_tests = b.addTest(.{
        .root_module = developer_diagnostics_module,
    });
    const run_developer_diagnostics_tests = b.addRunArtifact(developer_diagnostics_tests);
    const developer_diagnostics_test_step = b.step(
        "test-developer-diagnostics",
        "Run backend-neutral developer snapshot and export tests",
    );
    developer_diagnostics_test_step.dependOn(&run_developer_diagnostics_tests.step);

    const developer_profile_tests = b.addTest(.{ .root_module = developer_profile_module });
    const run_developer_profile_tests = b.addRunArtifact(developer_profile_tests);
    const developer_profile_test_step = b.step(
        "test-developer-profile",
        "Run bounded fixed-phase profiling ring tests",
    );
    developer_profile_test_step.dependOn(&run_developer_profile_tests.step);

    const developer_visualization_tests = b.addTest(.{
        .root_module = developer_visualization_module,
    });
    const run_developer_visualization_tests = b.addRunArtifact(
        developer_visualization_tests,
    );
    const developer_visualization_test_step = b.step(
        "test-developer-visualization",
        "Run typed physics-debug and profiling host-control tests",
    );
    developer_visualization_test_step.dependOn(
        &run_developer_visualization_tests.step,
    );

    const sandbox_developer_host_tests = b.addTest(.{
        .root_module = sandbox_developer_host_test_module,
    });
    const run_sandbox_developer_host_tests = b.addRunArtifact(
        sandbox_developer_host_tests,
    );
    const sandbox_developer_host_test_step = b.step(
        "test-sandbox-developer-host",
        "Run graphical developer-owner boundary and optional-resource tests",
    );
    sandbox_developer_host_test_step.dependOn(
        &run_sandbox_developer_host_tests.step,
    );

    const sandbox_authoring_tests = b.addTest(.{ .root_module = sandbox_authoring_module });
    const run_sandbox_authoring_tests = b.addRunArtifact(sandbox_authoring_tests);
    const sandbox_authoring_test_step = b.step(
        "test-sandbox-authoring",
        "Run bounded persistent-selection and undo/redo session tests",
    );
    sandbox_authoring_test_step.dependOn(&run_sandbox_authoring_tests.step);

    const sandbox_save_tests = b.addTest(.{ .root_module = sandbox_save_module });
    const run_sandbox_save_tests = b.addRunArtifact(sandbox_save_tests);
    const sandbox_save_test_step = b.step(
        "test-sandbox-save",
        "Run canonical exact-cohort save-envelope tests",
    );
    sandbox_save_test_step.dependOn(&run_sandbox_save_tests.step);

    const sandbox_persistence_tests = b.addTest(.{
        .root_module = sandbox_persistence_module,
    });
    const run_sandbox_persistence_tests = b.addRunArtifact(
        sandbox_persistence_tests,
    );
    const sandbox_persistence_test_step = b.step(
        "test-sandbox-persistence",
        "Run sandbox snapshot and durable-commit coordination tests",
    );
    sandbox_persistence_test_step.dependOn(
        &run_sandbox_persistence_tests.step,
    );

    const save_slots_tests = b.addTest(.{ .root_module = save_slots_module });
    const run_save_slots_tests = b.addRunArtifact(save_slots_tests);
    const save_slots_test_step = b.step(
        "test-save-slots",
        "Run macOS atomic save-slot and recovery tests",
    );
    save_slots_test_step.dependOn(&run_save_slots_tests.step);

    const simulation_snapshot_tests = b.addTest(.{
        .root_module = simulation_snapshot_module,
    });
    const run_simulation_snapshot_tests = b.addRunArtifact(
        simulation_snapshot_tests,
    );
    const simulation_snapshot_test_step = b.step(
        "test-simulation-snapshot",
        "Run canonical simulation snapshot codec and preflight tests",
    );
    simulation_snapshot_test_step.dependOn(
        &run_simulation_snapshot_tests.step,
    );

    const sandbox_simulation_tests = b.addTest(.{ .root_module = sandbox_simulation_module });
    const run_sandbox_simulation_tests = b.addRunArtifact(sandbox_simulation_tests);
    const sandbox_simulation_test_step = b.step(
        "test-simulation",
        "Run the concrete sandbox/Jolt composition tests",
    );
    sandbox_simulation_test_step.dependOn(&run_sandbox_simulation_tests.step);
    const session_budgets_tests = b.addTest(.{ .root_module = session_budgets_module });
    const run_session_budgets_tests = b.addRunArtifact(session_budgets_tests);
    const session_identity_tests = b.addTest(.{ .root_module = session_identity_module });
    const run_session_identity_tests = b.addRunArtifact(session_identity_tests);
    const session_protocol_tests = b.addTest(.{ .root_module = session_protocol_module });
    const run_session_protocol_tests = b.addRunArtifact(session_protocol_tests);
    const combat_presentation_tests = b.addTest(.{ .root_module = combat_presentation_module });
    const run_combat_presentation_tests = b.addRunArtifact(combat_presentation_tests);
    const gameplay_admission_tests = b.addTest(.{ .root_module = gameplay_admission_module });
    const run_gameplay_admission_tests = b.addRunArtifact(gameplay_admission_tests);
    const snapshot_source_tests = b.addTest(.{ .root_module = snapshot_source_module });
    const run_snapshot_source_tests = b.addRunArtifact(snapshot_source_tests);
    const session_transport_policy_tests = b.addTest(.{
        .root_module = session_transport_policy_module,
    });
    const run_session_transport_policy_tests = b.addRunArtifact(
        session_transport_policy_tests,
    );
    const reconnect_policy_tests = b.addTest(.{ .root_module = reconnect_policy_module });
    const run_reconnect_policy_tests = b.addRunArtifact(reconnect_policy_tests);
    const client_clock_tests = b.addTest(.{ .root_module = client_clock_module });
    const run_client_clock_tests = b.addRunArtifact(client_clock_tests);
    const session_prediction_tests = b.addTest(.{ .root_module = session_prediction_module });
    const run_session_prediction_tests = b.addRunArtifact(session_prediction_tests);
    const vehicle_prediction_tests = b.addTest(.{ .root_module = vehicle_prediction_module });
    const run_vehicle_prediction_tests = b.addRunArtifact(vehicle_prediction_tests);
    const impaired_link_tests = b.addTest(.{ .root_module = impaired_link_module });
    const run_impaired_link_tests = b.addRunArtifact(impaired_link_tests);
    const session_local_link_tests = b.addTest(.{ .root_module = session_local_link_module });
    const run_session_local_link_tests = b.addRunArtifact(session_local_link_tests);
    const replicated_world_tests = b.addTest(.{ .root_module = replicated_world_module });
    const run_replicated_world_tests = b.addRunArtifact(replicated_world_tests);
    const session_client_tests = b.addTest(.{ .root_module = session_client_module });
    const run_session_client_tests = b.addRunArtifact(session_client_tests);
    const local_solo_session_tests = b.addTest(.{ .root_module = local_solo_session_module });
    const run_local_solo_session_tests = b.addRunArtifact(local_solo_session_tests);
    const session_authority_tests = b.addTest(.{ .root_module = session_authority_module });
    const run_session_authority_tests = b.addRunArtifact(session_authority_tests);
    const session_room_tests = b.addTest(.{ .root_module = session_room_module });
    const run_session_room_tests = b.addRunArtifact(session_room_tests);
    const room_coordinator_tests = b.addTest(.{ .root_module = room_coordinator_module });
    const run_room_coordinator_tests = b.addRunArtifact(room_coordinator_tests);
    const room_ticket_tests = b.addTest(.{ .root_module = room_ticket_module });
    const run_room_ticket_tests = b.addRunArtifact(room_ticket_tests);
    const gns_direct_test_module = b.createModule(.{
        .root_source_file = b.path("src/adapters/transport/gns_direct.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "session_budgets", .module = session_budgets_module }},
    });
    gns_direct_test_module.addIncludePath(b.path("src/adapters/transport"));
    gns_direct_test_module.addIncludePath(gns.include);
    const gns_direct_tests = b.addTest(.{ .root_module = gns_direct_test_module });
    gns.link(gns_direct_tests);
    const run_gns_direct_tests = b.addRunArtifact(gns_direct_tests);
    const session_contract_test_step = b.step(
        "test-session-contracts",
        "Run MP0 identity, protocol, budget, and local-link tests",
    );
    session_contract_test_step.dependOn(&run_session_budgets_tests.step);
    session_contract_test_step.dependOn(&run_session_identity_tests.step);
    session_contract_test_step.dependOn(&run_session_protocol_tests.step);
    session_contract_test_step.dependOn(&run_combat_presentation_tests.step);
    session_contract_test_step.dependOn(&run_gameplay_admission_tests.step);
    session_contract_test_step.dependOn(&run_snapshot_source_tests.step);
    session_contract_test_step.dependOn(&run_session_transport_policy_tests.step);
    session_contract_test_step.dependOn(&run_reconnect_policy_tests.step);
    session_contract_test_step.dependOn(&run_client_clock_tests.step);
    session_contract_test_step.dependOn(&run_session_prediction_tests.step);
    session_contract_test_step.dependOn(&run_vehicle_prediction_tests.step);
    session_contract_test_step.dependOn(&run_impaired_link_tests.step);
    session_contract_test_step.dependOn(&run_session_local_link_tests.step);
    session_contract_test_step.dependOn(&run_replicated_world_tests.step);
    session_contract_test_step.dependOn(&run_session_client_tests.step);
    session_contract_test_step.dependOn(&run_local_solo_session_tests.step);
    session_contract_test_step.dependOn(&run_session_authority_tests.step);
    session_contract_test_step.dependOn(&run_session_room_tests.step);
    session_contract_test_step.dependOn(&run_room_coordinator_tests.step);
    session_contract_test_step.dependOn(&run_room_ticket_tests.step);
    verify_mp3_step.dependOn(session_contract_test_step);
    const gns_test_step = b.step(
        "test-gns",
        "Build the pinned GNS integration and run its narrow adapter tests",
    );
    gns_test_step.dependOn(&run_gns_direct_tests.step);

    const sandbox_interaction_tests = b.addTest(.{
        .root_module = sandbox_interaction_module,
    });
    const run_sandbox_interaction_tests = b.addRunArtifact(
        sandbox_interaction_tests,
    );
    const sandbox_interaction_test_step = b.step(
        "test-sandbox-interaction",
        "Run bounded host/editor interaction producer tests",
    );
    sandbox_interaction_test_step.dependOn(
        &run_sandbox_interaction_tests.step,
    );

    const sandbox_replay_tests = b.addTest(.{ .root_module = sandbox_replay_module });
    const run_sandbox_replay_tests = b.addRunArtifact(sandbox_replay_tests);
    const sandbox_replay_test_step = b.step(
        "test-replay",
        "Run same-cohort flight-recorder envelope and cursor tests",
    );
    sandbox_replay_test_step.dependOn(&run_sandbox_replay_tests.step);

    const district_content_catalog_tests = b.addTest(.{
        .root_module = district_content_catalog_module,
    });
    const run_district_content_catalog_tests = b.addRunArtifact(
        district_content_catalog_tests,
    );
    const district_content_catalog_test_step = b.step(
        "test-district-content-catalog",
        "Run canonical district catalog admission boundary tests",
    );
    district_content_catalog_test_step.dependOn(
        &run_district_content_catalog_tests.step,
    );

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Keep the Jolt adapter independently testable. This target intentionally
    // links no SDL, renderer, shader, or editor dependencies.
    const physics_tests = b.addTest(.{ .root_module = jolt_physics_module });
    const run_physics_tests = b.addRunArtifact(physics_tests);
    const physics_test_step = b.step("test-physics", "Run isolated Jolt adapter tests");
    physics_test_step.dependOn(&run_physics_tests.step);
    const verify_s10_step = b.step(
        "verify-s10",
        "Run focused and graphical S10 damage/death/respawn acceptance",
    );
    verify_s10_step.dependOn(verify_s10_listen_step);
    verify_s10_step.dependOn(verify_s10_dedicated_step);
    verify_s10_step.dependOn(session_contract_test_step);
    verify_s10_step.dependOn(vitals_feature_test_step);
    verify_s10_step.dependOn(physics_test_step);

    const verify_m5_architecture_command = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_m5_architecture.sh"),
    });
    const verify_m5_architecture_step = b.step(
        "verify-m5-architecture",
        "Enforce M5 client/authority, presentation, persistence, and closure boundaries",
    );
    verify_m5_architecture_step.dependOn(
        &verify_m5_architecture_command.step,
    );
    const verify_m6_architecture_command = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_m6_architecture.sh"),
    });
    const verify_m6_architecture_step = b.step(
        "verify-m6-architecture",
        "Enforce transactional authority-cycle, delivery, receipt, replay, and durable boundaries",
    );
    verify_m6_architecture_step.dependOn(
        &verify_m6_architecture_command.step,
    );
    const verify_mp6_architecture_command = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_mp6_architecture.sh"),
    });
    const verify_mp6_architecture_step = b.step(
        "verify-mp6-room-architecture",
        "Enforce coordinator, secret, placement, presentation, and Steam-free MP6 boundaries",
    );
    verify_mp6_architecture_step.dependOn(
        &verify_mp6_architecture_command.step,
    );

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(verify_m5_architecture_step);
    test_step.dependOn(verify_m6_architecture_step);
    test_step.dependOn(verify_mp6_architecture_step);
    test_step.dependOn(&cohort_verification.run.step);
    test_step.dependOn(&cohort_verification.tests.step);
    test_step.dependOn(&run_content_tests.step);
    test_step.dependOn(&verify_cooked_bundle.step);
    test_step.dependOn(&run_content_cooker_tests.step);
    test_step.dependOn(&run_content_catalog_cooker_tests.step);
    test_step.dependOn(&verify_cooked_catalog.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_contracts_tests.step);
    test_step.dependOn(&run_sandbox_value_contracts_tests.step);
    test_step.dependOn(&run_crate_feature_tests.step);
    test_step.dependOn(&run_character_feature_tests.step);
    test_step.dependOn(&run_vitals_contract_tests.step);
    test_step.dependOn(&run_vitals_feature_tests.step);
    test_step.dependOn(&run_npc_encounter_contract_tests.step);
    test_step.dependOn(&run_npc_encounter_feature_tests.step);
    test_step.dependOn(&run_driver_contract_tests.step);
    test_step.dependOn(&run_interaction_contract_tests.step);
    test_step.dependOn(&run_vehicle_feature_tests.step);
    test_step.dependOn(&run_district_contract_tests.step);
    test_step.dependOn(&run_navigation_contract_tests.step);
    test_step.dependOn(&run_navigation_planner_tests.step);
    test_step.dependOn(&run_sandbox_navigation_tests.step);
    test_step.dependOn(&run_district_worker_tests.step);
    test_step.dependOn(&run_district_replay_loader_tests.step);
    test_step.dependOn(&run_district_feature_tests.step);
    test_step.dependOn(&run_interaction_feature_tests.step);
    test_step.dependOn(&run_npc_feature_tests.step);
    test_step.dependOn(&run_population_contract_tests.step);
    test_step.dependOn(&run_sandbox_population_catalog_tests.step);
    test_step.dependOn(&run_sandbox_population_catalog_host_tests.step);
    test_step.dependOn(&run_sandbox_population_tests.step);
    test_step.dependOn(&run_district_gpu_registry_tests.step);
    test_step.dependOn(&run_district_scene_adapter_tests.step);
    test_step.dependOn(&run_district_presentation_tests.step);
    test_step.dependOn(&run_district_streaming_host_tests.step);
    test_step.dependOn(&run_sandbox_controls_tests.step);
    test_step.dependOn(&run_sandbox_product_population_host_tests.step);
    test_step.dependOn(&run_sandbox_invocation_tests.step);
    test_step.dependOn(&run_sandbox_host_contracts_tests.step);
    test_step.dependOn(&run_developer_controls_tests.step);
    test_step.dependOn(&run_developer_diagnostics_tests.step);
    test_step.dependOn(&run_developer_profile_tests.step);
    test_step.dependOn(&run_developer_visualization_tests.step);
    test_step.dependOn(&run_sandbox_developer_host_tests.step);
    test_step.dependOn(&run_sandbox_authoring_tests.step);
    test_step.dependOn(&run_sandbox_save_tests.step);
    test_step.dependOn(&run_sandbox_persistence_tests.step);
    test_step.dependOn(&run_save_slots_tests.step);
    test_step.dependOn(&run_simulation_snapshot_tests.step);
    test_step.dependOn(&run_sandbox_simulation_tests.step);
    test_step.dependOn(&run_session_budgets_tests.step);
    test_step.dependOn(&run_session_identity_tests.step);
    test_step.dependOn(&run_session_protocol_tests.step);
    test_step.dependOn(&run_gameplay_admission_tests.step);
    test_step.dependOn(&run_snapshot_source_tests.step);
    test_step.dependOn(&run_session_transport_policy_tests.step);
    test_step.dependOn(&run_reconnect_policy_tests.step);
    test_step.dependOn(&run_client_clock_tests.step);
    test_step.dependOn(&run_session_prediction_tests.step);
    test_step.dependOn(&run_vehicle_prediction_tests.step);
    test_step.dependOn(&run_impaired_link_tests.step);
    test_step.dependOn(&run_interaction_validation_tests.step);
    test_step.dependOn(&run_session_local_link_tests.step);
    test_step.dependOn(&run_replicated_world_tests.step);
    test_step.dependOn(&run_session_client_tests.step);
    test_step.dependOn(&run_local_solo_session_tests.step);
    test_step.dependOn(&run_session_authority_tests.step);
    test_step.dependOn(&run_session_room_tests.step);
    test_step.dependOn(&run_room_coordinator_tests.step);
    test_step.dependOn(&run_room_ticket_tests.step);
    test_step.dependOn(&run_gns_direct_tests.step);
    test_step.dependOn(&run_sandbox_interaction_tests.step);
    test_step.dependOn(&run_sandbox_replay_tests.step);
    test_step.dependOn(&run_district_content_catalog_tests.step);
    test_step.dependOn(&replay_tool_exe.step);
    test_step.dependOn(&verify_replay_linkage.step);
    test_step.dependOn(&save_tool_exe.step);
    test_step.dependOn(&verify_save_linkage.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_physics_tests.step);
    test_step.dependOn(&run_headless_tests.step);
    test_step.dependOn(&run_external_producers_tests.step);
    test_step.dependOn(&run_headless_authority_tests.step);
    test_step.dependOn(&run_shader_contract_tests.step);
    test_step.dependOn(&verify_validation_boundary.step);
    test_step.dependOn(&run_validation_boundary_tests.step);
    test_step.dependOn(verify_installed_validation_step);
    test_step.dependOn(&run_physics_debug_gpu_tests.step);
    test_step.dependOn(&verify_headless_boundary.step);
    test_step.dependOn(&verify_headless_linkage.step);
    test_step.dependOn(&run_headless_boundary_tests.step);
    test_step.dependOn(&run_headless_linkage_tests.step);
    test_step.dependOn(&s7_measure_exe.step);
    test_step.dependOn(&run_s7_measure_tests.step);
    test_step.dependOn(&s8_measure_exe.step);
    test_step.dependOn(&run_s8_measure_tests.step);
    test_step.dependOn(&s11_measure_exe.step);
    test_step.dependOn(&run_s11_measure_tests.step);
    test_step.dependOn(&vehicle_dynamics_exe.step);
    test_step.dependOn(&run_vehicle_dynamics_tests.step);
    test_step.dependOn(&m3_soak_exe.step);
    test_step.dependOn(&run_m3_soak_tests.step);
    test_step.dependOn(&title_renderer_contracts.step);

    const test_m5_cohesion_step = b.step(
        "test-m5-cohesion",
        "Run focused embedded-session cohesion, clock, projection, and ownership contracts",
    );
    test_m5_cohesion_step.dependOn(&run_mod_tests.step);
    test_m5_cohesion_step.dependOn(&run_exe_tests.step);
    test_m5_cohesion_step.dependOn(&run_sandbox_invocation_tests.step);
    test_m5_cohesion_step.dependOn(&run_sandbox_host_contracts_tests.step);
    test_m5_cohesion_step.dependOn(&run_sandbox_value_contracts_tests.step);
    test_m5_cohesion_step.dependOn(&run_sandbox_developer_host_tests.step);
    test_m5_cohesion_step.dependOn(&run_district_streaming_host_tests.step);
    test_m5_cohesion_step.dependOn(&run_sandbox_persistence_tests.step);
    test_m5_cohesion_step.dependOn(&run_simulation_snapshot_tests.step);
    test_m5_cohesion_step.dependOn(&run_sandbox_simulation_tests.step);
    test_m5_cohesion_step.dependOn(&run_gameplay_admission_tests.step);
    test_m5_cohesion_step.dependOn(&run_snapshot_source_tests.step);
    test_m5_cohesion_step.dependOn(&run_session_local_link_tests.step);
    test_m5_cohesion_step.dependOn(&run_replicated_world_tests.step);
    test_m5_cohesion_step.dependOn(&run_session_client_tests.step);
    test_m5_cohesion_step.dependOn(&run_local_solo_session_tests.step);
    test_m5_cohesion_step.dependOn(&run_session_authority_tests.step);

    const test_m6_transaction_step = b.step(
        "test-m6-transaction",
        "Run focused authority transaction, delivery, receipt, replay, and durable contracts",
    );
    test_m6_transaction_step.dependOn(verify_m6_architecture_step);
    test_m6_transaction_step.dependOn(&run_session_protocol_tests.step);
    test_m6_transaction_step.dependOn(&run_snapshot_source_tests.step);
    test_m6_transaction_step.dependOn(&run_session_transport_policy_tests.step);
    test_m6_transaction_step.dependOn(&run_impaired_link_tests.step);
    test_m6_transaction_step.dependOn(&run_session_local_link_tests.step);
    test_m6_transaction_step.dependOn(&run_session_client_tests.step);
    test_m6_transaction_step.dependOn(&run_local_solo_session_tests.step);
    test_m6_transaction_step.dependOn(&run_session_authority_tests.step);
    test_m6_transaction_step.dependOn(&run_sandbox_persistence_tests.step);

    const test_mp6_room_step = b.step(
        "test-mp6-room",
        "Run focused room coordinator, ticket, host, lifecycle, and architecture contracts",
    );
    test_mp6_room_step.dependOn(verify_mp6_architecture_step);
    test_mp6_room_step.dependOn(&run_session_room_tests.step);
    test_mp6_room_step.dependOn(&run_room_coordinator_tests.step);
    test_mp6_room_step.dependOn(&run_room_ticket_tests.step);
    test_mp6_room_step.dependOn(mp6_host_test_step);
    test_mp6_room_step.dependOn(verify_mp6_lifecycle_step);

    const verify_source_package_command = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_source_package.sh"),
    });
    verify_source_package_command.setEnvironmentVariable(
        "ZIG",
        b.graph.zig_exe,
    );
    const verify_source_package_step = b.step(
        "verify-source-package",
        "Verify filtered source-package membership and executable source closure",
    );
    verify_source_package_step.dependOn(&verify_source_package_command.step);

    const test_s12_navigation_step = b.step(
        "test-s12-navigation",
        "Run S12 destination, planner, world, recovery, persistence, replay, and placement contracts",
    );
    test_s12_navigation_step.dependOn(content_cooker_test_step);
    test_s12_navigation_step.dependOn(district_content_catalog_test_step);
    test_s12_navigation_step.dependOn(navigation_contract_test_step);
    test_s12_navigation_step.dependOn(navigation_planner_test_step);
    test_s12_navigation_step.dependOn(sandbox_navigation_test_step);
    test_s12_navigation_step.dependOn(district_feature_test_step);
    test_s12_navigation_step.dependOn(npc_feature_test_step);
    test_s12_navigation_step.dependOn(simulation_snapshot_test_step);
    test_s12_navigation_step.dependOn(sandbox_simulation_test_step);
    test_s12_navigation_step.dependOn(sandbox_replay_test_step);
    test_s12_navigation_step.dependOn(developer_diagnostics_test_step);
    test_s12_navigation_step.dependOn(session_contract_test_step);

    const s12_measure_root_module = b.createModule(.{
        .root_source_file = b.path("tools/s12_measure.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "content", .module = content_module },
            .{ .name = "district_content_catalog", .module = district_content_catalog_module },
            .{ .name = "navigation_contract", .module = navigation_contract_module },
            .{ .name = "navigation_planner", .module = navigation_planner_module },
            .{ .name = "sandbox_host_contracts", .module = sandbox_host_contracts_module },
            .{ .name = "sandbox_navigation", .module = sandbox_navigation_module },
            .{ .name = "sandbox_simulation", .module = sandbox_simulation_module },
        },
    });
    const s12_measure_exe = b.addExecutable(.{
        .name = "incinerator_s12_measure",
        .root_module = s12_measure_root_module,
    });
    const run_s12_measure = b.addRunArtifact(s12_measure_exe);
    run_s12_measure.addArg(b.getInstallPath(
        .prefix,
        "share/incinerator/content",
    ));
    run_s12_measure.step.dependOn(b.getInstallStep());
    const s12_measure_tests = b.addTest(.{ .root_module = s12_measure_root_module });
    const run_s12_measure_tests = b.addRunArtifact(s12_measure_tests);
    const s12_measure_test_step = b.step(
        "test-s12-measure",
        "Run S12 navigation measurement methodology tests",
    );
    s12_measure_test_step.dependOn(&run_s12_measure_tests.step);

    const measure_s12_step = b.step(
        "measure-s12",
        "Run separated S12 planner-wave and representative Jolt movement measurement",
    );
    measure_s12_step.dependOn(&run_s12_measure.step);

    const s13_measure_root_module = b.createModule(.{
        .root_source_file = b.path("tools/s13_measure.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "incinerator_engine", .module = mod },
            .{ .name = "district_contract", .module = district_contract_module },
            .{ .name = "jolt_physics", .module = jolt_physics_module },
            .{ .name = "npc_contract", .module = npc_contract_module },
            .{ .name = "population_contract", .module = population_contract_module },
            .{ .name = "sandbox_population", .module = sandbox_population_module },
            .{ .name = "sandbox_population_catalog", .module = sandbox_population_catalog_module },
            .{ .name = "sandbox_district_recipe", .module = sandbox_district_recipe_module },
            .{ .name = "session_budgets", .module = session_budgets_module },
            .{ .name = "session_protocol", .module = session_protocol_module },
        },
    });
    const s13_measure_exe = b.addExecutable(.{
        .name = "incinerator_s13_measure",
        .root_module = s13_measure_root_module,
    });
    const s13_measure_check_step = b.step(
        "check-s13-measure",
        "Compile the SDL-free S13 authored-population measurement",
    );
    s13_measure_check_step.dependOn(&s13_measure_exe.step);
    const run_s13_measure = b.addRunArtifact(s13_measure_exe);
    const measure_s13_step = b.step(
        "measure-s13",
        "Run the ReleaseFast S13 owner, physical, synthetic, persistence, and projection measurement",
    );
    measure_s13_step.dependOn(&run_s13_measure.step);
    const s13_measure_tests = b.addTest(.{ .root_module = s13_measure_root_module });
    const run_s13_measure_tests = b.addRunArtifact(s13_measure_tests);
    const s13_measure_test_step = b.step(
        "test-s13-measure",
        "Run S13 authored-population measurement methodology tests",
    );
    s13_measure_test_step.dependOn(&run_s13_measure_tests.step);

    const installed_s12_smoke_step = b.step(
        "smoke-installed-s12-macos",
        "Run installed S12 navigation/world and inherited combat Metal smokes",
    );
    installed_s12_smoke_step.dependOn(installed_s8_smoke_step);
    installed_s12_smoke_step.dependOn(installed_s11_smoke_step);

    const verify_s11_step = b.step(
        "verify-s11",
        "Run authoritative NPC encounter, durability, network, and graphical acceptance",
    );
    verify_s11_step.dependOn(npc_encounter_test_step);
    verify_s11_step.dependOn(sandbox_population_test_step);
    verify_s11_step.dependOn(vitals_feature_test_step);
    verify_s11_step.dependOn(simulation_snapshot_test_step);
    verify_s11_step.dependOn(sandbox_simulation_test_step);
    verify_s11_step.dependOn(sandbox_replay_test_step);
    verify_s11_step.dependOn(session_contract_test_step);
    verify_s11_step.dependOn(developer_diagnostics_test_step);
    verify_s11_step.dependOn(s11_measure_test_step);
    verify_s11_step.dependOn(verify_mp4d_step);
    verify_s11_step.dependOn(verify_mp6_lifecycle_step);
    verify_s11_step.dependOn(check_mp6_step);
    verify_s11_step.dependOn(check_validation_step);
    verify_s11_step.dependOn(verify_source_package_step);
    verify_s11_step.dependOn(verify_s11_listen_step);
    verify_s11_step.dependOn(verify_s11_dedicated_step);
    verify_s11_step.dependOn(installed_s11_smoke_step);
    verify_s11_step.dependOn(sandbox_product_population_host_test_step);

    const verify_s12_step = b.step(
        "verify-s12",
        "Run complete S12 destination navigation, evidence, inherited gameplay, and macOS acceptance",
    );
    verify_s12_step.dependOn(test_s12_navigation_step);
    verify_s12_step.dependOn(s8_measure_test_step);
    verify_s12_step.dependOn(s12_measure_test_step);
    verify_s12_step.dependOn(verify_s11_step);
    verify_s12_step.dependOn(verify_incident_hardening_step);
    verify_s12_step.dependOn(check_validation_step);
    verify_s12_step.dependOn(verify_source_package_step);
    verify_s12_step.dependOn(installed_s12_smoke_step);

    const verify_s13_step = b.step(
        "verify-s13",
        "Run complete S13 authored-population, lifecycle, evidence, and macOS acceptance",
    );
    verify_s13_step.dependOn(test_s13_population_step);
    verify_s13_step.dependOn(test_s12_navigation_step);
    verify_s13_step.dependOn(s12_measure_test_step);
    verify_s13_step.dependOn(s13_measure_test_step);
    verify_s13_step.dependOn(sandbox_product_population_host_test_step);
    verify_s13_step.dependOn(simulation_snapshot_test_step);
    verify_s13_step.dependOn(sandbox_replay_test_step);
    verify_s13_step.dependOn(session_contract_test_step);
    verify_s13_step.dependOn(developer_diagnostics_test_step);
    verify_s13_step.dependOn(interaction_matrix_step);
    verify_s13_step.dependOn(verify_s11_step);
    verify_s13_step.dependOn(verify_incident_hardening_step);
    verify_s13_step.dependOn(check_validation_step);
    verify_s13_step.dependOn(verify_source_package_step);
    verify_s13_step.dependOn(installed_s13_smoke_step);

    const interaction_validation_audit_command = b.addSystemCommand(&.{
        "bash",
        b.pathFromRoot("tools/verify_interaction_validation.sh"),
    });
    const verify_interactions_step = b.step(
        "verify-interactions",
        "Run the accepted interaction scenario, topology, fault, soak, Metal, and documentation gate",
    );
    verify_interactions_step.dependOn(verify_s11_step);
    verify_interactions_step.dependOn(interaction_matrix_step);
    verify_interactions_step.dependOn(interaction_routine_soak_step);
    verify_interactions_step.dependOn(verify_m5_architecture_step);
    verify_interactions_step.dependOn(&interaction_validation_audit_command.step);

    const verify_m5_step = b.step(
        "verify-m5",
        "Run the complete native macOS M5 client/authority cohesion gate",
    );
    verify_m5_step.dependOn(test_m5_cohesion_step);
    verify_m5_step.dependOn(verify_m5_architecture_step);
    verify_m5_step.dependOn(verify_m4_step);
    verify_m5_step.dependOn(check_validation_step);
    verify_m5_step.dependOn(macos_readiness_step);
    verify_m5_step.dependOn(verify_source_package_step);
    const verify_m5_cold_command = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "-Dproduct=headless",
        "test",
        "-j1",
        "--summary",
        "all",
    });
    verify_m5_cold_command.setCwd(b.path("."));
    const verify_m5_cold_step = b.step(
        "verify-m5-cold",
        "Run the isolated cold-authority product graph and tests",
    );
    verify_m5_cold_step.dependOn(&verify_m5_cold_command.step);
    verify_m5_step.dependOn(verify_m5_cold_step);
    const verify_m6_step = b.step(
        "verify-m6",
        "Run the complete Apple Silicon macOS M6 transactional authority gate",
    );
    verify_m6_step.dependOn(test_m6_transaction_step);
    verify_m6_step.dependOn(verify_m5_step);
    const verify_mp6_room_step = b.step(
        "verify-mp6-room",
        "Run the complete Apple Silicon macOS MP6 playable room-flow gate",
    );
    verify_mp6_room_step.dependOn(test_mp6_room_step);
    verify_mp6_room_step.dependOn(verify_mp6_dedicated_step);
    verify_mp6_room_step.dependOn(verify_mp6_listen_step);
    verify_mp6_room_step.dependOn(verify_m6_step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

// =============================================================================
// Shader Compilation
// =============================================================================
// Compiles GLSL through a SPIR-V intermediate into Metal Shading Language, the
// only active SDL GPU backend contract.

const ShaderFormat = enum {
    msl,

    fn fileExtension(_: ShaderFormat) []const u8 {
        return "metal";
    }

    fn entrypoint(_: ShaderFormat) []const u8 {
        return "main0";
    }

    fn driver(_: ShaderFormat) []const u8 {
        return "metal";
    }
};

const ShaderBuild = struct {
    module: *std.Build.Module,
    validation_module: *std.Build.Module,
    reflection_module: *std.Build.Module,
    step: *std.Build.Step,
};

const ShaderTools = struct {
    glslc: []const u8,
    spirv_cross: []const u8,
};

const CompiledShader = struct {
    spirv: std.Build.LazyPath,
    target: std.Build.LazyPath,
};

fn buildShaders(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tools: ShaderTools,
) ShaderBuild {
    const format: ShaderFormat = .msl;

    const shader_step = b.step("shaders", "Compile GLSL shaders into Metal Shading Language");
    const generated = b.addWriteFiles();

    const triangle_vertex = compileShader(b, tools, "shaders/triangle.vert", "triangle.vert");
    const triangle_fragment = compileShader(b, tools, "shaders/triangle.frag", "triangle.frag");
    const model_vertex = compileShader(b, tools, "shaders/model.vert", "model.vert");
    const model_fragment = compileShader(b, tools, "shaders/model.frag", "model.frag");
    const visibility_fragment = compileShader(
        b,
        tools,
        "shaders/visibility.frag",
        "visibility.frag",
    );
    const neural_primitive_vertex = compileShader(
        b,
        tools,
        "shaders/neural_primitive.vert",
        "neural_primitive.vert",
    );
    const neural_primitive_fragment = compileShader(
        b,
        tools,
        "shaders/neural_primitive.frag",
        "neural_primitive.frag",
    );
    const neural_model_vertex = compileShader(
        b,
        tools,
        "shaders/neural_model.vert",
        "neural_model.vert",
    );
    const neural_model_fragment = compileShader(
        b,
        tools,
        "shaders/neural_model.frag",
        "neural_model.frag",
    );

    const extension = format.fileExtension();
    _ = generated.addCopyFile(triangle_vertex.target, b.fmt("triangle.vert.{s}", .{extension}));
    _ = generated.addCopyFile(triangle_fragment.target, b.fmt("triangle.frag.{s}", .{extension}));
    _ = generated.addCopyFile(model_vertex.target, b.fmt("model.vert.{s}", .{extension}));
    _ = generated.addCopyFile(model_fragment.target, b.fmt("model.frag.{s}", .{extension}));
    _ = generated.addCopyFile(
        visibility_fragment.target,
        b.fmt("visibility.frag.{s}", .{extension}),
    );
    _ = generated.addCopyFile(neural_primitive_vertex.target, b.fmt("neural_primitive.vert.{s}", .{extension}));
    _ = generated.addCopyFile(neural_primitive_fragment.target, b.fmt("neural_primitive.frag.{s}", .{extension}));
    _ = generated.addCopyFile(neural_model_vertex.target, b.fmt("neural_model.vert.{s}", .{extension}));
    _ = generated.addCopyFile(neural_model_fragment.target, b.fmt("neural_model.frag.{s}", .{extension}));

    _ = generated.addCopyFile(reflectShader(b, tools, triangle_vertex.spirv, "triangle.vert"), "triangle.vert.json");
    _ = generated.addCopyFile(reflectShader(b, tools, triangle_fragment.spirv, "triangle.frag"), "triangle.frag.json");
    _ = generated.addCopyFile(reflectShader(b, tools, model_vertex.spirv, "model.vert"), "model.vert.json");
    _ = generated.addCopyFile(reflectShader(b, tools, model_fragment.spirv, "model.frag"), "model.frag.json");
    _ = generated.addCopyFile(
        reflectShader(b, tools, visibility_fragment.spirv, "visibility.frag"),
        "visibility.frag.json",
    );
    _ = generated.addCopyFile(reflectShader(b, tools, neural_primitive_vertex.spirv, "neural_primitive.vert"), "neural_primitive.vert.json");
    _ = generated.addCopyFile(reflectShader(b, tools, neural_primitive_fragment.spirv, "neural_primitive.frag"), "neural_primitive.frag.json");
    _ = generated.addCopyFile(reflectShader(b, tools, neural_model_vertex.spirv, "neural_model.vert"), "neural_model.vert.json");
    _ = generated.addCopyFile(reflectShader(b, tools, neural_model_fragment.spirv, "neural_model.frag"), "neural_model.frag.json");

    const module_source = generated.add("shader_assets.zig", b.fmt(
        \\pub const Format = enum {{ msl }};
        \\pub const format: Format = .{s};
        \\pub const entrypoint = "{s}";
        \\pub const driver = "{s}";
        \\pub const triangle_vertex = @embedFile("triangle.vert.{s}");
        \\pub const triangle_fragment = @embedFile("triangle.frag.{s}");
        \\pub const model_vertex = @embedFile("model.vert.{s}");
        \\pub const model_fragment = @embedFile("model.frag.{s}");
        \\pub const visibility_fragment = @embedFile("visibility.frag.{s}");
        \\pub const neural_primitive_vertex = @embedFile("neural_primitive.vert.{s}");
        \\pub const neural_primitive_fragment = @embedFile("neural_primitive.frag.{s}");
        \\pub const neural_model_vertex = @embedFile("neural_model.vert.{s}");
        \\pub const neural_model_fragment = @embedFile("neural_model.frag.{s}");
        \\
    , .{
        @tagName(format),
        format.entrypoint(),
        format.driver(),
        extension,
        extension,
        extension,
        extension,
        extension,
        extension,
        extension,
        extension,
        extension,
    }));

    const reflection_source = generated.add("shader_reflections.zig",
        \\pub const triangle_vertex = @embedFile("triangle.vert.json");
        \\pub const triangle_fragment = @embedFile("triangle.frag.json");
        \\pub const model_vertex = @embedFile("model.vert.json");
        \\pub const model_fragment = @embedFile("model.frag.json");
        \\pub const visibility_fragment = @embedFile("visibility.frag.json");
        \\pub const neural_primitive_vertex = @embedFile("neural_primitive.vert.json");
        \\pub const neural_primitive_fragment = @embedFile("neural_primitive.frag.json");
        \\pub const neural_model_vertex = @embedFile("neural_model.vert.json");
        \\pub const neural_model_fragment = @embedFile("neural_model.frag.json");
        \\
    );

    shader_step.dependOn(&generated.step);

    return .{
        .module = b.createModule(.{
            .root_source_file = module_source,
            .target = target,
            .optimize = optimize,
        }),
        .validation_module = b.createModule(.{
            .root_source_file = module_source,
            .target = b.graph.host,
            .optimize = optimize,
        }),
        .reflection_module = b.createModule(.{
            .root_source_file = reflection_source,
            .target = b.graph.host,
            .optimize = optimize,
        }),
        .step = shader_step,
    };
}

fn compileShader(
    b: *std.Build,
    tools: ShaderTools,
    source_path: []const u8,
    output_name: []const u8,
) CompiledShader {
    const glslc = b.addSystemCommand(&.{tools.glslc});
    glslc.addFileArg(b.path(source_path));
    glslc.addArg("-o");
    const spirv = glslc.addOutputFileArg(b.fmt("{s}.spv", .{output_name}));

    const spirv_cross = b.addSystemCommand(&.{tools.spirv_cross});
    spirv_cross.addFileArg(spirv);
    spirv_cross.addArg("--msl");
    spirv_cross.addArg("--output");
    return .{
        .spirv = spirv,
        .target = spirv_cross.addOutputFileArg(b.fmt("{s}.metal", .{output_name})),
    };
}

fn reflectShader(
    b: *std.Build,
    tools: ShaderTools,
    spirv: std.Build.LazyPath,
    output_name: []const u8,
) std.Build.LazyPath {
    const spirv_cross = b.addSystemCommand(&.{tools.spirv_cross});
    spirv_cross.addFileArg(spirv);
    spirv_cross.addArg("--reflect");
    spirv_cross.addArg("--output");
    return spirv_cross.addOutputFileArg(b.fmt("{s}.json", .{output_name}));
}
