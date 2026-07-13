# S3-B Cooked and Resident Resource Baseline

**Date:** 2026-07-12  
**Platform:** Apple Silicon macOS / Metal  
**Mode:** Debug native startup characterization; capacities are enforced in all
build modes.

## Fixture Volumes

| Resource | Observed |
|---|---:|
| Installed cooked bundle | 868 bytes |
| Cooked nodes | 2 |
| Cooked meshes / primitives | 1 / 1 |
| Cooked materials / textures | 1 / 1 |
| Vertices / indices | 3 / 3 |
| Decoded RGBA8 pixels | 8 bytes |
| Static logical boxes | 3 |
| Registry-owned staged CPU bytes | 344 bytes |
| Submitted/resident GPU bytes | 116 bytes |

The 116 GPU bytes are 96 vertex bytes, 12 index bytes, and 8 texture bytes.
The fixture deliberately proves semantic preservation and ownership rather
than throughput.

## Enforced Limits

| Budget | Limit |
|---|---:|
| Cooked file | 64 KiB |
| Strings / pixels | 4 KiB / 4 KiB |
| Nodes / meshes / primitives | 8 / 2 / 4 |
| Materials / textures | 4 / 2 |
| Vertices / indices | 128 / 384 |
| Static boxes | 8 |
| Scene registry slots | 4 |
| In-flight batches | 2 |
| Scenes per batch | 4 |
| Meshes/materials/textures per scene | 8 / 8 / 8 |
| Instances per scene | 32 |
| Staged CPU bytes | 16 MiB |
| In-flight upload bytes | 16 MiB |
| Resident GPU bytes | 32 MiB |
| Submission bytes per pump | 8 MiB |

Every admission projects current staging, in-flight, and resident accounting
before allocating or submitting. Capacity failures are backpressure, not a
request to wait or exceed the budget.

## Interpretation

This baseline establishes count and byte accounting, not asset throughput or a
shipping memory target. One tiny scene does not justify render queues,
hardware-instanced draw submission, culling, LOD, compression, mip streaming,
or a general upload heap. S3-C will add repeated end-to-end timing and lifecycle
evidence once proximity policy drives real load/unload transitions.
