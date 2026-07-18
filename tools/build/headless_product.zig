const std = @import("std");
const macos = @import("macos.zig");
const simulation_graph = @import("simulation_graph.zig");

/// Construct the cold Apple Silicon authority product and nothing else.
///
/// This function is entered before the client build resolves SDL, editor,
/// shader, source-asset, or visual-package dependencies. Keep every module and
/// step here on the explicit SDL-free authority graph.
pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    macos.requireAppleSilicon(b, target);

    const graph = simulation_graph.create(b, target, optimize);
    const cohort_verification = simulation_graph.addCohortVerification(b);
    const engine_module = graph.engine;
    const crate_contract_module = graph.crate_contract;
    const character_contract_module = graph.character_contract;
    const vehicle_contract_module = graph.vehicle_contract;
    const district_contract_module = graph.district_contract;
    const district_feature_contract_module = graph.district_feature_contract;
    const interaction_feature_contract_module = graph.interaction_feature_contract;
    const npc_contract_module = graph.npc_contract;
    const npc_encounter_contract_module = graph.npc_encounter_contract;
    const vitals_contract_module = graph.vitals_contract;
    const sandbox_host_contracts_module = graph.sandbox_host_contracts;
    const sandbox_diagnostics_contract_module = graph.sandbox_diagnostics_contract;
    const simulation_snapshot_module = graph.simulation_snapshot;
    const sandbox_simulation_module = graph.sandbox_simulation;
    const sandbox_replay_module = graph.sandbox_replay;
    const sandbox_authoring_module = graph.sandbox_authoring;
    const developer_diagnostics_module = graph.developer_diagnostics;
    const sandbox_save_module = graph.sandbox_save;
    const save_slots_module = graph.save_slots;

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
            .{ .name = "incinerator_engine", .module = engine_module },
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
    b.installArtifact(headless_exe);
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
    const install_example_config = b.addInstallFile(
        b.path("config/headless.example.json"),
        "etc/incinerator/headless/config.example.json",
    );
    const install_content_manifest = b.addInstallFile(
        b.path("config/headless-content.json"),
        "share/incinerator/headless/content.json",
    );
    b.getInstallStep().dependOn(&install_example_config.step);
    b.getInstallStep().dependOn(&install_content_manifest.step);

    const boundary_exe = b.addExecutable(.{
        .name = "headless_boundary_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_boundary_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const verify_boundary = b.addRunArtifact(boundary_exe);
    verify_boundary.setCwd(b.path("."));

    const linkage_exe = b.addExecutable(.{
        .name = "headless_linkage_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/headless_linkage_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const verify_emitted_linkage = b.addRunArtifact(linkage_exe);
    verify_emitted_linkage.addFileArg(headless_exe.getEmittedBin());

    const check_step = b.step(
        "check-headless-product",
        "Compile and boundary-check the cold headless product",
    );
    check_step.dependOn(&headless_exe.step);
    check_step.dependOn(&verify_boundary.step);
    check_step.dependOn(&verify_emitted_linkage.step);
    const check_conventional = b.step("check", "Compile and verify the selected product");
    check_conventional.dependOn(check_step);

    const staged_product = b.addWriteFiles();
    const staged_binary = staged_product.addCopyFile(
        headless_exe.getEmittedBin(),
        "bin/incinerator_headless",
    );
    _ = staged_product.addCopyFile(
        b.path("config/headless.example.json"),
        "etc/incinerator/headless/config.example.json",
    );
    _ = staged_product.addCopyFile(
        b.path("config/headless-content.json"),
        "share/incinerator/headless/content.json",
    );
    const verify_staged_product = b.addSystemCommand(&.{"sh"});
    verify_staged_product.addFileArg(b.path("tools/verify_headless_product.sh"));
    verify_staged_product.addDirectoryArg(staged_product.getDirectory());
    const verify_staged_linkage = b.addRunArtifact(linkage_exe);
    verify_staged_linkage.addFileArg(staged_binary);
    const verify_product_step = b.step(
        "verify-headless-product",
        "Verify the isolated install allowlist, Mach-O linkage, and forbidden markers",
    );
    verify_product_step.dependOn(&verify_boundary.step);
    verify_product_step.dependOn(&verify_staged_product.step);
    verify_product_step.dependOn(&verify_staged_linkage.step);

    const verify_lifecycle = b.addSystemCommand(&.{"sh"});
    verify_lifecycle.addFileArg(b.path("tools/verify_m3_headless_lifecycle.sh"));
    verify_lifecycle.addDirectoryArg(staged_product.getDirectory());
    verify_lifecycle.step.dependOn(&verify_staged_product.step);
    const verify_lifecycle_step = b.step(
        "test-m3-lifecycle",
        "Verify bounded startup, restart, signals, hard lag, and save preservation",
    );
    verify_lifecycle_step.dependOn(&verify_lifecycle.step);

    const headless_tests = b.addTest(.{ .root_module = headless_root_module });
    const run_headless_tests = b.addRunArtifact(headless_tests);
    const external_producers_tests = b.addTest(.{ .root_module = external_producers_module });
    const run_external_producers_tests = b.addRunArtifact(external_producers_tests);
    const test_external_producers_step = b.step(
        "test-external-producers",
        "Run bounded external producer router tests",
    );
    test_external_producers_step.dependOn(&run_external_producers_tests.step);
    const headless_authority_tests = b.addTest(.{ .root_module = headless_authority_module });
    const run_headless_authority_tests = b.addRunArtifact(headless_authority_tests);
    const test_headless_authority_step = b.step(
        "test-headless-authority",
        "Run one-world headless authority tests",
    );
    test_headless_authority_step.dependOn(&run_headless_authority_tests.step);
    const m3_soak_tests = b.addTest(.{ .root_module = m3_soak_module });
    const run_m3_soak_tests = b.addRunArtifact(m3_soak_tests);
    const test_m3_soak_step = b.step(
        "test-m3-soak",
        "Run M3 soak contract tests",
    );
    test_m3_soak_step.dependOn(&run_m3_soak_tests.step);
    const boundary_tests = b.addTest(.{ .root_module = boundary_exe.root_module });
    const run_boundary_tests = b.addRunArtifact(boundary_tests);
    const linkage_tests = b.addTest(.{ .root_module = linkage_exe.root_module });
    const run_linkage_tests = b.addRunArtifact(linkage_tests);
    const test_step = b.step("test", "Run cold headless product tests");
    test_step.dependOn(&cohort_verification.run.step);
    test_step.dependOn(&cohort_verification.tests.step);
    test_step.dependOn(&run_headless_tests.step);
    test_step.dependOn(&run_external_producers_tests.step);
    test_step.dependOn(&run_headless_authority_tests.step);
    test_step.dependOn(&run_m3_soak_tests.step);
    test_step.dependOn(&run_boundary_tests.step);
    test_step.dependOn(&run_linkage_tests.step);
    test_step.dependOn(verify_product_step);
    test_step.dependOn(verify_lifecycle_step);
    const install_step = b.step(
        "install-headless-product",
        "Install only the headless executable and two authority manifests",
    );
    install_step.dependOn(b.getInstallStep());
    const verify_installed = b.addSystemCommand(&.{"sh"});
    verify_installed.addFileArg(b.path("tools/verify_headless_product.sh"));
    verify_installed.addArg(b.getInstallPath(.prefix, ""));
    verify_installed.step.dependOn(b.getInstallStep());
    const verify_installed_step = b.step(
        "verify-installed-headless-product",
        "Verify the selected install prefix contains only the headless product",
    );
    verify_installed_step.dependOn(&verify_installed.step);

    const cold_verify = b.addSystemCommand(&.{"sh"});
    cold_verify.addFileArg(b.path("tools/verify_headless_cold_product.sh"));
    cold_verify.addDirectoryArg(b.path("."));
    cold_verify.addArg(b.graph.zig_exe);
    cold_verify.setCwd(.{ .cwd_relative = "/tmp" });
    const cold_verify_step = b.step(
        "verify-cold-headless-product",
        "Build Debug and ReleaseFast from a shaderless extracted tree and isolated caches",
    );
    cold_verify_step.dependOn(&cold_verify.step);

    const run_headless = b.addRunArtifact(headless_exe);
    if (b.args) |args| run_headless.addArgs(args);
    const run_step = b.step("run", "Run the selected headless product");
    run_step.dependOn(&run_headless.step);
}
