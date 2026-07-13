# S6 District Catalog Declaration

`catalog.txt` is the checked-in, canonical source declaration for the bounded
S6 district catalog. Entries are ordered by semantic ID. The final field is a
comma-free dependency semantic ID or `-` when the entry has no dependency.

The catalog cooker resolves each declared bundle key only from explicit bundle
file arguments supplied by the build graph. It derives exact bundle identities
and coordinate-specific logical checksums; paths and timestamps are not stored
in the cooked catalog.

This is engine-owned conformance data, not game content.
