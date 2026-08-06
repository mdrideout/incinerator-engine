# Neural Rendering Offline Tools

This directory is reserved for the NR0 offline workflow. No neural-rendering
tool is implemented yet.

As NR0 phases require them, add narrow entry points for:

1. deterministic paired capture and inspection;
2. training one declared experiment;
3. held-out evaluation and comparison generation;
4. export into the selected macOS runtime format;
5. transactional model promotion; and
6. promoted-bundle and installed-content verification.

Training frameworks and their environments stay here or in an explicitly
managed external environment. They cannot enter the product, validation-only
Metal host, headless authority, or server dependency graphs merely because a
build step can invoke the tool.

Prefer explicit paths and self-describing manifests. Do not discover a global
dataset, a mutable `latest` checkpoint, or an ambient model cache. A Zig build
step may orchestrate a tool after the command exists, but the underlying tool
must remain directly runnable and inspectable.

Promotion must follow
[ADR-025](../../docs/adr/025-game-specific-neural-rendering-boundary.md) and
must never mutate the source experiment run.

