# ADR-005: Physics-ECS Integration Strategy

## Status
Accepted

## Context

The engine uses two separate systems for game objects:
- **ECS (flecs)**: Manages entities, components, and queries for rendering
- **Physics (Jolt via zphysics)**: Simulates rigid body dynamics, collisions, constraints

These systems must be connected so that physics simulation results are reflected in rendered visuals. The core question: **who owns the transform, and how does data flow between systems?**

## Decision

We adopt **Approach 2: RigidBody Component in ECS** with explicit sync.

### Pattern

```
simulateTick() {
    physics.update(dt)      // Physics steps forward
    syncPhysicsToECS()      // Copy physics transforms → ECS components
}

render() {
    // Render from ECS (already updated)
}
```

### Component Design

Entities with physics have a `RigidBody` component storing the physics body ID:

```zig
pub const RigidBody = struct {
    body_id: zphysics.BodyId,
};
```

A sync system queries all entities with `(Position, Rotation, RigidBody)` and copies transforms from physics to ECS each tick.

## Rationale

### Alternatives Considered

**Approach 1: Physics-Owned Transforms**
- Physics engine is authoritative; rendering queries physics directly
- Problem: No unified entity model. "Where is entity X?" has two answers depending on whether it has physics.

**Approach 3: Physics Writes Directly to ECS**
- Physics system holds entity IDs and writes components during simulation
- Problem: Tight coupling. Physics must understand ECS structure. Harder to debug.

### Why Approach 2

1. **Single source of truth for game state**: ECS owns all entity data. Physics is an input, not the authority.

2. **Unified entity model**: Static props, animated characters, physics objects, and vehicles are all entities with different component combinations. Same queries, same inspector, same serialization.

3. **Clear data flow**: Physics → sync → ECS → Rendering. Easy to reason about, easy to debug.

4. **Mode switching**: A character can transition from animation-driven to ragdoll by swapping components. The entity persists; only its physics representation changes.

5. **Editor compatibility**: The Scene inspector (already implemented) shows ECS state. Physics entities appear automatically with correct positions.

## Complex Scenarios

### Ragdolls

A ragdoll is multiple physics bodies (one per bone) connected by joints. Two options:

**A) One entity per bone**: Each bone entity has `RigidBody`. Hierarchy via ECS parent-child. Sync updates each bone's transform.

**B) Single entity with RagdollController**: One entity holds an array of body IDs. Sync writes to a bone transform buffer consumed by skinned mesh rendering.

Option B is preferred for characters since:
- Character is conceptually one entity
- Switching between animation and ragdoll is component swap
- Skinned meshes already consume bone arrays

### Vehicles

Vehicles use specialized physics (chassis + wheel constraints). The pattern:

```zig
pub const VehiclePhysics = struct {
    chassis_body: BodyId,
    vehicle_constraint: *VehicleConstraint,
};
```

Sync reads chassis transform → entity Position/Rotation. Wheel positions come from the constraint and update child entities or a wheel transform array.

### Partial Physics

Some objects need physics for part of their lifetime:
- Debris: spawns with physics, comes to rest, becomes static
- Doors: kinematic until broken, then dynamic
- Characters: animation-driven until death, then ragdoll

Component composition handles this: add/remove `RigidBody` or swap controller components. The entity persists through mode changes.

## Consequences

### Positive
- Consistent entity model across all object types
- Existing tools (Scene inspector) work automatically
- Physics is decoupled from rendering
- Easy to add/remove physics at runtime

### Negative
- One frame of latency between physics and rendering (acceptable at 120Hz)
- Sync system must run every tick (minimal overhead)
- Must be careful about modifying Position directly on physics entities (sync will overwrite)

### Future Considerations
- Interpolation between physics frames for smoother rendering
- Kinematic bodies (ECS → physics for animated objects that affect physics)
- Compound colliders (multiple shapes per entity)

## References
- ADR-004: ECS Architecture
- Jolt Physics documentation on body management
- Unity/Unreal physics-rendering patterns
