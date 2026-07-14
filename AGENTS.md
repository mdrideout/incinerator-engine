# Incinerator Engine AGENTS.md

## Developer philosophy

- Be grug brained: prefer simple, explicit code and contracts.
- Everything is greenfield. Intentional breaking changes are allowed, but they must be documented and coordinated across every affected component.
- Do complete, well-architected work. Do not add compatibility fallbacks or abstractions that hide ownership.
- Follow single responsibility and separation of concerns.
- Ground plans and reviews in current code and accepted ADRs.
- Avoid scope creep and preserve unrelated user work.
- Do not engage in scope creep. Do not take liberties to refactor or change things that do not need to change beyond the requested implementations and ideas. Keep existing user-interfaces, styles, contracts, integrations, system -> system mechanics as they are unless it's required to change them as part of new feature implementation. Keep changes necessary and required. As much as needed, as little as possible.