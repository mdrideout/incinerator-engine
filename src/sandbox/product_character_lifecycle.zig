//! Normal-product ownership for the local authority-managed character across
//! death and respawn.
//!
//! The raw character observation lane is shared with host bootstrap, so every
//! lifecycle transition is correlated with the local reliable life state and
//! replicated avatar before it may replace the composition's current
//! persistent identity.

const std = @import("std");
const engine = @import("engine_contracts");
const identity = @import("session_identity");

pub const Owner = struct {
    bootstrapped: bool = false,
    dying_character: ?engine.PersistentId = null,
    dead_character: ?engine.PersistentId = null,
    dead_avatar: identity.ReplicatedEntityId = .invalid,
    dead_incarnation: u16 = 0,
    respawn_character: ?engine.PersistentId = null,
    respawn_avatar: identity.ReplicatedEntityId = .invalid,

    pub fn observeSpawn(
        self: *Owner,
        current: *?engine.PersistentId,
        spawned: anytype,
        hud: anytype,
        projected: identity.ReplicatedEntityId,
    ) !void {
        if (!self.bootstrapped) {
            if (spawned.request_id != 1 or current.* != null or
                self.dying_character != null or self.dead_character != null or
                self.dead_avatar.isValid() or self.dead_incarnation != 0 or
                self.respawn_character != null or self.respawn_avatar.isValid())
            {
                return error.UnexpectedProductCharacterBootstrapOutcome;
            }
            self.bootstrapped = true;
            current.* = spawned.id;
            return;
        }

        const dead_character = self.dead_character orelse
            return error.UnexpectedProductCharacterRespawnOutcome;
        if (spawned.request_id == 1 or current.* != null or
            self.dying_character != null or std.meta.eql(dead_character, spawned.id) or
            self.respawn_character != null or self.respawn_avatar.isValid() or
            !self.dead_avatar.isValid() or self.dead_incarnation == 0 or
            !hud.available or hud.life_state != .dead or
            hud.incarnation != self.dead_incarnation or
            !std.meta.eql(hud.avatar, self.dead_avatar) or
            projected.index != self.dead_avatar.index or
            projected.generation <= self.dead_avatar.generation or
            projected.generation <= self.dead_incarnation)
        {
            return error.UnexpectedProductCharacterRespawnOutcome;
        }
        // Character spawn and vitals registration are deliberately separate
        // authority ticks. Retain the raw identities, but do not expose the new
        // current character until the correlated respawn result arrives.
        self.respawn_character = spawned.id;
        self.respawn_avatar = projected;
    }

    pub fn observeDespawn(
        self: *Owner,
        current: *?engine.PersistentId,
        id: engine.PersistentId,
        hud: anytype,
    ) !void {
        const expected = current.* orelse
            return error.UnexpectedProductCharacterDeathOutcome;
        if (!self.bootstrapped or !std.meta.eql(expected, id) or
            !std.meta.eql(self.dying_character orelse
                return error.UnexpectedProductCharacterDeathOutcome, id) or
            self.dead_character != null or !self.dead_avatar.isValid() or
            self.dead_incarnation == 0 or !hud.available or
            hud.life_state != .dead or hud.incarnation != self.dead_incarnation or
            !std.meta.eql(hud.avatar, self.dead_avatar) or
            self.respawn_character != null or self.respawn_avatar.isValid())
        {
            return error.UnexpectedProductCharacterDeathOutcome;
        }
        current.* = null;
        self.dying_character = null;
        self.dead_character = id;
    }

    pub fn observeLocalLife(
        self: *Owner,
        current: ?engine.PersistentId,
        projected: identity.ReplicatedEntityId,
        hud: anytype,
        event: anytype,
    ) !void {
        if (!self.bootstrapped or current == null or
            !std.meta.eql(projected, event.avatar) or
            event.incarnation != projected.generation or
            !std.meta.eql(hud.avatar, event.avatar) or
            hud.incarnation != event.incarnation or hud.life_state != event.state)
        {
            return error.UnexpectedProductCharacterLifeEvent;
        }
        switch (event.state) {
            .alive => {},
            .dead => {
                if (self.dying_character != null or self.dead_character != null or
                    self.dead_avatar.isValid() or self.dead_incarnation != 0 or
                    self.respawn_character != null or self.respawn_avatar.isValid())
                {
                    return error.UnexpectedProductCharacterLifeEvent;
                }
                self.dying_character = current;
                self.dead_avatar = event.avatar;
                self.dead_incarnation = event.incarnation;
            },
        }
    }

    pub fn observeRespawnResult(
        self: *Owner,
        current: *?engine.PersistentId,
        hud: anytype,
        result: anytype,
    ) !void {
        if (result.disposition != .respawned) return;
        const respawn_character = self.respawn_character orelse
            return error.UnexpectedProductCharacterRespawnResult;
        if (!self.bootstrapped or current.* != null or
            self.dying_character != null or self.dead_character == null or
            !self.dead_avatar.isValid() or self.dead_incarnation == 0 or
            !self.respawn_avatar.isValid() or
            !hud.available or hud.life_state != .alive or
            !std.meta.eql(self.respawn_avatar, result.avatar) or
            !std.meta.eql(hud.avatar, result.avatar) or
            hud.incarnation != result.incarnation or
            result.incarnation <= self.dead_incarnation or
            result.avatar.generation != result.incarnation)
        {
            return error.UnexpectedProductCharacterRespawnResult;
        }
        current.* = respawn_character;
        self.dying_character = null;
        self.dead_character = null;
        self.dead_avatar = .invalid;
        self.dead_incarnation = 0;
        self.respawn_character = null;
        self.respawn_avatar = .invalid;
    }
};
