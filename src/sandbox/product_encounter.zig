//! Product-composition ownership for the small playable sandbox encounter.
//!
//! The authority owns NPC identity, vitals, encounter behavior, death, and
//! replacement. This owner does one narrower job: once the local product has a
//! player and the canonical west district is active, it submits the initial
//! NPC through the ordinary host-managed authority boundary and correlates the
//! result. Validation scenarios deliberately use a separate composition.

const std = @import("std");
const npc = @import("npc_contract");
const district_recipe = @import("sandbox_district_recipe");

pub const initial_request_id: u64 = 0x5342_4e50_0000_0001;

pub const Prerequisites = struct {
    player_ready: bool,
    west_district_active: bool,
};

pub const State = enum {
    waiting_for_prerequisites,
    awaiting_spawn,
    bootstrap_complete,
};

pub const Observation = enum {
    unrelated,
    activated,
};

pub const Owner = struct {
    state: State = .waiting_for_prerequisites,
    /// Provenance for the initial spawn only. The authority may later replace
    /// this NPC with a new identity while bootstrap remains complete.
    bootstrap_npc: ?@FieldType(npc.Spawned, "id") = null,

    /// Return the exact initial command without mutating ownership. The caller
    /// marks it submitted only after the authority boundary accepts it.
    pub fn pendingSpawn(
        self: *const Owner,
        prerequisites: Prerequisites,
    ) ?npc.Command {
        if (self.state != .waiting_for_prerequisites or
            !prerequisites.player_ready or
            !prerequisites.west_district_active)
        {
            return null;
        }
        return initialSpawnCommand();
    }

    pub fn markSubmitted(self: *Owner, command: npc.Command) !void {
        if (self.state != .waiting_for_prerequisites or
            !std.meta.eql(command, initialSpawnCommand()))
        {
            return error.InvalidProductEncounterSubmission;
        }
        self.state = .awaiting_spawn;
    }

    /// Consume only this composition's correlation. Authority-owned death and
    /// replacement outcomes intentionally remain unrelated to the initializer.
    pub fn observe(self: *Owner, outcome: npc.Outcome) !Observation {
        if (outcomeRequestId(outcome) != initial_request_id) return .unrelated;
        if (self.state != .awaiting_spawn) {
            return error.UnexpectedProductEncounterOutcome;
        }
        switch (outcome) {
            .spawned => |spawned| {
                if (!std.meta.eql(
                    spawned.owner,
                    district_recipe.navigation_west_coord,
                )) return error.UnexpectedProductEncounterOutcome;
                self.bootstrap_npc = spawned.id;
                self.state = .bootstrap_complete;
                return .activated;
            },
            .rejected => |rejected| {
                if (rejected.command != .spawn) {
                    return error.UnexpectedProductEncounterOutcome;
                }
                return error.ProductEncounterSpawnRejected;
            },
            .goal_set, .despawned => return error.UnexpectedProductEncounterOutcome,
        }
    }
};

fn initialSpawnCommand() npc.Command {
    const first = npc.NodeRef{
        .coord = district_recipe.navigation_west_coord,
        .index = 2,
    };
    return .{ .spawn = .{
        .request_id = initial_request_id,
        .node = first,
        .goal = .{ .patrol_between = .{
            .first = district_recipe.depot_forecourt,
            .second = district_recipe.player_plaza,
        } },
    } };
}

fn outcomeRequestId(outcome: npc.Outcome) u64 {
    return switch (outcome) {
        .spawned => |value| value.request_id,
        .goal_set => |value| value.request_id,
        .despawned => |value| value.request_id,
        .rejected => |value| value.request_id,
    };
}

test "product encounter waits for both authority prerequisites" {
    const owner = Owner{};
    try std.testing.expect(owner.pendingSpawn(.{
        .player_ready = false,
        .west_district_active = false,
    }) == null);
    try std.testing.expect(owner.pendingSpawn(.{
        .player_ready = true,
        .west_district_active = false,
    }) == null);
    try std.testing.expect(owner.pendingSpawn(.{
        .player_ready = false,
        .west_district_active = true,
    }) == null);

    const command = owner.pendingSpawn(.{
        .player_ready = true,
        .west_district_active = true,
    }) orelse return error.MissingProductEncounterSpawn;
    try std.testing.expect(std.meta.eql(command, initialSpawnCommand()));
}

test "product encounter submission and activation are exactly correlated" {
    var owner = Owner{};
    const command = owner.pendingSpawn(.{
        .player_ready = true,
        .west_district_active = true,
    }) orelse return error.MissingProductEncounterSpawn;
    try owner.markSubmitted(command);
    try std.testing.expectEqual(State.awaiting_spawn, owner.state);
    try std.testing.expect(owner.pendingSpawn(.{
        .player_ready = true,
        .west_district_active = true,
    }) == null);

    const unrelated_id = @FieldType(npc.Spawned, "id"){
        .namespace = 9,
        .local = 2,
    };
    try std.testing.expectEqual(Observation.unrelated, try owner.observe(.{ .spawned = .{
        .request_id = initial_request_id + 1,
        .id = unrelated_id,
        .owner = district_recipe.navigation_west_coord,
    } }));
    try std.testing.expectEqual(State.awaiting_spawn, owner.state);

    const initial_id = @FieldType(npc.Spawned, "id"){
        .namespace = 9,
        .local = 3,
    };
    try std.testing.expectEqual(Observation.activated, try owner.observe(.{ .spawned = .{
        .request_id = initial_request_id,
        .id = initial_id,
        .owner = district_recipe.navigation_west_coord,
    } }));
    try std.testing.expectEqual(State.bootstrap_complete, owner.state);
    try std.testing.expect(std.meta.eql(initial_id, owner.bootstrap_npc.?));
}

test "product encounter rejects exact failure and invalid transitions" {
    var waiting = Owner{};
    try std.testing.expectError(
        error.UnexpectedProductEncounterOutcome,
        waiting.observe(.{ .spawned = .{
            .request_id = initial_request_id,
            .id = .{ .namespace = 1, .local = 1 },
            .owner = district_recipe.navigation_west_coord,
        } }),
    );

    var submitted = Owner{};
    const command = submitted.pendingSpawn(.{
        .player_ready = true,
        .west_district_active = true,
    }).?;
    try submitted.markSubmitted(command);
    try std.testing.expectError(
        error.ProductEncounterSpawnRejected,
        submitted.observe(.{ .rejected = .{
            .command = .spawn,
            .reason = .start_district_inactive,
            .request_id = initial_request_id,
        } }),
    );
    try std.testing.expectError(
        error.InvalidProductEncounterSubmission,
        submitted.markSubmitted(command),
    );
}
