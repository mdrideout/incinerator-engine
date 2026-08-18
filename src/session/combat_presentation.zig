//! Renderer-neutral combat presentation policy.
//!
//! Authority snapshots and reliable gameplay results remain the only inputs.
//! This owner turns those protocol values into deterministic, tick-keyed draw
//! intent; it does not infer hit direction, advance gameplay, or use wall time.

const std = @import("std");
const budgets = @import("session_budgets");
const identity = @import("session_identity");
const protocol = @import("session_protocol");

pub const hit_flash_ticks: u64 = 8;
pub const shot_tracer_ticks: u64 = 6;
pub const feedback_capacity: usize = budgets.max_reliable_events_per_tick;

pub const Color = [4]f32;

pub const colors = struct {
    pub const local_character: Color = .{ 0.15, 0.95, 0.25, 1 };
    pub const remote_character: Color = .{ 0.95, 0.25, 0.15, 1 };
    pub const hit_flash: Color = .{ 1, 1, 1, 1 };
    // Death must read immediately in the primitive sandbox. A near-black body
    // looked like a despawn against the ground and made lifecycle failures
    // impossible to distinguish by eye.
    pub const dead: Color = .{ 0.92, 0.04, 0.06, 1 };
    pub const health: Color = .{ 0.15, 0.90, 0.20, 1 };
    pub const health_empty: Color = .{ 0.35, 0.05, 0.05, 1 };
    pub const npc_patrolling: Color = .{ 0.65, 0.25, 0.95, 1 };
    pub const npc_resident: Color = .{ 0.22, 0.72, 0.34, 1 };
    pub const npc_worker: Color = .{ 0.18, 0.48, 0.92, 1 };
    pub const npc_visitor: Color = .{ 0.76, 0.34, 0.88, 1 };
    pub const npc_hostile: Color = .{ 0.95, 0.20, 0.18, 1 };
    pub const npc_waiting: Color = .{ 0.45, 0.45, 0.55, 1 };
    pub const npc_pursuing: Color = .{ 0.95, 0.20, 0.18, 1 };
    pub const npc_windup: Color = .{ 1, 0.50, 0.05, 1 };
    pub const npc_recovery: Color = .{ 0.95, 0.80, 0.15, 1 };
    pub const npc_searching: Color = .{ 0.25, 0.55, 1, 1 };
    pub const npc_returning: Color = .{ 0.35, 0.75, 0.65, 1 };
    pub const melee_cooldown: Color = .{ 1, 0.80, 0.05, 1 };
    pub const respawn_countdown: Color = .{ 0.95, 0.20, 0.15, 1 };
    pub const respawn_ready: Color = .{ 0.20, 0.85, 1, 1 };
    pub const no_safe_spawn: Color = .{ 1, 0.05, 0.85, 1 };
};

pub const HealthBarPlan = struct {
    visible: bool,
    fraction: f32,
    fill_color: Color,
    empty_color: Color,
};

pub const BarGeometry = struct {
    fill_width: f32,
    fill_center_offset: f32,
};

/// Left-anchors the fill inside a centered background bar.
pub fn healthBarGeometry(plan: HealthBarPlan, width: f32) BarGeometry {
    const clamped_width = @max(width, 0);
    const fill_width = clamped_width * std.math.clamp(plan.fraction, 0, 1);
    return .{
        .fill_width = fill_width,
        .fill_center_offset = (fill_width - clamped_width) * 0.5,
    };
}

pub const EntityPlan = struct {
    entity: identity.ReplicatedEntityId,
    incarnation: u16,
    health: u16,
    maximum_health: u16,
    life_state: protocol.AvatarLifeState,
    hit_flash: bool,
    dead: bool,
    body_color: Color,
    health_bar: HealthBarPlan,
};

pub const NpcPlan = struct {
    entity: EntityPlan,
    encounter_state: protocol.NpcEncounterState,
    windup: bool,
    attack_impact_remaining_ticks: u64,
    attack_ready_remaining_ticks: u64,
};

pub const RespawnMarker = enum {
    none,
    countdown,
    ready,
    no_safe_spawn,
};

pub fn respawnMarkerColor(marker: RespawnMarker) ?Color {
    return switch (marker) {
        .none => null,
        .countdown => colors.respawn_countdown,
        .ready => colors.respawn_ready,
        .no_safe_spawn => colors.no_safe_spawn,
    };
}

pub const LocalHud = struct {
    authority_tick: u64,
    available: bool,
    avatar: identity.ReplicatedEntityId,
    incarnation: u16,
    health: u16,
    maximum_health: u16,
    life_state: protocol.AvatarLifeState,
    melee_remaining_ticks: u64,
    respawn_remaining_ticks: u64,
    latest_melee_disposition: ?protocol.MeleeActionDisposition,
    weapon_mode: protocol.WeaponMode,
    magazine_ammo: u16,
    reserve_ammo: u16,
    weapon_remaining_ticks: u64,
    reload_remaining_ticks: u64,
    latest_weapon_disposition: ?protocol.WeaponActionDisposition,
    latest_respawn_disposition: ?protocol.RespawnActionDisposition,
    melee_cooldown_marker: bool,
    respawn_marker: RespawnMarker,
    anchor_position: ?[3]f32,
    anchor_tick: u64,

    pub fn noSafeSpawn(self: LocalHud) bool {
        return self.respawn_marker == .no_safe_spawn;
    }
};

pub const HudInput = struct {
    authority_tick: u64,
    avatar: identity.ReplicatedEntityId,
    incarnation: u16,
    life_state: ?protocol.AvatarLifeState,
    melee_ready_tick: u64,
    weapon_mode: protocol.WeaponMode = .holstered,
    magazine_ammo: u16 = 0,
    reserve_ammo: u16 = 0,
    weapon_ready_tick: u64 = 0,
    reload_complete_tick: u64 = 0,
    respawn_ready_tick: u64,
    character: ?protocol.CharacterState = null,
    owned_vehicle: ?protocol.VehicleState = null,
};

pub const Feedback = union(enum) {
    melee: protocol.MeleeActionResult,
    weapon: protocol.WeaponActionResult,
    shot: protocol.ShotEvent,
    respawn: protocol.RespawnActionResult,
    life: protocol.LifeEvent,
};

/// Small bounded bridge for a host that owns protocol delivery separately from
/// its graphical scene. Overflow is explicit rather than silently dropping
/// player feedback.
pub const FeedbackQueue = struct {
    items: [feedback_capacity]Feedback = undefined,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *FeedbackQueue, feedback: Feedback) !void {
        if (self.count == self.items.len) return error.CombatFeedbackQueueFull;
        const index = (self.head + self.count) % self.items.len;
        self.items[index] = feedback;
        self.count += 1;
    }

    pub fn pop(self: *FeedbackQueue) ?Feedback {
        if (self.count == 0) return null;
        const feedback = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        return feedback;
    }
};

const Observation = struct {
    occupied: bool = false,
    entity: identity.ReplicatedEntityId = .invalid,
    incarnation: u16 = 0,
    health: u16 = 0,
    observed_tick: u64 = 0,
    flash_until_tick: u64 = 0,
};

pub const TracerPlan = struct {
    shooter: identity.ReplicatedEntityId,
    sequence: identity.ActionSequence,
    origin: [3]f32,
    impact: [3]f32,
    hit: bool,
};

const TracerObservation = struct {
    occupied: bool = false,
    event: protocol.ShotEvent = undefined,
    visible_until_tick: u64 = 0,
};

pub const Owner = struct {
    characters: [budgets.max_participants]Observation = @splat(.{}),
    npcs: [budgets.max_npcs]Observation = @splat(.{}),
    latest_melee: ?protocol.MeleeActionResult = null,
    latest_weapon: ?protocol.WeaponActionResult = null,
    latest_respawn: ?protocol.RespawnActionResult = null,
    latest_life: ?protocol.LifeEvent = null,
    tracers: [budgets.max_participants]TracerObservation = @splat(.{}),
    tracer_plans: [budgets.max_participants]TracerPlan = undefined,
    hud_anchor_position: ?[3]f32 = null,
    hud_anchor_tick: u64 = 0,

    pub fn noteFeedback(
        self: *Owner,
        local_avatar: identity.ReplicatedEntityId,
        feedback: Feedback,
    ) void {
        switch (feedback) {
            .melee => |result| self.latest_melee = result,
            .weapon => |result| self.latest_weapon = result,
            .shot => |event| self.noteShot(event),
            .respawn => |result| {
                self.latest_respawn = result;
                if (result.disposition == .respawned) {
                    self.latest_melee = null;
                    self.latest_weapon = null;
                    self.latest_life = null;
                }
            },
            .life => |event| if (std.meta.eql(event.avatar, local_avatar)) {
                self.latest_life = event;
            },
        }
    }

    fn noteShot(self: *Owner, event: protocol.ShotEvent) void {
        var free: ?usize = null;
        for (&self.tracers, 0..) |*entry, index| {
            if (!entry.occupied) {
                if (free == null) free = index;
                continue;
            }
            if (std.meta.eql(entry.event.shooter, event.shooter)) {
                entry.* = .{
                    .occupied = true,
                    .event = event,
                    .visible_until_tick = event.authority_tick +| shot_tracer_ticks,
                };
                return;
            }
        }
        const index = free orelse return;
        self.tracers[index] = .{
            .occupied = true,
            .event = event,
            .visible_until_tick = event.authority_tick +| shot_tracer_ticks,
        };
    }

    pub fn tracerPlans(self: *Owner, authority_tick: u64) []const TracerPlan {
        var count: usize = 0;
        for (&self.tracers) |*entry| {
            if (!entry.occupied) continue;
            if (authority_tick > entry.visible_until_tick) {
                entry.occupied = false;
                continue;
            }
            self.tracer_plans[count] = .{
                .shooter = entry.event.shooter,
                .sequence = entry.event.sequence,
                .origin = entry.event.ray_origin,
                .impact = entry.event.impact_position,
                .hit = entry.event.disposition == .hit,
            };
            count += 1;
        }
        return self.tracer_plans[0..count];
    }

    pub fn characterPlan(
        self: *Owner,
        authority_tick: u64,
        state: protocol.CharacterState,
        local_player: bool,
    ) EntityPlan {
        const flash = observe(
            self.characters[0..],
            authority_tick,
            state.entity,
            state.incarnation,
            state.health,
        );
        return entityPlan(
            state.entity,
            state.incarnation,
            state.health,
            state.maximum_health,
            state.life_state,
            flash,
            if (local_player) colors.local_character else colors.remote_character,
        );
    }

    pub fn npcPlan(
        self: *Owner,
        authority_tick: u64,
        state: protocol.NpcState,
    ) NpcPlan {
        const flash = observe(
            self.npcs[0..],
            authority_tick,
            state.entity,
            state.incarnation,
            state.health,
        );
        const base_color: Color = switch (state.encounter_state) {
            .patrolling => if (state.state == .active)
                if (state.combat_disposition == .hostile_to_players)
                    colors.npc_hostile
                else switch (state.population_role) {
                    .unassigned => colors.npc_patrolling,
                    .resident => colors.npc_resident,
                    .worker => colors.npc_worker,
                    .visitor => colors.npc_visitor,
                }
            else
                colors.npc_waiting,
            .pursuing => colors.npc_pursuing,
            .attack_windup => colors.npc_windup,
            .attack_recovery => colors.npc_recovery,
            .searching => colors.npc_searching,
            .returning => colors.npc_returning,
        };
        return .{
            .entity = entityPlan(
                state.entity,
                state.incarnation,
                state.health,
                state.maximum_health,
                state.life_state,
                flash,
                base_color,
            ),
            .encounter_state = state.encounter_state,
            .windup = state.life_state == .alive and
                state.encounter_state == .attack_windup,
            .attack_impact_remaining_ticks = state.attack_impact_tick -| authority_tick,
            .attack_ready_remaining_ticks = state.attack_ready_tick -| authority_tick,
        };
    }

    pub fn localHud(self: *Owner, input: HudInput) LocalHud {
        var available = input.life_state != null;
        var health: u16 = 0;
        var maximum_health: u16 = 0;
        var life_state = input.life_state orelse protocol.AvatarLifeState.dead;
        var incarnation = input.incarnation;

        if (input.character) |character| {
            available = true;
            health = character.health;
            maximum_health = character.maximum_health;
            life_state = character.life_state;
            incarnation = character.incarnation;
        }
        // Reliable local life feedback closes the short window before the
        // corresponding snapshot. Incarnation matching prevents an old death
        // from overriding a replacement avatar.
        if (self.latest_life) |event| {
            if (std.meta.eql(event.avatar, input.avatar) and
                event.incarnation == input.incarnation)
            {
                available = true;
                health = event.health;
                maximum_health = event.maximum_health;
                life_state = event.state;
                incarnation = event.incarnation;
            }
        }

        const melee_ready_tick = @max(
            input.melee_ready_tick,
            if (self.latest_melee) |result| result.ready_tick else 0,
        );
        var respawn_ready_tick = input.respawn_ready_tick;
        if (self.latest_life) |event| {
            if (std.meta.eql(event.avatar, input.avatar) and
                event.incarnation == incarnation)
            {
                respawn_ready_tick = @max(respawn_ready_tick, event.respawn_ready_tick);
            }
        }
        if (self.latest_respawn) |result| {
            if (result.incarnation == incarnation) {
                respawn_ready_tick = @max(respawn_ready_tick, result.ready_tick);
            }
        }

        const melee_remaining = melee_ready_tick -| input.authority_tick;
        const weapon_ready_tick = input.weapon_ready_tick;
        const reload_complete_tick = input.reload_complete_tick;
        const respawn_remaining = respawn_ready_tick -| input.authority_tick;
        const latest_respawn_disposition = if (self.latest_respawn) |result|
            if (result.incarnation == incarnation) result.disposition else null
        else
            null;
        const respawn_marker: RespawnMarker = if (life_state == .alive)
            .none
        else if (latest_respawn_disposition == .no_safe_spawn)
            .no_safe_spawn
        else if (respawn_remaining != 0)
            .countdown
        else
            .ready;

        const current_anchor = if (input.owned_vehicle) |vehicle|
            vehicle.position
        else if (input.character) |current_character|
            current_character.position
        else
            null;
        if (current_anchor) |position| {
            if (input.authority_tick >= self.hud_anchor_tick) {
                self.hud_anchor_position = position;
                self.hud_anchor_tick = input.authority_tick;
            }
        }

        return .{
            .authority_tick = input.authority_tick,
            .available = available,
            .avatar = input.avatar,
            .incarnation = incarnation,
            .health = health,
            .maximum_health = maximum_health,
            .life_state = life_state,
            .melee_remaining_ticks = melee_remaining,
            .respawn_remaining_ticks = respawn_remaining,
            .latest_melee_disposition = if (self.latest_melee) |result|
                result.disposition
            else
                null,
            // State is owned by the client's tick-ordered projection. The
            // latest action result remains feedback only; retaining its
            // earlier projection here would mask a later reload-completion
            // snapshot indefinitely.
            .weapon_mode = input.weapon_mode,
            .magazine_ammo = input.magazine_ammo,
            .reserve_ammo = input.reserve_ammo,
            .weapon_remaining_ticks = weapon_ready_tick -| input.authority_tick,
            .reload_remaining_ticks = reload_complete_tick -| input.authority_tick,
            .latest_weapon_disposition = if (self.latest_weapon) |result|
                result.disposition
            else
                null,
            .latest_respawn_disposition = latest_respawn_disposition,
            .melee_cooldown_marker = life_state == .alive and melee_remaining != 0,
            .respawn_marker = respawn_marker,
            .anchor_position = self.hud_anchor_position,
            .anchor_tick = self.hud_anchor_tick,
        };
    }
};

fn entityPlan(
    entity: identity.ReplicatedEntityId,
    incarnation: u16,
    health: u16,
    maximum_health: u16,
    life_state: protocol.AvatarLifeState,
    flash: bool,
    base_color: Color,
) EntityPlan {
    const dead = life_state == .dead;
    const fraction = if (maximum_health == 0)
        @as(f32, 0)
    else
        std.math.clamp(
            @as(f32, @floatFromInt(health)) /
                @as(f32, @floatFromInt(maximum_health)),
            0,
            1,
        );
    return .{
        .entity = entity,
        .incarnation = incarnation,
        .health = health,
        .maximum_health = maximum_health,
        .life_state = life_state,
        .hit_flash = flash and !dead,
        .dead = dead,
        .body_color = if (dead)
            colors.dead
        else if (flash)
            colors.hit_flash
        else
            base_color,
        .health_bar = .{
            .visible = maximum_health != 0,
            .fraction = fraction,
            .fill_color = if (dead) colors.dead else colors.health,
            .empty_color = colors.health_empty,
        },
    };
}

fn observe(
    observations: []Observation,
    authority_tick: u64,
    entity: identity.ReplicatedEntityId,
    incarnation: u16,
    health: u16,
) bool {
    var free: ?usize = null;
    var selected: ?usize = null;
    for (observations, 0..) |observation, index| {
        if (!observation.occupied) {
            if (free == null) free = index;
            continue;
        }
        if (std.meta.eql(observation.entity, entity)) {
            selected = index;
            break;
        }
    }
    const index = selected orelse free orelse @as(usize, entity.index) % observations.len;
    var observation = &observations[index];
    if (!observation.occupied or !std.meta.eql(observation.entity, entity) or
        observation.incarnation != incarnation)
    {
        observation.* = .{
            .occupied = true,
            .entity = entity,
            .incarnation = incarnation,
            .health = health,
            .observed_tick = authority_tick,
        };
        return false;
    }
    if (authority_tick >= observation.observed_tick) {
        if (health < observation.health) {
            observation.flash_until_tick = authority_tick +| hit_flash_ticks;
        }
        observation.health = health;
        observation.observed_tick = authority_tick;
    }
    return authority_tick < observation.flash_until_tick;
}

fn testCharacter(
    entity: identity.ReplicatedEntityId,
    incarnation: u16,
    health: u16,
) protocol.CharacterState {
    return .{
        .entity = entity,
        .owner = .{ .index = 0, .generation = 1 },
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .incarnation = incarnation,
        .health = health,
        .maximum_health = 100,
        .life_state = if (health == 0) .dead else .alive,
    };
}

fn npc(entity: identity.ReplicatedEntityId) protocol.NpcState {
    return .{
        .entity = entity,
        .position = .{ 0, 0, 0 },
        .velocity = .{ 0, 0, 0 },
        .facing_yaw = 0,
        .state = .active,
        .incarnation = 1,
        .health = 100,
        .maximum_health = 100,
        .life_state = .alive,
        .encounter_state = .patrolling,
    };
}

test "health transitions emit one bounded tick-keyed hit flash" {
    var owner = Owner{};
    const entity = identity.ReplicatedEntityId{ .index = 7, .generation = 2 };
    try std.testing.expect(!owner.characterPlan(10, testCharacter(entity, 1, 100), true).hit_flash);
    const hit = owner.characterPlan(12, testCharacter(entity, 1, 75), true);
    try std.testing.expect(hit.hit_flash);
    try std.testing.expectEqualDeep(colors.hit_flash, hit.body_color);
    try std.testing.expect(owner.characterPlan(19, testCharacter(entity, 1, 75), true).hit_flash);
    try std.testing.expect(!owner.characterPlan(20, testCharacter(entity, 1, 75), true).hit_flash);
}

test "new incarnation and healing never manufacture a damage flash" {
    var owner = Owner{};
    const entity = identity.ReplicatedEntityId{ .index = 4, .generation = 1 };
    _ = owner.characterPlan(1, testCharacter(entity, 1, 80), false);
    try std.testing.expect(!owner.characterPlan(2, testCharacter(entity, 1, 100), false).hit_flash);
    try std.testing.expect(!owner.characterPlan(3, testCharacter(entity, 2, 100), false).hit_flash);
}

test "NPC render plan exposes windup deadlines and dead presentation" {
    var owner = Owner{};
    var state = npc(.{ .index = 30, .generation = 1 });
    state.encounter_state = .attack_windup;
    state.attack_impact_tick = 55;
    state.attack_ready_tick = 72;
    const windup = owner.npcPlan(50, state);
    try std.testing.expect(windup.windup);
    try std.testing.expectEqual(@as(u64, 5), windup.attack_impact_remaining_ticks);
    try std.testing.expectEqual(@as(u64, 22), windup.attack_ready_remaining_ticks);
    try std.testing.expectEqualDeep(colors.npc_windup, windup.entity.body_color);

    state.life_state = .dead;
    state.health = 0;
    const dead = owner.npcPlan(51, state);
    try std.testing.expect(dead.entity.dead);
    try std.testing.expect(!dead.windup);
    try std.testing.expectEqualDeep(colors.dead, dead.entity.body_color);
    try std.testing.expectEqual(@as(f32, 0), dead.entity.health_bar.fraction);
}

test "NPC role color yields to hostility encounter hit and death feedback" {
    var owner = Owner{};
    var state = npc(.{ .index = 32, .generation = 1 });
    state.population_member = 2;
    state.population_role = .worker;
    state.combat_disposition = .passive;
    state.activity_kind = .commute;
    state.activity_state = .traveling;
    try std.testing.expectEqualDeep(
        colors.npc_worker,
        owner.npcPlan(1, state).entity.body_color,
    );

    state.combat_disposition = .hostile_to_players;
    try std.testing.expectEqualDeep(
        colors.npc_hostile,
        owner.npcPlan(2, state).entity.body_color,
    );
    state.encounter_state = .searching;
    try std.testing.expectEqualDeep(
        colors.npc_searching,
        owner.npcPlan(3, state).entity.body_color,
    );
    state.health = 70;
    try std.testing.expectEqualDeep(
        colors.hit_flash,
        owner.npcPlan(4, state).entity.body_color,
    );
    state.health = 0;
    state.life_state = .dead;
    try std.testing.expectEqualDeep(
        colors.dead,
        owner.npcPlan(5, state).entity.body_color,
    );
}

test "NPC damage flash expires on the common authority clock" {
    var owner = Owner{};
    var state = npc(.{ .index = 31, .generation = 1 });
    try std.testing.expect(!owner.npcPlan(10, state).entity.hit_flash);
    state.health = 66;
    try std.testing.expect(owner.npcPlan(20, state).entity.hit_flash);
    try std.testing.expect(owner.npcPlan(27, state).entity.hit_flash);
    try std.testing.expect(!owner.npcPlan(28, state).entity.hit_flash);
}

test "local HUD saturates cooldowns and retains no-safe-spawn disposition" {
    var owner = Owner{};
    const avatar = identity.ReplicatedEntityId{ .index = 1, .generation = 1 };
    owner.noteFeedback(avatar, .{ .melee = .{
        .sequence = .{ .value = 1 },
        .disposition = .cooldown,
        .ready_tick = 108,
    } });
    owner.noteFeedback(avatar, .{ .life = .{
        .avatar = avatar,
        .incarnation = 3,
        .authority_tick = 100,
        .health = 0,
        .maximum_health = 100,
        .state = .dead,
        .respawn_ready_tick = 120,
    } });
    owner.noteFeedback(avatar, .{ .respawn = .{
        .sequence = .{ .value = 2 },
        .disposition = .no_safe_spawn,
        .incarnation = 3,
        .ready_tick = 120,
    } });
    const hud = owner.localHud(.{
        .authority_tick = 100,
        .avatar = avatar,
        .incarnation = 3,
        .life_state = .dead,
        .melee_ready_tick = 0,
        .respawn_ready_tick = 0,
        .character = testCharacter(avatar, 3, 100),
    });
    try std.testing.expect(hud.available);
    try std.testing.expectEqual(@as(u16, 0), hud.health);
    try std.testing.expectEqual(@as(u64, 8), hud.melee_remaining_ticks);
    try std.testing.expectEqual(@as(u64, 20), hud.respawn_remaining_ticks);
    try std.testing.expectEqual(
        protocol.RespawnActionDisposition.no_safe_spawn,
        hud.latest_respawn_disposition.?,
    );
    try std.testing.expect(hud.noSafeSpawn());
    try std.testing.expectEqualDeep(
        colors.no_safe_spawn,
        respawnMarkerColor(hud.respawn_marker).?,
    );
    try std.testing.expect(!hud.melee_cooldown_marker);
}

test "local HUD does not let old weapon feedback mask a newer projection" {
    var owner = Owner{};
    const avatar = identity.ReplicatedEntityId{ .index = 1, .generation = 1 };
    owner.noteFeedback(avatar, .{ .weapon = .{
        .sequence = .{ .value = 4 },
        .authority_tick = 10,
        .action = .reload,
        .disposition = .reload_started,
        .mode = .reloading,
        .magazine_ammo = 0,
        .reserve_ammo = 36,
        .weapon_ready_tick = 0,
        .reload_complete_tick = 100,
    } });
    const completed = owner.localHud(.{
        .authority_tick = 100,
        .avatar = avatar,
        .incarnation = 1,
        .life_state = .alive,
        .melee_ready_tick = 0,
        .weapon_mode = .equipped,
        .magazine_ammo = 12,
        .reserve_ammo = 24,
        .weapon_ready_tick = 0,
        .reload_complete_tick = 0,
        .respawn_ready_tick = 0,
        .character = testCharacter(avatar, 1, 100),
    });
    try std.testing.expectEqual(protocol.WeaponMode.equipped, completed.weapon_mode);
    try std.testing.expectEqual(@as(u16, 12), completed.magazine_ammo);
    try std.testing.expectEqual(@as(u16, 24), completed.reserve_ammo);
    try std.testing.expectEqual(@as(u64, 0), completed.reload_remaining_ticks);
    try std.testing.expectEqual(
        protocol.WeaponActionDisposition.reload_started,
        completed.latest_weapon_disposition.?,
    );
}

test "local HUD uses vehicle anchor and retains the last position without an avatar proxy" {
    var owner = Owner{};
    const avatar = identity.ReplicatedEntityId{ .index = 1, .generation = 1 };
    var current_character = testCharacter(avatar, 1, 100);
    current_character.position = .{ 1, 2, 3 };
    const on_foot = owner.localHud(.{
        .authority_tick = 10,
        .avatar = avatar,
        .incarnation = 1,
        .life_state = .alive,
        .melee_ready_tick = 0,
        .respawn_ready_tick = 0,
        .character = current_character,
    });
    try std.testing.expectEqualDeep([3]f32{ 1, 2, 3 }, on_foot.anchor_position.?);

    const vehicle = protocol.VehicleState{
        .entity = .{ .index = 20, .generation = 1 },
        .position = .{ 7, 1, -4 },
        .rotation = .{ 0, 0, 0, 1 },
        .linear_velocity = .{ 0, 0, 0 },
        .angular_velocity = .{ 0, 0, 0 },
        .driver = current_character.owner,
    };
    const driving = owner.localHud(.{
        .authority_tick = 11,
        .avatar = avatar,
        .incarnation = 1,
        .life_state = .alive,
        .melee_ready_tick = 0,
        .respawn_ready_tick = 0,
        .owned_vehicle = vehicle,
    });
    try std.testing.expectEqualDeep([3]f32{ 7, 1, -4 }, driving.anchor_position.?);

    const absent_dead = owner.localHud(.{
        .authority_tick = 12,
        .avatar = avatar,
        .incarnation = 1,
        .life_state = .dead,
        .melee_ready_tick = 0,
        .respawn_ready_tick = 20,
    });
    try std.testing.expectEqualDeep([3]f32{ 7, 1, -4 }, absent_dead.anchor_position.?);
    try std.testing.expectEqual(@as(u64, 11), absent_dead.anchor_tick);
    try std.testing.expectEqual(RespawnMarker.countdown, absent_dead.respawn_marker);
}

test "render geometry is bounded and left anchored" {
    const geometry = healthBarGeometry(.{
        .visible = true,
        .fraction = 0.25,
        .fill_color = colors.health,
        .empty_color = colors.health_empty,
    }, 1.2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), geometry.fill_width, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.45), geometry.fill_center_offset, 0.0001);
}

test "feedback queue preserves bounded FIFO order" {
    var queue = FeedbackQueue{};
    try queue.push(.{ .melee = .{
        .sequence = .{ .value = 1 },
        .disposition = .miss,
    } });
    try queue.push(.{ .respawn = .{
        .sequence = .{ .value = 2 },
        .disposition = .cooldown,
        .incarnation = 1,
        .ready_tick = 30,
    } });
    try std.testing.expect(queue.pop().? == .melee);
    try std.testing.expect(queue.pop().? == .respawn);
    try std.testing.expect(queue.pop() == null);
}

test "feedback queue admits the declared reliable-event ceiling" {
    try std.testing.expectEqual(
        @as(usize, budgets.max_reliable_events_per_tick),
        feedback_capacity,
    );
    var queue = FeedbackQueue{};
    for (0..feedback_capacity) |index| {
        try queue.push(.{ .melee = .{
            .sequence = .{ .value = @intCast(index + 1) },
            .disposition = .miss,
        } });
    }
    try std.testing.expectError(
        error.CombatFeedbackQueueFull,
        queue.push(.{ .melee = .{
            .sequence = .{ .value = @intCast(feedback_capacity + 1) },
            .disposition = .miss,
        } }),
    );
    for (0..feedback_capacity) |index| {
        const feedback = queue.pop() orelse return error.MissingCombatFeedback;
        try std.testing.expect(feedback == .melee);
        try std.testing.expectEqual(
            @as(u32, @intCast(index + 1)),
            feedback.melee.sequence.value,
        );
    }
    try std.testing.expect(queue.pop() == null);
}
