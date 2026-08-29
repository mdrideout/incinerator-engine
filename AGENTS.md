# Incinerator Engine AGENTS.md

## Developer philosophy

- Be grug brained: prefer simple, explicit code and contracts.
- Everything is greenfield. Intentional breaking changes are allowed, but they must be documented and coordinated across every affected component.
- Do complete, well-architected work. Do not add compatibility fallbacks or abstractions that hide ownership.
- Follow single responsibility and separation of concerns.
- Ground plans and reviews in current code and accepted ADRs.
- Avoid scope creep and preserve unrelated user work.
- Do not engage in scope creep. Do not take liberties to refactor or change things that do not need to change beyond the requested implementations and ideas. Keep existing user-interfaces, styles, contracts, integrations, system -> system mechanics as they are unless it's required to change them as part of new feature implementation. Keep changes necessary and required. As much as needed, as little as possible.
- Do not set arbitrary contraints, budgets, caps, limitations. Do not truncate content. Do not set timeouts. Do not make assumptions about how much we can handle. Allow us to run into the exceptions when resources, time lengths, or capacity are exceeded. We will only create constraints as we encounter real exceptions caused by a real repeatable documented problem or limit.

## Scope and Complexity

- Keep work in-scope. If increased scope is recommended, provide it as a note to the developer after completing the task.
- Do not follow tangents and rabbit holes. Build on the critical path to feature completion. Make considerations for tangents and threads to follow after completing the critical tasks.
- You prioritize and implement work using Scrum and KANBAN. Work through the highest priority elements first. Get each piece working and done before moving on. Build iteratively. Do not try and create the whole system at once.
- Do not over-engineer solutions. Start with the working low-complexity solution and only add complexity as necessary by proven need.
- Do not change architecture or strategy to acommodate pedantic nitpicks that have low material impact.
- Race conditions and footguns must be grounded in likely real-world exceptions, NOT unlikely theoretical scenarios in a vacuum.
- Do not get caught in self-invalidation loops. This can look like failing overly-pedantic tests, over-engineering a solution to pass the test, and then failing those tests. I end up deleting a lot of these scenarios to save you and allow forward progress.

## Editor Interaction

- Before changing SDL input routing, ImGui capture, viewport modes, selection,
  gizmos, shortcuts, system menus, or renderer overlays, read
  `skills/incinerator-editor-interaction/SKILL.md` and
  `docs/adr/030-editor-input-routing-and-interaction-capture.md` completely.
- Model the full press/drag/release/cancel journey and its winning owner before
  implementation. Keep viewport mode, pointer lock, interaction capture,
  simulation pause, diagnostics, selection, and authoring state independent.
- Do not rely on previous-frame ImGui capture for a new event, place a
  full-scene ImGui window over the renderer, or let raw Escape bypass an active
  interaction and application-menu routing.
- Every interaction change requires deterministic routing coverage and the
  applicable native SDL/Metal acceptance; human review is reserved for
  usability and visual feel.

## Neural Rendering

- Neural rendering is paused indefinitely by product-owner decision. Read `docs/design/neural-rendering-pause.md` first. Do not initiate, extend, retrain, optimize, promote, or begin another neural-rendering phase unless the user explicitly requests that the track resume. Deterministic rendering is the active product focus; preserve the retained neural work without expanding it.
- For neural-rendering research, capture, experiments, model bundles, promotion, runtime inference, or NR0 work, read `skills/incinerator-neural-rendering/SKILL.md`, `docs/adr/025-game-specific-neural-rendering-boundary.md`, `docs/adr/026-from-scratch-title-neural-renderer.md`, and `docs/design/title-neural-renderer-north-star.md` before acting. Keep deterministic authority, mutable experiment artifacts, and deliberately promoted runtime game content as separate owners. Promotion-eligible learned components are title-specific and trained from random initialization; external pretrained models are comparison evidence only.
