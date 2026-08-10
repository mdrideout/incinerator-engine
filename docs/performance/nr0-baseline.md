# NR0 Neural Rendering Performance Baseline

**Status:** NR-0001, NR0-A/B foundation, NR0-C/D, NR-0003, NR4-A/B/C/D, and
NR5-A through NR5-E measured; promoted installed-runtime baseline open

**Date:** 2026-08-10

Record the first accepted baseline here. Do not copy performance from research
papers into the Incinerator result table.

The report must name:

- Apple hardware, OS, power state, and relevant GPU/runtime backend;
- engine/model/content/shader/schema revisions and model digest;
- build mode and inference precision;
- input, structural-buffer, target, and display dimensions;
- model load time and resource residency;
- CPU frame, GPU raster, inference, post/UI, present, and end-to-end timing;
- p50, p95, p99, worst observed frame, and sustained frame pacing;
- model weights, activations, inputs, outputs, history, capture, and total process
  memory where observable;
- fallback cost and transition behavior; and
- whether capture/debug evidence was enabled.

No frame-rate, memory, model-size, or hardware support target is accepted until
this repository measures a repeatable real cohort.

## NR-0001 preliminary measurements

These numbers validate the local path; they are not an accepted shipping
budget.

| Item | Result |
|---|---|
| Hardware | MacBook Pro, Apple M2 Max, 38-core GPU, 64 GB unified memory |
| OS/runtime | macOS 15.7.7, Metal 3, Core ML, Python 3.13.12 |
| Training cohort | PyTorch 2.7.0, torchvision 0.22.0, MPS; 40 epochs over 80 exact engine train pairs |
| Model | 25,552 parameters, fixed 4x RGB residual upscaler, FP16 ML Program compute |
| Dimensions | 80x45 RGB input, 320x180 RGB output; live output linearly presented at the drawable size |
| Training wall time | 3,987 ms after environment/model startup |
| Validation | model MAE 0.04273 / PSNR 19.25 dB; bicubic MAE 0.05059 / PSNR 18.78 dB |
| Untouched test | model MAE 0.04348 / PSNR 19.16 dB; bicubic MAE 0.05134 / PSNR 18.68 dB |
| PyTorch/Core ML agreement | mean absolute error 0.000171; maximum 0.001274 |
| Core ML package load | 71.19 ms |
| Standalone Core ML prediction | 500 iterations after 50 warmups: p50 0.465 ms, p95 0.558 ms, p99 0.627 ms, max 0.716 ms |
| Native staged live path | 480 predictions: staged readback plus inference mean 5.579 ms, max 11.409 ms; last model inference 0.372 ms |
| Full scripted live proof | 3,840 S13 predictions, zero failures; S13 acceptance unchanged |

The staged number excludes asynchronous output-upload GPU completion and normal
scene/UI GPU work. It includes a blocking product-texture downsample/readback,
CPU layout conversion, and Core ML prediction. It therefore demonstrates the
cost center rather than hiding it: native Core ML execution is small for this
toy model, while CPU staging dominates. A GPU-resident adapter and complete
frame/GPU/memory instrumentation remain prerequisites for NR0-F acceptance.

## NR0-A/B foundation measurements

These figures characterize the input and capture foundation, not inference
performance or a shipping budget.

| Item | Result |
|---|---|
| Hardware/backend | Same Apple M2 Max host; debug build; SDL3 GPU Metal |
| Schema | `incinerator.neural-input.v1`, six 400×225 RGBA8 targets |
| Canonical paired target | 1600×900 RGBA8, derived from the exact submitted product scene before UI |
| Raw capture volume | 7,920,000 bytes per selected frame: 2,160,000 bytes of inputs plus 5,760,000 bytes of target, before PPM/manifests |
| Deterministic acceptance | Two 3,840-frame S13 launches at 240 Hz virtual presentation / 60 Hz simulation; 964 ticks each; six selected frames; zero capture failures; byte-identical declared buffers |
| Graphical lab smoke | Approximately 120 FPS / 8.3 ms reported by the existing debug frame counter with all six live targets and editor visible; not a percentile benchmark |
| Capture synchronization | Selected frames deliberately use a same-queue submit fence and blocking readback; normal frames do not pay this capture path |

The MRT pass itself still needs GPU timestamps, frame-time percentiles, memory
residency, and on/off A/B measurement in NR0-F. The deterministic 240 Hz value
is a scripted virtual presentation rate and must not be represented as measured
rendering throughput.

## NR0-C spatial candidate measurements

These numbers characterize the first 17-plane model and standalone Core ML
execution. They are not an installed end-to-end or shipping budget.

| Item | Result |
|---|---|
| Hardware/runtime | Same Apple M2 Max host; PyTorch 2.7.0 MPS; Core ML 9.0; macOS 15.7.7 |
| Model | 51,888 parameters; 24 features; three residual blocks; fixed 4× residual decoder |
| Stored artifacts | 213,685-byte PyTorch checkpoint; 119,721-byte Core ML package; 1,067,884,544-byte complete evidence root including 72 raw/debug paired frames and samples |
| Dimensions | 17 planes at 400×225; RGB output at 1600×900 |
| Precision/export | PyTorch FP32 training; FP16 macOS 15 ML Program candidate |
| Training | 80 epochs, 40 train frames, deterministic aligned 96×96 input patches, batch 4; epoch 80 selected by orbit-wide validation |
| Validation | model MAE 0.02556 / PSNR 22.51 dB / SSIM 0.8710; best baseline MAE 0.18025 / PSNR 13.91 dB / SSIM 0.8074 |
| Untouched test | model MAE 0.02556 / PSNR 24.18 dB / SSIM 0.8661; best baseline MAE 0.18479 / PSNR 13.90 dB / SSIM 0.7981 |
| PyTorch/Core ML agreement | mean absolute error 0.000103; maximum 0.000491 |
| Standalone Core ML prediction | `ALL`, 500 iterations after 50 warmups: p50 5.077 ms, p95 5.720 ms, p99 5.988 ms, max 6.096 ms |
| CPU+GPU comparison | 200 iterations after 20 warmups: p50 5.072 ms, p95 5.782 ms, p99 6.505 ms, max 6.771 ms |

The PyTorch full-frame p50 was approximately 2.8–2.9 ms after MPS warmup, but
that is an offline framework measurement and is not interchangeable with Core
ML or product frame timing. NR0-F still owns installed model/package memory,
activation residency, GPU timestamps, input raster cost, output composition,
UI/present, fallback transitions, sustained frame pacing, and end-to-end
latency.

## NR0-D offline stress-evaluation measurements

These figures describe exhaustive PyTorch/MPS evaluation and evidence
generation, not installed inference or a shipping memory/frame budget.

| Item | Result |
|---|---|
| Hardware/runtime | Same Apple M2 Max host; macOS 15.7.7; PyTorch 2.7.0 MPS; Python 3.13.12 |
| Candidate | Exact 51,888-parameter NR-0002 checkpoint; SHA-256 `35e286bc5d5018e0e6f2a409da5d23179f0cf1329d65d0f37c0da4e3917af749` |
| Cohort | Six immutable stress captures; 478 1600×900 canonical targets; 9,374 visible-instance records |
| Inference distribution | p50 3.430 ms; p95 5.784 ms; p99 7.473 ms; max 117.633 ms |
| Evaluation wall time | 1,417,652 ms (about 23.6 minutes) for metrics and 4,307 visual evidence files |
| Process peak RSS | 8,550,137,856 bytes |
| PyTorch MPS after evaluation | 399,396,352 bytes current allocated; 3,557,277,696 bytes driver allocated |
| External artifact volume | Approximately 11 GB retained run including the immutable superseded first report; crop-complete `evaluation-v2` approximately 2.3 GB |

The process and MPS values include the Python framework, complete metric
pipeline, and visual artifact generation. They cannot be used as model-runtime
residency. NR0-F must measure the promoted bundle through the installed
GPU-resident adapter before the engine accepts any runtime cost or hardware
envelope.

## NR-0003 external-model comparison

These numbers prove only that a large pretrained video prior can execute at the
requested quality-first proof rate on the target Mac. ADR-026 prevents these
weights from entering the title model lineage.

| Item | Structure schedule | Richness schedule |
|---|---:|---:|
| Hardware/runtime | Apple M2 Max, 64 GB unified memory; Python 3.13, PyTorch 2.13 MPS | Same |
| Model | LTX-Video 2B 0.9.8 distilled, external pretrained comparison | Same |
| Dimensions/cohort | 9 frames, 512×288, 8 FPS sequence | Same |
| Warm pipeline | 5.966 s | 6.079 s |
| Warm effective rate | 1.509 FPS | 1.480 FPS |
| Cold end-to-end | 30.872 s | 30.964 s |
| Peak process RSS | 7,918,895,104 bytes | 7,918,878,720 bytes |
| Disposition | Preserves major geometry but adds little fidelity | Adds rich materials/lighting by replacing authored geometry |

The complete evidence and measurement limitations are recorded in
[`NR-0003`](../../experiments/neural-rendering/nr-0003-ltxv-2b-distilled/README.md).
This result informs architecture only. Future performance baselines must name
the repository-defined model initialized and trained under ADR-026.

## NR4-A offline target-factory measurements

These figures measure offline training-truth manufacture, not runtime neural
rendering and not a shipping frame budget.

| Item | Result |
|---|---|
| Hardware/backend | Same Apple M2 Max host; Blender 4.5.12 LTS; Cycles Metal |
| Configuration | 1600×900, 256 fixed samples, seed 73, adaptive sampling and learned denoising disabled |
| Scene | 26-draw rights-clean procedural urban corner; 25 identities visible from the selected camera |
| Two target renders | 5,530.988 ms and 5,520.111 ms reported Cycles render time |
| Alignment | 0.975158 exact identity-over-union in both runs |
| Reproducibility | Engine source, target package, tooling snapshots, identity, and depth logical evidence exact; display maximum difference 1/255; normal maximum absolute difference 4.768e-7 |

The initial Metal kernel compilation is environment warmup and is recorded in
each target log; target production is intentionally offline.

## NR4-B offline moving-target measurements

These are measured data-factory costs for two exact 18-frame sequence proofs,
not an inference, training, or shipping budget.

| Item | Result |
|---|---|
| Hardware/backend | Same Apple M2 Max host; Blender 4.5.12 LTS; Cycles Metal |
| Configuration | 1600×900, 256 fixed samples, seed 73, adaptive sampling and learned denoising disabled |
| Cohort | Six causally isolated three-sample segments; 18 source/target pairs per proof |
| First proof target time | 132.762 seconds total; 4.994–18.167 seconds per target |
| Second proof target time | 133.374 seconds total; 4.966–18.511 seconds per target |
| Retained external evidence | Approximately 2.5 GB for both complete source, HDR target, auxiliary, alignment, report, log, and reproducibility cohorts |
| Alignment | 0.974974–0.987851 exact identity-over-union over all frames; no cheap-visible identity omitted |
| Reproducibility | Engine source, normalized packages, target identity, and target depth exact for all 18 corresponding frames; display maximum difference 1/255; normal maximum absolute difference 5.960e-7 |

The near-edge frames dominate the target-time range because the close glass and
lighting composition increases Cycles work. That observation is retained as
offline renderer behavior; it is not converted into an arbitrary corpus or
camera restriction.

## NR4-C native working-resolution measurements

These are fresh native-cohort data-factory measurements. They do not reuse or
reduce NR4-A/B target pixels and are not an inference or shipping-frame budget.

| Item | Result |
|---|---|
| Hardware/backend | Apple M2 Max, 64 GB unified memory; Blender 4.5.12 LTS; Cycles Metal |
| Native contract | Six direct 160×90 inputs; direct 400×225 scene-linear float32 target; exact 5:2 top-left pixel-center mapping |
| Cohort | One two-run still proof plus two 18-frame sequence proofs across six causal segments |
| Run A target time | 14.862 seconds total; 0.646–1.516 seconds per target; 0.826 seconds mean |
| Input adapter observation | 2.725 ms CPU command encoding total over 18 selected frames; 0.229 ms maximum; GPU raster time unavailable |
| Display-pair decode | 6.000–6.819 ms; 6.454 ms mean |
| Resize baselines | Nearest 0.057 ms mean; bilinear 0.365 ms; bicubic 0.564 ms |
| Peak target process RSS | 540,540,928 bytes; Cycles GPU-memory residency unavailable from the pinned Python surface |
| Run A evidence | 11,064,553 input bytes; 359,158 target-package bytes; 65,751,976 direct-target bytes; 11,607,072 analysis/report bytes |
| Retained two-run roots | 9,565,341 bytes for the still gate; 178,312,689 bytes for the sequence gate |
| Alignment | 0.940195–0.976374 exact identity-over-union; no input-visible identity omitted |
| Reproducibility | Inputs, normalized packages, identity, and depth exact; display maximum 1/255; normal maximum `9.537e-7` absolute / `1.767e-8` RMSE |

The accepted schema-4 closing sequence retains the same raster extents and adds
four frame-global float32 controls. They cost 16 training bytes per frame and
no additional GPU raster target or raster pixel. In its fresh Run A, 18 direct
targets render in 15.365 seconds and peak Blender process RSS is 544,800,768
bytes. Cross-run input/package/identity/depth evidence is exact; display
variation is at most 1/255 and normal variation at most `6.557e-7` absolute /
`1.774e-8` RMSE. The closing roots are named in the validation ledger.

The input timing measures host CPU command encoding, not GPU execution. The
manifest names this scope. No estimate is substituted for unavailable GPU
timestamps or memory residency.

## NR4-D paired-corpus measurements

These are offline data-factory and retained-evidence costs, not inference or
training budgets.

| Item | Result |
|---|---|
| Cohort | 6 whole sequences; 108 native pairs; overfit/train/validation/test plus 2 stress sequences |
| Target time | 86.245 seconds total; 0.544–1.662 seconds per direct 400×225 Cycles target |
| Peak target process RSS | 546,144,256 bytes |
| Input capture | 66,439,775 bytes across source runs |
| Target-frame packages | 2,183,562 bytes across source runs |
| Direct target evidence | 381,465,647 bytes across source runs |
| Alignment/baseline/report evidence | 67,010,888 bytes across source runs |
| Alignment | 0.913698–0.977032 exact identity-over-union; no input-visible identity omitted |
| Self-contained corpus | Approximately 506 MiB |
| Complete retained proof | Approximately 1.0 GiB, including source runs, corpus, logs, and review evidence |

The superseded `-a` proof remains diagnostic evidence: its first partial
assembly exposed a policy implementation that incorrectly treated repeated
conditioning inside one sequence as split leakage, and its later review opened
the nominal test split. The accepted `-b` proof fixes both: leakage is enforced
across sequences, and test pixels cannot enter the review report.

## NR5-A/B from-scratch framework and controlled-overfit measurements

These measurements describe external PyTorch/MPS framework and controlled-fit
behavior. They are not installed inference, shipping performance, or a product
budget.

| Item | Result |
|---|---|
| Hardware/runtime | Apple M2 Max, 64 GB unified memory; macOS 15.7.7; Python 3.13.12; PyTorch 2.7.0 MPS; OpenEXR 3.4.14 |
| Clean-room lifecycle | 575.688 ms for initialize, train, checkpoint, immutable resume, evaluation, audit, and exact TorchScript export on the tiny framework fixture |
| Controlled model | 448,175 parameters; 36 learned tensors; two-branch low-resolution context plus target-grid structural reconstruction |
| Controlled cohort | 18 overfit frames; 11 continuous planes, categorical semantic/instance maps, 4 normalized global controls; direct 400×225 scene-linear HDR targets |
| Training | 240 declared epochs; epoch 238 retained; 208.399 seconds MPS wall time |
| Checkpoints | 1,811,179-byte random initializer; 5,438,465-byte trained checkpoint including optimizer/scheduler state and lineage |
| Controlled-fit quality | Model linear-HDR MAE 0.009956 vs best bilinear 0.447403; diagnostic-display MAE 0.013717 vs 0.366620 |
| Boundaries | Model semantic-boundary MAE 0.018672 vs bilinear 0.276200; instance-boundary MAE 0.036004 vs 0.325507 |
| Offline full-frame inference | 7.151 ms median, 13.588 ms p95, 14.923 ms maximum over the 18-frame MPS evaluation |
| Export | 1,867,652-byte TorchScript candidate; zero observed mean/maximum difference on the export fixture |
| Provenance | Exact NR4-E authorization, configuration, nine executing tool sources, evaluation/environment/export manifests, initializer, and checkpoint retained by digest |

The first 152,375-parameter `-a` attempt remains diagnostic evidence. It
exposed visible ringing and training oscillation, motivating the measured
capacity increase, annealed learning rate, lowest-loss selection, immutable
configuration snapshot, and complete 18-frame visual evidence in accepted run
`nr5-b-controlled-overfit-20260809-c`.

## NR5-C/D held-out and native-stress measurements

These remain offline PyTorch/MPS experiment measurements, not installed engine
inference or a shipping budget. The canonical result is
`nr5-c-held-out-20260810-b`; the native stress corpus was freshly generated as
`nr5-d-native-stress-corpus-20260810-a`.

| Item | Result |
|---|---|
| Model/cohort | 448,175 parameters; 36 train, 18 validation, 18 sealed-test, and 36 fresh stress frames at direct `160×90 → 400×225` |
| Training | 180 declared epochs; validation selected epoch 175; 349.955 seconds MPS wall time |
| Validation quality | Model linear-HDR MAE 0.010291 vs bilinear 0.468340; median inference 9.106 ms, p95 10.742 ms |
| One-open test quality | Model linear-HDR MAE 0.016277 vs bilinear 0.424593; median inference 8.532 ms, p95 28.867 ms including cold outlier |
| Fresh stress quality | Model linear-HDR MAE 0.011826 vs bilinear 0.502818; semantic boundary 0.034780 vs 0.280980; instance boundary 0.074701 vs 0.336319 |
| Supplemental stress inference | 6.983 ms median, 10.862 ms p95, 125.516 ms maximum; cold MPS compilation outlier retained |
| Checkpoint/export | 5,438,663-byte selected checkpoint; 1,868,420-byte TorchScript candidate; zero mean/maximum disagreement across all 36 stress frames |
| Process memory | 1,027,063,808-byte peak RSS while loading corpus/checkpoint/export and executing full stress inference plus a representative forward/backward step |
| Training memory limitation | Canonical training ended before RSS instrumentation; the actual training-process peak is unknown and is not reconstructed from the supplemental measurement |

The timings exclude engine rasterization, GPU texture ownership, composition,
post/UI, presentation, and fallback transitions. They demonstrate local proof
feasibility only. Visible edge smoothing and chromatic ringing remain quality
limitations regardless of the low aggregate errors.

## NR5-E live Core ML trial measurements

These measurements describe the explicit external trial bundle and current
blocking evaluation path. They are not an installed model, frame-rate target,
or shipping inference design.

| Item | Result |
|---|---|
| Live cohort | 48 Metal frames; six `160×90` engine targets; direct `400×225` model output |
| Correctness | 48 readbacks, 48 predictions, zero inference failures, zero unknown semantic pixels, zero unknown instance pixels |
| Core ML agreement | Float32 MLProgram maximum absolute error `0.00001955`, mean absolute error `0.00000017` against the export wrapper |
| Warm acceptance timing | Last inference `11.281 ms`; staged pipeline mean `33.475 ms`; staged maximum `77.716 ms` |
| Cold behavior | First-use Core ML compilation outlier near `1052 ms` retained from the preceding cold run |
| Presentation | One-frame-delayed output with explicit `N` conventional/neural toggle and automatic conventional fallback |
| Current cost owners | Blocking GPU readback, CPU preprocessing, Core ML inference, CPU display transform, upload, and one-frame staging |

The warm inference is compatible with interactive proof use on the target Mac,
while the staged mean explains the observed roughly 24–27 FPS product run. NR6
must measure temporal quality before optimizing this transport. It must not
erase source/presented-frame lineage or silently replace the fallback contract.
