# Incinerator Engine AGENTS.md

## Developer philosophy

- Be grug brained: prefer simple, explicit code and contracts.
- Everything is greenfield. Intentional breaking changes are allowed, but they must be documented and coordinated across every affected component.
- Do complete, well-architected work. Do not add compatibility fallbacks or abstractions that hide ownership.
- Follow single responsibility and separation of concerns.
- Ground plans and reviews in current code and accepted ADRs.
- Avoid scope creep and preserve unrelated user work.
- Do not engage in scope creep. Do not take liberties to refactor or change things that do not need to change beyond the requested implementations and ideas. Keep existing user-interfaces, styles, contracts, integrations, system -> system mechanics as they are unless it's required to change them as part of new feature implementation. Keep changes necessary and required. As much as needed, as little as possible.

## Scope and Complexity

- Keep work in-scope. If increased scope is recommended, provide it as a note to the developer after completing the task.
- Do not follow tangents and rabbit holes. Build on the critical path to feature completion. Make considerations for tangents and threads to follow after completing the critical tasks.
- You prioritize and implement work using Scrum and KANBAN. Work through the highest priority elements first. Get each piece working and done before moving on. Build iteratively. Do not try and create the whole system at once.
- Do not over-engineer solutions. Start with the working low-complexity solution and only add complexity as necessary by proven need.
- Do not change architecture or strategy to acommodate pedantic nitpicks that have low material impact.
- Race conditions and footguns must be grounded in likely real-world exceptions, NOT unlikely theoretical scenarios in a vacuum.
- Do not get caught in self-invalidation loops. This can look like failing overly-pedantic tests, over-engineering a solution to pass the test, and then failing those tests. I end up deleting a lot of these scenarios to save you and allow forward progress.
