# Sandbox Player Loop

**Status:** Proposed product acceptance direction; product-owner decision pending

**Recorded:** 2026-09-06, following the E2E review

## Intended ordinary play

Use the existing four-district sandbox to make a small, understandable journey:
start in the plaza, locate and collect a carryable, travel to a destination,
handle an encounter, and return to a safe place with a visible outcome. Walking,
driving, carrying, handgun/melee combat, damage/death/respawn, authored population,
and semantic destinations supply the current mechanics.

The proposed player motivation is completing a delivery in a populated,
reactive place. Destination choice, delivery completion, and reward are product
decisions still to make. The engine currently demonstrates the mechanics and
their authority/presentation contracts; it does not yet implement a mission,
delivery objective, economy, or persistent progression system.

## Use the current authoring sequence to improve this journey

| Phase | Concrete contribution | Acceptance question |
|---|---|---|
| EA1-A | Readable textured project assets | Can the player distinguish route landmarks, obstacles, and interactable objects? |
| EA1-B | One complete material workflow on a title asset | Can an author inspect, preview, edit, revert, and commit that asset's material and observe it in play? |
| EA2 | Vehicle archetype | Can an author tune the vehicle used to traverse the same journey and inspect the resulting handling? |
| EA3 | Lighting | Does authored lighting preserve route, target, and combat readability? |
| EA4 | Map authoring | Can the journey's start, route, encounter, and destination be authored and replayed with stable identity? |
| EA5 | Separately built engine and game | Can the same authored journey run from an independently built game/content package? |

Preserve the accepted S15 gameplay journey at each step. A passing source-package
gate remains packaging evidence; EA5 must prove an independent engine consumer.
Keep the solo, private-listen, and dedicated authority boundaries, while tracking
the remaining network presentation/product integration as explicit future work.

## What closes the product checkpoint

An ordinary player should understand where to go, what can be used, why an
interaction succeeded or failed, and how to recover after death. Record observable
outcomes for travel, collection/drop, encounter, and recovery using existing
gameplay/incident evidence. Human review judges readability, controls, and whether
the journey is worthwhile; automation verifies authority, rendering, routing,
identity, and recovery. Do not substitute tooling completeness for this review.

This proposal adds no mission framework, scripting runtime, public service,
new platform, crowd solver, or neural-rendering work. Implement a title feature
only after its concrete rules and acceptance outcome are selected.
