---
name: godotwebgpu
description: How GodotWebGPU's WebGPU backend actually works — RenderingDeviceDriverWebGPU and RenderingContextDriverWebGPU over emdawnwebgpu/Dawn, the push-constant ring buffer, subpass flattening, the SPIR-V preprocess plus Tint SPIR-V-to-WGSL pipeline, wgsl_precompile.py, the IPC-elimination optimizations, and browser workarounds. Owns the 50 imported fork documents in references/.
when_to_use: Load when porting or debugging anything under drivers/webgpu/, when a WGSL translation or shader compile misbehaves, when reasoning about WebGPU-vs-Vulkan capability gaps (bind group limits, missing push constants, no subpasses, no sync readback), or when you need a fact from the fork's own documentation. Boundary — this is how the backend works; sequencing the port and citing provenance is the port skill, and mainline 4.7.1 internals are the engine skill.
user-invocable: false
---

# GodotWebGPU — the backend hogdot exists to carry

A complete `RenderingDeviceDriver` + `RenderingContextDriver` implementation targeting the browser's
WebGPU API through Emscripten's **emdawnwebgpu** port (Dawn's C API → browser JS API). It lets Godot's
**Mobile** renderer run in a browser instead of the GLES3/WebGL2 Compatibility path, and brings compute
shaders to web. Measured at `webgpu/webgpu-4.6.2`: **17,095 lines across 26 files** in `drivers/webgpu/`.

⚠ **Everything below describes Godot 4.6.2. hogdot targets 4.7.1.** Paths and reasoning carry over; line
numbers, counts and API signatures must be re-derived. `./hogdot/port-surface.sh` is the authority.

## The files (sizes at `webgpu/webgpu-4.6.2`)

| File | Lines | Role |
| --- | ---: | --- |
| `rendering_device_driver_webgpu.cpp` | 8,856 | The driver. Buffers, textures, pipelines, draw, compute, all command encoding. |
| `rendering_device_driver_webgpu.h` | 646 | Driver interface — the file that must match 4.7.1's `RenderingDeviceDriver`. |
| `spirv_preprocess.cpp/.h` | 2,674 | SPIR-V rewriting passes run *before* Tint. |
| `wgsl_precompile.py` | 896 | Build-time SPIR-V→WGSL precompilation. |
| `SCsub` | 738 | Builds the driver, Tint, and the precompile step. |
| `pixel_formats_webgpu.h` | 705 | Godot `DataFormat` → `WGPUTextureFormat` table. |
| `webgpu_objects.h` | 481 | `WGBuffer`/`WGTexture`/`WGShader`… opaque-pointer wrappers. |
| `rendering_context_driver_webgpu.cpp/.h` | ~330 | Device import from a JS-preinitialised `GPUDevice`, surface from `#canvas`, swapchain. |
| `rendering_shader_container_webgpu.cpp/.h` | ~330 | Shader container format (SPIR-V storage + WGSL conversion). |
| `tint_wrapper.cpp/.h` | ~110 | Isolates Tint's C++20 headers from Godot's C++17 build. |
| `tint_cli/` | — | Standalone Tint driver + libFuzzer targets for the preprocess passes. |

## The five design decisions that shape everything

- **Push constants don't exist in WebGPU.** Emulated with a **256 KB read-only storage ring buffer at
  binding 120 in group 3**, 256-byte-aligned slots, dynamic offsets, one bind group reused. Dirty-state
  tracking skips unchanged data. ⚠ Ring *wrap* corrupted data once — see `references/notes/push_constant_ring_buffer.md`
  before touching this.
- **Subpasses don't exist.** Each Godot subpass becomes its own `WGPURenderPassEncoder`, with load/store
  ops derived per pass. This is why `render_forward_mobile.cpp` is in the conflict set.
- **Shader translation is a build-time+runtime pipeline**: GLSL → SPIR-V (glslang, build time) →
  **`spirv_preprocess.cpp` rewrites the SPIR-V** (split combined image-samplers into texture+sampler,
  rewrite push-constant blocks to the binding-120 storage buffer, depth-image flags, position-Y negation,
  point-size stripping) → **Tint** emits WGSL. `wgsl_precompile.py` moves the translation to build time
  using WGSL `override` constants for Godot's specialization constants.
- **Barriers are no-ops.** WebGPU tracks hazards itself; every barrier/sync command returns immediately.
- **Buffer mapping is async, so the driver shadows it.** A CPU-side copy is flushed with
  `wgpuQueueWriteBuffer()` on unmap; reads go through `wgpuBufferMapAsync` + callback. There is **no
  synchronous readback** anywhere. Async lifetimes use a two-flag pattern that makes use-after-free
  impossible even if the owner dies mid-callback.

Also live: **BGL rebinding** — when a shader's expected bind-group layout doesn't match the uniform set's
(specialization variants, merged push-constant layouts), the driver builds *adapted* bind groups on the
fly behind a cache.

## Hard limits you cannot design around

- **4 bind groups max** (WebGPU spec). Godot uses sets 0–3, and **set 3 is shared** between material
  uniforms and the push-constant ring.
- **No 3-component texture formats** — RGB8/RGB16F/RGB32F map to RGBA equivalents.
- **No multi-draw-indirect** (dispatched individually), **no subgroup ops** (`LIMIT_SUBGROUP_IN_SHADERS` = 0).
- **Mobile renderer is auto-selected**: Forward+ needs ≥48 sampled textures per stage, most WebGPU
  implementations report 16. This is *why* CommonGrounds is a Mobile-renderer consumer.
- **Timestamp queries are optional** — gated on the `timestamp-query` feature, with dummy fallback.

## Thread model (proven 2026-08-10, phase 8)

**Game threads are real; rendering is pinned to the browser main thread, permanently.** A `GPUDevice`
is a JS object owned by one realm and a wasm pthread is a Worker with its own realm and object table,
so a `wgpu*()` call from a worker aborts in emdawnwebgpu's `getJsObject()`. No lock fixes it — it is
not a data race. No browser ships cross-realm `GPUDevice` sharing, and emdawnwebgpu has no proxying
layer (Emscripten's own WebGL bindings do; that is why `opengl3=yes` can thread rendering and this
cannot).

⚠ **The engine puts worker threads on the device by itself** — this was the phase's central surprise,
and `research/web-threads-feasibility.md` predicted the opposite ("zero driver changes") because it
audited `drivers/webgpu/` for thread use instead of auditing the engine code that *calls* the driver.
Four sites needed gating behind
`RenderingDeviceDriver::is_multithreaded_resource_creation_supported()` (default `true`, WebGPU
`false`): `ShaderRD::_compile_variant`, `PipelineHashMapRD::compile_pipeline`,
`PipelineDeferredRD::_start`, and `RendererCompositorRD::can_create_resources_async`. Full inventory
and reasoning: **RL-043**; the shipping guide is `.claude/work/plans/THREADS.md`.

⚠ `proxy_to_pthread=yes` and `RENDER_SEPARATE_THREAD` are unsupported and not planned.

⚠ **The fork's own docs were right, and the research doc's claim that they overstate the limitation is
wrong.** `site/CORRECTNESS_AND_COMPATIBILITY.md:289` says *rendering* is main-thread-only and
`site/FAQ.md:195-199` frames `threads=yes` as audio/physics offload needing COOP/COEP — which is
exactly the configuration that now works. Nobody had built the combination; the documents were
accurate.

## Performance — the backend's whole shape is an IPC argument

Every GPU call crosses a WASM→JS→browser-GPU-process IPC boundary at 40–250× native per-call cost, so
Godot's "commands are free" forward-mobile renderer becomes **IPC-bound, not GPU-bound**. The optimization
hierarchy, in order: **eliminate calls** (batching, merging, dedup) → **shrink payloads** → **move work to
build time**. That campaign took web from 3.25× slower than native to roughly parity. Read
`references/site/PERFORMANCE_AND_OPTIMIZATION.md` before any perf work, and never micro-optimize a
call that could be removed.

## Build and selection

```bash
scons platform=web target=template_release dlink_enabled=yes webgpu=yes opengl3=no threads=no
```

⚠ **`threads=yes` works too** and produces a zip *without* the `.nothreads` suffix — the suffix is the
only thing telling the two apart, and naming the wrong one in a preset fails at runtime, not at
export. Both templates are supported; see the thread-model section above.

`webgpu=yes` defines `WEBGPU_ENABLED` and adds `--use-port=emdawnwebgpu` to compile *and* link flags.
Selection is by project setting — `rendering/renderer/rendering_method.web` (`mobile` / `forward_plus` /
`gl_compatibility`) and `rendering/rendering_device/driver.web` = `webgpu`.

⚠ **Emscripten**: `--use-port=emdawnwebgpu` requires **≥4.0.10** and replaced `-sUSE_WEBGPU=1`, which was
removed in 5.0. The fork shipped and benchmarked on **5.0.0**; this machine is on the **6.0.x** line and
it moves — ask `emcc --version`, never a doc (RL-039 is what a stale version assertion cost). Build
config details live in the `build-export` skill, not here.

## Reference material

- [index.md](references/index.md) — **read this before opening any other reference.** Maps all 50 imported
  fork documents with a one-line what/when each, groups them by port slice, and carries the two traps that
  make the raw tree dangerous (the naga→Tint generational split, and 4.6.2-vs-4.7.1 drift).
- [driver-readme.md](references/driver-readme.md) — the fork's own `drivers/webgpu/README.md`, verbatim.
  The densest single page on the backend. ⚠ Its per-file line counts are stale (says ~5,250 for the driver;
  actually 8,856) — trust the table above.
- `references/site/` (5 files) — the polished, **current (Tint-era)** synthesis: architecture, technical
  reference, performance, correctness, FAQ.
- `references/notes/` (44 files) — the working notes, design docs, debugging sessions and measurement logs.
  ⚠ `notes/review_v3/` predates the Tint migration; `index.md` says which file supersedes which.

---
*Source of truth for how the WebGPU backend works — update it in the same change as any `drivers/webgpu/` port.*
