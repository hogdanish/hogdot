# GodotWebGPU document index

Every `.md` GodotWebGPU carried, imported verbatim from `webgpu/webgpu-4.6.2` (2026-08-06) — 50 files,
1.2 MB. **Nothing here has been edited**, so it is all evidence and none of it is law. Read one file,
not the tree; `rg` across `notes/`+`site/` when you don't know which.

## ⚠ Read this before trusting any file

**1. Two generations exist, and the older one is wrong about the whole shader pipeline.** The project
replaced **naga** (Rust/WASM, `naga_wasm_bg.wasm`, shipped as a prebuilt binary) with **Tint** (Google's
Dawn compiler, linked in as C++) on **2026-05-11**. Rust was removed from the build entirely.

| Topic | Current (Tint) | Superseded (naga) |
| --- | --- | --- |
| Architecture | `site/ARCHITECTURE_AND_DESIGN.md` | `notes/review_v3/FINAL_1_ARCHITECTURE_AND_DESIGN.md` |
| Technical reference | `site/TECHNICAL_REFERENCE.md` | `notes/review_v3/FINAL_2_TECHNICAL_REFERENCE.md` |
| Correctness | `site/CORRECTNESS_AND_COMPATIBILITY.md` | `notes/review_v3/FINAL_4_CORRECTNESS_AND_COMPATIBILITY.md` |
| FAQ | `site/FAQ.md` | `notes/review_v3/FINAL_FAQ.md` |
| Performance | `site/PERFORMANCE_AND_OPTIMIZATION.md` | `notes/review_v3/FINAL_3_PERFORMANCE_AND_OPTIMIZATION.md` (near-identical — this pair barely mentions the translator, so either is safe) |

Measured: `FINAL_1` mentions naga 23×/Tint 0×; `site/ARCHITECTURE_AND_DESIGN.md` mentions Tint 18×/naga 1×.
**Default to `site/`.** Reach for a `FINAL_*` or a `review_v3/0*` only to understand *why* something was
built the way it was — never for what the code does now.

⚠ `notes/review_v3/02_shader_pipeline.md` (naga 54×) documents a pipeline **that no longer exists**. The
live one is `site/TECHNICAL_REFERENCE.md` §4 plus `notes/naga_to_tint.md`.

**2. It describes Godot 4.6.2, hogdot targets 4.7.1.** Every line number, every "42 files changed", every
`RenderingDeviceDriver` signature is 4.6.2-era. Treat file *paths* and *reasoning* as reliable, and every
*number* and *signature* as needing re-derivation against 4.7.1. `./hogdot/port-surface.sh` is the
authority on what actually differs.

**3. `webgpu_notes/stubs/` was deliberately not imported** — 145 KB of early scaffold headers
(`rendering_device_driver_webgpu.h`, `pixel_formats_webgpu.h`, …) that the real `drivers/webgpu/`
superseded. Stale API signatures sitting next to a live port are a hazard, not a resource. If you ever
want them: `git show webgpu/webgpu-4.6.2:webgpu_notes/stubs/<file>`.

## Start here

| File | What / when |
| --- | --- |
| [driver-readme.md](driver-readme.md) | The driver's own README (`drivers/webgpu/README.md`). The densest single page: architecture diagram, per-file line counts, every key design decision, known limitations, build commands, project settings. **Read this first, always.** |
| [site/FAQ.md](site/FAQ.md) | Q&A over the whole backend — why Mobile and not Forward+, browser support, what compute does. Best orientation when you don't yet know what to ask. |
| [site/ARCHITECTURE_AND_DESIGN.md](site/ARCHITECTURE_AND_DESIGN.md) | The layered architecture, the 4 big design decisions and their rationale, comparison to the Vulkan/Metal drivers, upstream-acceptance analysis. |
| [site/TECHNICAL_REFERENCE.md](site/TECHNICAL_REFERENCE.md) | Method-level reference for all 10 seams — object model, command recording, bind groups, shader pipeline, textures, surface, RD integration, build, platform/web, browser quirks. The lookup table while porting. |

## By seam — matched to the port slices

**RD core / driver** — `drivers/webgpu/`, `rendering_device*.{cpp,h}`
- `notes/review_v3/01_driver_core.md` — object lifecycle, command encoding, bind groups, swapchain, per-method concerns. Naga-era only in §6.
- `notes/DESIGN.md` — method-by-method mapping for *every* `RenderingDeviceDriverWebGPU` / `RenderingContextDriverWebGPU` entry point, with "→ no-op" / "→ stub" conventions. The porting lookup table.
- `notes/review_v3/03_renderer_integration.md` — every `servers/rendering/` change: driver-trait modifications, RD core edits, format negotiation, skeleton atlas, canvas uniform layout. **Maps directly onto the RD-core and storage_rd conflict slices.**
- `notes/push_constant_ring_buffer.md` — the 256 KB ring emulating push constants (binding 120, group 3), the wrap-corruption bug and its fix. Read before touching push-constant code.

**Shader pipeline** — SPIR-V → WGSL
- `notes/naga_to_tint.md` — the migration of record: motivation, before/after architecture, dependencies, SCsub details, the 6 Tint patches. **The authoritative account of today's pipeline.**
- `notes/naga_to_tint_debugging.md` — 8 concrete translation bugs (struct alignment, combined-sampler double-splitting, OpFunctionCall type mismatches, device-lost on macOS Vulkan) each with root cause and fix. The first place to look when a shader miscompiles.
- `notes/precompile_specialized_to_wgsl.md` — build-time WGSL precompilation via WGSL `override` constants; what Godot specialization constants really are. Backs `wgsl_precompile.py`.
- `notes/precompile_naga_spirv_to_wgsl.md` — the earlier build-time precompilation pass that removed ~4.7 s of main-thread translation. Naga-era mechanism, still-valid motivation.
- `notes/finish_async_shader_comp.md` — async pipeline compilation, the callback-delivery bug, and why pipelines cannot move to a web worker.
- `notes/remove_rust.md` — why Rust had to go for upstreamability, and the Tint-vs-naga evaluation. Context, not mechanism.
- `notes/naga_to_tint_commit_message.md` — a 1 KB commit-message draft. Useful only as prose for a port commit.

**Performance** — the reason the backend is shaped the way it is
- `site/PERFORMANCE_AND_OPTIMIZATION.md` — the synthesis: IPC is the bottleneck, the optimization hierarchy, and the layered journey from 3.25× slower to parity. **Read before any perf work.**
- `notes/IPC_OPTIMIZATION_SUMMARY.md` — the polished narrative of the per-draw IPC eliminations (firstInstance dedup, instance batching, shadow-pass merging).
- `notes/COMMAND_STREAM_RECORDER_PERF_OPTIM.md` — 58 KB design for recording commands into WASM linear memory and replaying in one JS call. Largely forward-looking; read only when attacking the trampoline.
- `notes/COMMAND_BUFFERING_WASM_TO_JS.md` — the shipped subset of the above, with May-2026 results.
- `notes/perf_optimization_may3_2026.md` — 74 KB raw measurement log (M3 Ultra), baselines, isolation tests, prioritized candidates. A data dump; `rg` it, don't read it.
- `notes/review_v3/04_performance.md` — staging-buffer architecture, batching, how the optimizations compound, correctness risks each one introduces.
- `notes/STARTUP_PROFILING.md` — where 38 s of cold start went, shader-compile and pipeline-creation breakdowns.
- `notes/BUFFER_UNMAP_32MB_FLUSH_ROOT_CAUSE.md` — every `buffer_unmap()` flushed the whole 32 MB staging buffer. Short, self-contained, and a model for this kind of hunt.
- `notes/batched_images_to_vram.md` — `command_copy_buffer_to_texture_layered` and the direct `writeTexture` path for `Texture2DArray`.
- `notes/SLOW_WINDOW_OR_TEXTURE_CREATION.md` — `Window.new()` costing ~9–10 ms; unresolved, root cause still open.

**Platform / web / build**
- `notes/review_v3/05_platform_web.md` — JS↔WASM init flow, async safety, memory-safety patterns, the no-threads model, cross-origin isolation. Backs the `platform/web` conflict slice.
- `notes/review_v3/06_build_system.md` — SCons integration, template packaging, the full build command, minimum-Emscripten logic. ⚠ Its §2 covers Rust/Cargo, which no longer exists.
- `notes/BUILD_BLOCKERS.md` — the 10 exact edits that make `scons platform=web webgpu=yes` compile, file by file. **The closest thing to a port checklist for the build slice** — but written against 4.6.
- `notes/ASYNC_WEBGPU.md` — synchronous readback on single-threaded WASM; why ASYNCIFY was evaluated and abandoned. Also the best `emdawnwebgpu` source-location reference.

**Correctness & compatibility**
- `site/CORRECTNESS_AND_COMPATIBILITY.md` — resource-lifecycle guarantees, the two-flag async pattern that makes use-after-free impossible, per-browser workarounds, accepted limitations.
- `notes/review_v3/07_correctness.md` — the audit behind it, including "patterns that suggest unfixed issues".
- `notes/FIX_CONSOLE_ERRORS.md` / `notes/FIX_2D_PLATFORMER.md` / `notes/FIX_PHASE7.md` — three worked debugging sessions (startup GPU errors; a camera-not-following root cause; a phased re-application plan). Value is the *method*, and they name real files.

## Historical — provenance only, never current

`notes/INITIAL_PLAN.md` (the original 2-week brief) · `notes/RESEARCH.md` (901-line pre-implementation
research: Godot rendering architecture, the `RenderingDeviceDriver` interface, WebGPU-vs-Vulkan
differences, prior art — excellent background, 4.6-era) · `notes/TASKS.md` (109 KB master task list,
phases 0–6; the record of *what was built in what order*) · `notes/IMPLEMENTATION.md` (March-2026 summary,
pre-Tint) · `notes/PR_DESCRIPTION.md` (the upstream PR draft) · `notes/review_v3/PLAN.md` (how the review
itself was run) · `notes/review_v3/FINAL_5_LAUNCH_TODO.md` (pre-release punch list; several items may still
be open) · `notes/review_v3/08_architecture.md` (superseded by `site/ARCHITECTURE_AND_DESIGN.md`) ·
`notes/benchmark_vs_threejs.md`, `notes/native_vs_web_benchmarks.md`, `notes/manualy_run_benchmark_scenes.md`
(raw benchmark logs; the last records a build on **Emscripten 5.0.0**).

## Chronology (anchors "current" for any undated claim)

`2026-03-10` project brief, RESEARCH/DESIGN/TASKS → `03-13` first implementation summary →
`04-12` ASYNCIFY abandoned → `05-03` perf campaign → `05-04` command buffering ships →
`05-06/07` startup profiling, build-time WGSL precompilation → `05-09` target release →
`05-10` push-constant ring fixed → **`05-11` naga → Tint, Rust removed** → `05-12` TASKS.md final update.
`review_v3/` predates 05-11; `site/` postdates it.
