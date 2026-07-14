# MP5 Acceptance

**Accepted:** 2026-07-14

Focused proof:

```sh
zig build run-mp5-acceptance -j1 --summary all
```

Expected evidence:

```text
MP5_ROOM_PASS room=77 authority=9001 participants=2 identity_rejection=true service_independent=true route=127.0.0.1:27020
```

Full gate:

```sh
zig build verify-mp5 -j1 --summary all
```

The proof creates a dedicated direct-IP room, issues two bounded invitations,
rejects an expired invitation, distinguishes lobby leave from network loss,
then destroys the registry scope. Two configured clients still reach the
correct authority and receive authoritative gameplay state. An impostor using
another account with a copied authorization receives `unauthorized` before
participant allocation.

The gate also retains every MP4 fault, relevance, delta, GNS, persistence, and
architecture proof. No Steamworks dependency is present or required.
