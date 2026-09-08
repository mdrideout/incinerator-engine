//! Disk and isolated measurement composition. The feature remains mutation authority.
const std = @import("std");
const engine = @import("engine_contracts");
const content = @import("content");
const authoring = @import("vehicle_authoring");
const contract = @import("vehicle_authoring_contract");
const vehicle = contract.vehicle;
const cohort = @import("network_cohort_options");

const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transaction_id: u64,
    executable: []u8,
    candidate_path: []u8,
    report_path: []u8,
    log_path: []u8,
    digest: engine.assets.Digest,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    failure: ?[]const u8 = null,
    delivered: bool = false,

    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        self.execute() catch |err| {
            self.failure = @errorName(err);
        };
    }
    fn execute(self: *Job) !void {
        const output = try std.process.run(self.allocator, self.io, .{ .argv = &.{ self.executable, "--definition", self.candidate_path } });
        defer self.allocator.free(output.stdout);
        defer self.allocator.free(output.stderr);
        try writeFile(self.io, self.report_path, output.stdout);
        try writeFile(self.io, self.log_path, output.stderr);
        const Header = struct { definition_digest: [32]u8, build: struct { source_cohort: u64 } };
        var header = try std.json.parseFromSlice(Header, self.allocator, output.stdout, .{ .ignore_unknown_fields = true });
        defer header.deinit();
        if (!std.mem.eql(u8, &self.digest, &header.value.definition_digest)) return error.MeasurementDefinitionMismatch;
        if (header.value.build.source_cohort != cohort.build_cohort) return error.MeasurementBuildMismatch;
        if (output.term != .exited or output.term.exited != 0) return error.VehicleMeasurementIncomplete;
    }
    fn deinit(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.allocator.free(self.executable);
        self.allocator.free(self.candidate_path);
        self.allocator.free(self.report_path);
        self.allocator.free(self.log_path);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    root: content.ContentRootPath,
    run_id: engine.authoring.RunId,
    owner: authoring.Owner,
    requests: contract.Requests,
    jobs: std.ArrayList(*Job) = .empty,
    evidence_written: usize = 0,
    persistence_available: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: content.ContentRootPath, project_root: ?content.ContentRootPath, run_id: engine.authoring.RunId, catalog: []const engine.assets.Entry) !Host {
        var base = try std.Io.Dir.openDirAbsolute(io, root.bytes(), .{});
        defer base.close(io);
        var directory = if (project_root) |project| try std.Io.Dir.openDirAbsolute(io, project.bytes(), .{ .iterate = true }) else try base.openDir(io, "vehicle", .{ .iterate = true });
        errdefer directory.close(io);
        var decoded: std.ArrayList(vehicle.asset.Owned) = .empty;
        defer {
            for (decoded.items) |*value| value.deinit();
            decoded.deinit(allocator);
        }
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".icvehicle")) continue;
            const bytes = try directory.readFileAlloc(io, entry.name, allocator, .unlimited);
            defer allocator.free(bytes);
            var asset = try vehicle.asset.decode(allocator, bytes);
            errdefer asset.deinit();
            if (!std.mem.eql(u8, entry.name, &vehicle.asset.filename(asset.value.id))) return error.VehicleAssetIdentityMismatch;
            try asset.value.validateCatalog(catalog);
            try decoded.append(allocator, asset);
        }
        if (decoded.items.len == 0) return error.VehicleArchetypeMissing;
        const definitions = try allocator.alloc(contract.Definition, decoded.items.len);
        defer allocator.free(definitions);
        for (decoded.items, definitions) |value, *definition| definition.* = value.value;
        return .{ .persistence_available = project_root != null, .allocator = allocator, .io = io, .root = root, .run_id = run_id, .directory = directory, .owner = try authoring.Owner.init(allocator, definitions), .requests = .{ .allocator = allocator } };
    }
    pub fn deinit(self: *Host) void {
        for (self.jobs.items) |job| job.deinit();
        self.jobs.deinit(self.allocator);
        self.requests.deinit();
        self.owner.deinit();
        self.directory.close(self.io);
    }
    pub fn prepare(self: *Host, source: engine.authoring.Source, request: contract.Request, live: vehicle.VehicleView, catalog: []const engine.assets.Entry) !*authoring.Transaction {
        const tx = try self.owner.prepare(source, request, live, catalog, if (self.persistence_available) .{ .context = self, .write_fn = commit } else null);
        if (tx.result.disposition == .pending and tx.result.action == .measure) {
            self.startMeasurement(tx) catch |err| {
                self.owner.admissionFailed(tx.result.transaction_id, err);
            };
        }
        return tx;
    }
    pub fn input(self: *Host, live: ?vehicle.VehicleView, catalog: []const engine.assets.Entry) !contract.Input {
        return .{ .persistence_available = self.persistence_available, .catalog = catalog, .allocator = self.allocator, .inspection = if (live) |value| try self.owner.inspect(value) else null, .result = if (self.owner.last_ui_result) |id| self.owner.result(id, .ui) else null, .requests = &self.requests };
    }
    pub fn pump(self: *Host) void {
        for (self.jobs.items) |job| {
            if (!job.done.load(.acquire) or job.delivered) continue;
            job.delivered = true;
            const tx = self.owner.transaction(job.transaction_id) orelse continue;
            tx.result.disposition = if (job.failure == null) .accepted else .rejected;
            tx.result.rejection = job.failure;
            tx.result.artifact_path = job.report_path;
        }
    }
    pub fn writeEvidence(self: *Host, tick: u64, frame: u64) !void {
        // Terminal transactions retain the full before/candidate values, including curves.
        // Each file is independently correlated; no fixed incident-line buffer truncates it.
        while (self.evidence_written < self.owner.transactions.items.len) {
            const tx = &self.owner.transactions.items[self.evidence_written];
            if (tx.result.disposition == .pending) break;
            const path = try self.artifactPath(tx.result.transaction_id, "transaction.json");
            defer self.allocator.free(path);
            const bytes = try std.json.Stringify.valueAlloc(self.allocator, .{ .schema = 1, .run_id = self.run_id, .presentation_frame = frame, .observed_tick = tick, .result = tx.result, .before = tx.before.value, .candidate = if (tx.candidate) |candidate| candidate.value else null }, .{ .whitespace = .indent_2 });
            defer self.allocator.free(bytes);
            try writeFile(self.io, path, bytes);
            self.evidence_written += 1;
        }
    }
    fn artifactPath(self: *Host, id: u64, filename: []const u8) ![]u8 {
        const directory_path = try std.fmt.allocPrint(self.allocator, "{s}/vehicle-authoring/{d}-{d}/{d}", .{ self.root.bytes(), self.run_id.started_wall_unix_ms, self.run_id.nonce, id });
        defer self.allocator.free(directory_path);
        try std.Io.Dir.cwd().createDirPath(self.io, directory_path);
        return std.fs.path.join(self.allocator, &.{ directory_path, filename });
    }
    fn startMeasurement(self: *Host, tx: *authoring.Transaction) !void {
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        const executable_dir = try std.process.executableDirPathAlloc(self.io, self.allocator);
        defer self.allocator.free(executable_dir);
        const executable = try std.fs.path.join(self.allocator, &.{ executable_dir, "incinerator_vehicle_dynamics" });
        errdefer self.allocator.free(executable);
        const candidate_path = try self.artifactPath(tx.result.transaction_id, "candidate.icvehicle");
        errdefer self.allocator.free(candidate_path);
        const report_path = try self.artifactPath(tx.result.transaction_id, "measurement.json");
        errdefer self.allocator.free(report_path);
        const log_path = try self.artifactPath(tx.result.transaction_id, "measurement.log");
        errdefer self.allocator.free(log_path);
        const candidate = tx.candidate.?.value;
        const bytes = try vehicle.asset.encode(self.allocator, candidate);
        defer self.allocator.free(bytes);
        try writeFile(self.io, candidate_path, bytes);
        job.* = .{ .allocator = self.allocator, .io = self.io, .transaction_id = tx.result.transaction_id, .executable = executable, .candidate_path = candidate_path, .report_path = report_path, .log_path = log_path, .digest = try candidate.digest(self.allocator) };
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.jobs.appendAssumeCapacity(job);
        tx.result.artifact_path = report_path;
    }
    fn commit(context: *anyopaque, definition: contract.Definition) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        try vehicle.asset.write(self.allocator, self.io, self.directory, definition);
    }
};
fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
