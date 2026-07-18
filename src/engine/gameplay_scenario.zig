//! Typed, fixed-tick gameplay scenario kernel.
//!
//! The kernel knows sequencing and deadlines. Product/session adapters own
//! fixture construction, action translation, immutable observations, and
//! failure artifacts. There are no sleeps, strings-as-actions, or hidden
//! mutable gameplay access in this layer.

const std = @import("std");

pub const ActionPhase = enum { press, release };
pub const Status = enum { running, completed };
pub const FailureKind = enum {
    scenario_deadline,
    step_deadline,
    continuous_invariant,
};

pub fn Model(
    comptime Action: type,
    comptime Predicate: type,
    comptime Invariant: type,
    comptime Checkpoint: type,
) type {
    return struct {
        pub const Await = struct {
            predicate: Predicate,
            within_ticks: u64,
        };

        pub const Hold = struct {
            action: Action,
            until: Predicate,
            within_ticks: u64,
        };

        pub const Step = union(enum) {
            await: Await,
            press: Action,
            hold: Hold,
            release: Action,
            checkpoint: Checkpoint,
        };

        pub const Scenario = struct {
            id: u64,
            name: []const u8,
            seed: u64,
            steps: []const Step,
            invariants: []const Invariant,
            deadline_ticks: u64,
        };

        pub const Failure = struct {
            kind: FailureKind,
            tick: u64,
            step_index: usize,
            invariant_index: ?usize = null,
        };

        pub const Runner = struct {
            const Self = @This();

            scenario: Scenario,
            tick_count: u64 = 0,
            step_index: usize = 0,
            step_started_tick: u64 = 0,
            hold_pressed: bool = false,
            failure: ?Failure = null,

            pub fn init(scenario: Scenario) !Self {
                if (scenario.name.len == 0) return error.EmptyScenarioName;
                if (scenario.deadline_ticks == 0) return error.InvalidScenarioDeadline;
                for (scenario.steps) |step| switch (step) {
                    .await => |value| if (value.within_ticks == 0) {
                        return error.InvalidStepDeadline;
                    },
                    .hold => |value| if (value.within_ticks == 0) {
                        return error.InvalidStepDeadline;
                    },
                    else => {},
                };
                return .{ .scenario = scenario };
            }

            /// Adapter contract:
            /// - `advance(tick) !void` advances exactly one fixed simulation tick;
            /// - `observePredicate(Predicate) bool` samples immutable state;
            /// - `observeInvariant(Invariant) bool` samples immutable state;
            /// - `apply(Action, ActionPhase) !void` translates semantic input;
            /// - `checkpoint(Checkpoint) !void` records requested evidence;
            /// - `scenarioFailed(Failure) void` freezes/retains first-cause evidence.
            pub fn tick(self: *Self, adapter: anytype) !Status {
                if (self.failure != null) return error.ScenarioAlreadyFailed;
                if (self.step_index == self.scenario.steps.len) return .completed;

                if (self.tick_count == self.scenario.deadline_ticks) {
                    return self.fail(adapter, .scenario_deadline, null);
                }

                self.tick_count += 1;
                try adapter.advance(self.tick_count);

                for (self.scenario.invariants, 0..) |invariant, index| {
                    if (!adapter.observeInvariant(invariant)) {
                        return self.fail(adapter, .continuous_invariant, index);
                    }
                }

                const step = self.scenario.steps[self.step_index];
                switch (step) {
                    .await => |value| {
                        if (adapter.observePredicate(value.predicate)) {
                            self.completeStep();
                        } else if (self.stepAge() >= value.within_ticks) {
                            return self.fail(adapter, .step_deadline, null);
                        }
                    },
                    .press => |action| {
                        try adapter.apply(action, .press);
                        self.completeStep();
                    },
                    .hold => |value| {
                        if (!self.hold_pressed) {
                            try adapter.apply(value.action, .press);
                            self.hold_pressed = true;
                        }
                        if (adapter.observePredicate(value.until)) {
                            self.completeStep();
                        } else if (self.stepAge() >= value.within_ticks) {
                            return self.fail(adapter, .step_deadline, null);
                        }
                    },
                    .release => |action| {
                        try adapter.apply(action, .release);
                        self.completeStep();
                    },
                    .checkpoint => |checkpoint| {
                        try adapter.checkpoint(checkpoint);
                        self.completeStep();
                    },
                }
                return if (self.step_index == self.scenario.steps.len)
                    .completed
                else
                    .running;
            }

            fn stepAge(self: *const Self) u64 {
                return self.tick_count - self.step_started_tick;
            }

            fn completeStep(self: *Self) void {
                self.step_index += 1;
                self.step_started_tick = self.tick_count;
                self.hold_pressed = false;
            }

            fn fail(
                self: *Self,
                adapter: anytype,
                kind: FailureKind,
                invariant_index: ?usize,
            ) error{ScenarioFailed} {
                const failure = Failure{
                    .kind = kind,
                    .tick = self.tick_count,
                    .step_index = self.step_index,
                    .invariant_index = invariant_index,
                };
                self.failure = failure;
                adapter.scenarioFailed(failure);
                return error.ScenarioFailed;
            }
        };
    };
}

const TestAction = enum { forward, melee };
const TestPredicate = enum { near_target, target_dead };
const TestInvariant = enum { finite_pose, visible };
const TestCheckpoint = enum { contact };
const TestModel = Model(TestAction, TestPredicate, TestInvariant, TestCheckpoint);

const TestAdapter = struct {
    tick: u64 = 0,
    forward: bool = false,
    melee_count: u8 = 0,
    checkpoints: u8 = 0,
    failed: ?TestModel.Failure = null,
    fail_visibility_at: ?u64 = null,
    action_log: [8]struct { TestAction, ActionPhase } = undefined,
    action_count: usize = 0,

    fn advance(self: *TestAdapter, tick: u64) !void {
        if (tick != self.tick + 1) return error.NonSequentialTick;
        self.tick = tick;
    }

    fn observePredicate(self: *const TestAdapter, value: TestPredicate) bool {
        return switch (value) {
            .near_target => self.forward and self.tick >= 4,
            .target_dead => self.melee_count != 0 and self.tick >= 8,
        };
    }

    fn observeInvariant(self: *const TestAdapter, value: TestInvariant) bool {
        return switch (value) {
            .finite_pose => true,
            .visible => self.fail_visibility_at == null or
                self.tick != self.fail_visibility_at.?,
        };
    }

    fn apply(self: *TestAdapter, action: TestAction, phase: ActionPhase) !void {
        self.action_log[self.action_count] = .{ action, phase };
        self.action_count += 1;
        switch (action) {
            .forward => self.forward = phase == .press,
            .melee => if (phase == .press) {
                self.melee_count += 1;
            },
        }
    }

    fn checkpoint(self: *TestAdapter, _: TestCheckpoint) !void {
        self.checkpoints += 1;
    }

    fn scenarioFailed(self: *TestAdapter, failure: TestModel.Failure) void {
        self.failed = failure;
    }
};

const test_steps = [_]TestModel.Step{
    .{ .hold = .{ .action = .forward, .until = .near_target, .within_ticks = 5 } },
    .{ .release = .forward },
    .{ .checkpoint = .contact },
    .{ .press = .melee },
    .{ .await = .{ .predicate = .target_dead, .within_ticks = 5 } },
};
const test_invariants = [_]TestInvariant{ .finite_pose, .visible };
const test_scenario = TestModel.Scenario{
    .id = 11,
    .name = "hostile encounter",
    .seed = 0x11,
    .steps = &test_steps,
    .invariants = &test_invariants,
    .deadline_ticks = 16,
};

fn runTestScenario(adapter: *TestAdapter) !TestModel.Runner {
    var runner = try TestModel.Runner.init(test_scenario);
    while (try runner.tick(adapter) != .completed) {}
    return runner;
}

test "scenario runner uses condition waits and preserves action order" {
    var adapter: TestAdapter = .{};
    const runner = try runTestScenario(&adapter);
    try std.testing.expectEqual(@as(u64, 8), runner.tick_count);
    try std.testing.expectEqual(@as(u8, 1), adapter.checkpoints);
    try std.testing.expectEqual(@as(usize, 3), adapter.action_count);
    try std.testing.expectEqual(TestAction.forward, adapter.action_log[0][0]);
    try std.testing.expectEqual(ActionPhase.press, adapter.action_log[0][1]);
    try std.testing.expectEqual(ActionPhase.release, adapter.action_log[1][1]);
    try std.testing.expectEqual(TestAction.melee, adapter.action_log[2][0]);
}

test "scenario runner fails and reports a continuous invariant immediately" {
    var adapter = TestAdapter{ .fail_visibility_at = 3 };
    var runner = try TestModel.Runner.init(test_scenario);
    try std.testing.expectEqual(Status.running, try runner.tick(&adapter));
    try std.testing.expectEqual(Status.running, try runner.tick(&adapter));
    try std.testing.expectError(error.ScenarioFailed, runner.tick(&adapter));
    try std.testing.expectEqual(FailureKind.continuous_invariant, runner.failure.?.kind);
    try std.testing.expectEqual(@as(u64, 3), runner.failure.?.tick);
    try std.testing.expectEqual(@as(usize, 1), runner.failure.?.invariant_index.?);
}

test "scenario runner produces deterministic artifacts for equal inputs" {
    var first: TestAdapter = .{};
    var second: TestAdapter = .{};
    const first_runner = try runTestScenario(&first);
    const second_runner = try runTestScenario(&second);
    try std.testing.expectEqualDeep(first_runner, second_runner);
    try std.testing.expectEqualSlices(
        @TypeOf(first.action_log[0]),
        first.action_log[0..first.action_count],
        second.action_log[0..second.action_count],
    );
}

test "scenario runner rejects a missed condition deadline" {
    const missed_steps = [_]TestModel.Step{
        .{ .await = .{ .predicate = .near_target, .within_ticks = 2 } },
    };
    var runner = try TestModel.Runner.init(.{
        .id = 1,
        .name = "deadline",
        .seed = 1,
        .steps = &missed_steps,
        .invariants = &.{.finite_pose},
        .deadline_ticks = 4,
    });
    var adapter: TestAdapter = .{};
    try std.testing.expectEqual(Status.running, try runner.tick(&adapter));
    try std.testing.expectError(error.ScenarioFailed, runner.tick(&adapter));
    try std.testing.expectEqual(FailureKind.step_deadline, runner.failure.?.kind);
    try std.testing.expectEqual(@as(u64, 2), runner.failure.?.tick);
}
