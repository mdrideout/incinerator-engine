//! Prove that visual/fault scenarios are compiled only into the validation host.

const std = @import("std");

const validation_markers = [_][]const u8{
    "--visual-smoke",
    "--s1-visual-smoke",
    "--s2-visual-smoke",
    "--s3-streaming-smoke",
    "--s4-diagnostics-smoke",
    "--s4-physics-debug-smoke",
    "--s5-authoring-smoke",
    "--s6-streaming-smoke",
    "--s7-interaction-smoke",
    "--s8-population-smoke",
    "--window-lifecycle-smoke",
    "--init-failure-smoke",
};

// These implementation details must never be reachable from the operational
// client. Some scenarios are deliberately compiled out of particular
// validation configurations (for example, authoring when the editor is off),
// so their positive presence is proven by the scenario-specific readiness
// gates instead of this configuration-independent boundary check.
const prohibited_product_scenario_markers = [_][]const u8{
    "s0_smoke",
    "s1_smoke",
    "s2_smoke",
    "s3_smoke",
    "VisualSmokeFrameLimit",
    "S1VisualSmokeBlockCollisionFailed",
    "S2VisualSmokeLifecycleInvariant",
    "S3StreamingSmokeEvidenceMissing",
    "S4PhysicsDebugLifecycleInvariant",
    "S5_AUTHORING_SMOKE_RESULT",
    "S6StreamingSmokeEvidenceMissing",
    "S7InteractionSmokeEvidenceMissing",
    "S8PopulationSmokeEvidenceMissing",
};

const prohibited_product_fault_markers = [_][]const u8{
    "InjectedDeveloperDiagnosticFault",
    "diagnostics.injected_fault_probe",
    "initWithDiagnosticFaultProbe",
    "InjectedRendererInitFailure",
    "InjectedAppInitFailure",
    "InjectedInitFailure",
    "InjectedVehicleCreateFailure",
    "injected_partial_write",
    "injected_before_replace",
    "injected_after_replace",
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next() orelse return error.MissingExecutableName;
    const product_path = args.next() orelse return error.MissingProductBinary;
    const validation_path = args.next() orelse return error.MissingValidationBinary;
    if (args.next() != null) return error.UnexpectedArgument;

    const product = try readBinary(init, product_path);
    defer init.gpa.free(product);
    const validation = try readBinary(init, validation_path);
    defer init.gpa.free(validation);

    for (validation_markers) |marker| {
        if (contains(product, marker)) {
            std.debug.print("validation marker leaked into product {s}: {s}\n", .{
                product_path,
                marker,
            });
            return error.ValidationMarkerInProduct;
        }
        if (!contains(validation, marker)) {
            std.debug.print("validation host {s} is missing scenario marker: {s}\n", .{
                validation_path,
                marker,
            });
            return error.ValidationMarkerMissing;
        }
    }
    for (prohibited_product_scenario_markers) |marker| {
        if (contains(product, marker)) {
            std.debug.print("validation implementation leaked into product {s}: {s}\n", .{
                product_path,
                marker,
            });
            return error.ValidationImplementationInProduct;
        }
    }
    for (prohibited_product_fault_markers) |marker| {
        if (contains(product, marker)) {
            std.debug.print("validation fault marker leaked into product {s}: {s}\n", .{
                product_path,
                marker,
            });
            return error.ValidationFaultMarkerInProduct;
        }
    }

    std.debug.print("product/validation binary boundary verified\n", .{});
}

fn readBinary(init: std.process.Init, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.gpa,
        .limited(512 * 1024 * 1024),
    );
}

fn contains(binary: []const u8, marker: []const u8) bool {
    return std.mem.indexOf(u8, binary, marker) != null;
}

test "scenario markers are exact and product-safe data has no matches" {
    const marker = "--s1-visual-smoke";
    try std.testing.expect(!contains("incinerator product", marker));
    try std.testing.expect(contains("prefix --s1-visual-smoke suffix", marker));
    try std.testing.expect(!contains("--s1-visual", marker));
}
