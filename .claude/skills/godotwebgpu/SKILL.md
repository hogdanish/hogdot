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
  ⚠ A Tint internal error (`TINT_ASSERT`/`TINT_ICE`, e.g. a `.gdshader` switch fallthrough) used to
  abort the wasm module and kill the tab. Since RL-053 it is contained: vendored patch 0008 adds a
  global ICE handler and `tint_wrapper.cpp` longjmps back, so it reports as an ordinary translation
  failure and the material falls back. Gate: `?scene=badshader`.
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
- **No `shader-f16`** — `has_feature(SUPPORTS_HALF_FLOAT)` is false unconditionally, so forward-mobile
  runs the FP32 shader group and the export baker skips the FP16 one
  (`ShaderBakerExportPluginPlatformWebGPU::supports_half_float()`; ⚠ the two flip together, and that
  second copy was 40.3 MB of CommonGrounds' baked shaders — **`build-export`**).

## Binding a depth texture (all measured against Dawn in Chrome 151, 2026-08-11)

Four rules, in the order Dawn applies them. Getting any one wrong looks like the others, which is
how WA-18 (`hint_depth_texture` reading zeros engine-wide) survived the whole port. See RL-049.

1. **Aspect first.** A view over a depth/stencil format with `aspect = All` cannot be bound as a
   sampled texture at all — "Multiple aspects (Depth|Stencil) selected" — whatever its sample type.
   ⚠ `texture_create` builds every `default_view` with `All`, and Godot's Mobile depth attachment is
   `D24_UNORM_S8_UINT`, so a depth binding always needs the separate depth-aspect view
   (`_get_sampled_depth_view`).
2. **Leave that view's `format` Undefined**, so Dawn resolves it to the *aspect's* format. Naming
   the texture's own format is an error: "The view format (Depth24PlusStencil8) is not compatible
   with TextureAspect::DepthOnly … (Depth24Plus)".
3. **Sample type: `depth` and `unfilterable-float` both work; `float` never does.** Dawn's rejection
   names the permitted pair verbatim. Verified for depth16unorm, depth24plus, depth24plus-stencil8,
   depth32float and depth32float-stencil8, multisampled and not. ⚠ The blank-fallback shim was never
   the only option.
4. **The real constraint is the sampler.** What cannot be expressed is a depth texture *statically
   paired with a filtering sampler* — a property of the shader, not the binding. So the driver
   declares a binding `unfilterable-float` only when no sampler is paired with it
   (`_wgsl_texture_is_sampled`), and engine shaders that copy depth texel-fetch it instead of
   sampling (`resolve_raster.glsl` `MODE_COPY_DEPTH`, `bokeh_dof_raster.glsl`).

⚠ **`readonly_and_readwrite_storage_textures` is a WGSL *language* feature**, on
`navigator.gpu.wgslLanguageFeatures`, spelled with underscores — never a `GPUFeatureName` and never
on `adapter.features`. And it does not make every storage format read-writable: `read_write` is
confined to **r32float / r32uint / r32sint**, so the read_write split is decided per declaration on
the format. `read` (read-only) has no such restriction. See RL-051.

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

## HDR display output (added 2026-08-10, phase 10)

The canvas can carry values above 1.0, and hogdot drives it. Three facts are load-bearing:

- **Colour management is a CONFIGURATION property, not a creation one.** `WGPUSurfaceColorManagement`
  chains into `WGPUSurfaceConfiguration` and is forwarded to `GPUCanvasConfiguration.toneMapping`.
  ⚠ Chaining it into the *surface descriptor* aborts the runtime: emdawnwebgpu's
  `wgpuInstanceCreateSurface` asserts its chain is exactly the canvas selector. HDR therefore flips
  format and tone mapping together in `swap_chain_resize()` — `RGBA16Float` + `Extended` when
  granted, `BGRA8Unorm` + the canvas default otherwise. Nothing is recreated.
- **Detection takes two questions, not one.** `godot_js_display_hdr_supported()` (navigator.gpu +
  `(dynamic-range: high)` + a context exposing `getConfiguration`) is answerable *before*
  configuring and decides the format; `godot_js_display_hdr_granted()` adds the live tone-mapping
  mode and is answerable only *after*. Both require the media query, because a browser that echoes
  the requested dictionary instead of the granted one would otherwise report HDR on an SDR panel.
- **The colour path does not change.** Web reports `COLOR_SPACE_REC709_NONLINEAR_SRGB` in both
  modes; `blit.glsl`'s `linear_to_srgb` encodes without a clamp and extends past 1.0 through its
  `pow` branch, which is exactly the extended-sRGB an `extended` canvas decodes. Only the range
  widens.

⚠ **Headroom is a guess and always will be** until a web API reports one. `reference 100 / max 200`
gives `output_max_value = 2.0`; only that ratio reaches a shader. macOS EDR headroom is dynamic —
near zero at full SDR brightness — so a bigger assumption puts detail where the compositor clamps it.

⚠ **A driver cannot deliver HDR alone.** The 4.7 docs require an AGX or LINEAR tonemapper (ACES and
FILMIC produce SDR-range output and clamp first), `Viewport.use_hdr_2d` on every viewport, and no
glow SOFTLIGHT or colour adjustment. `request_hdr_output` is read only at startup;
`DisplayServer.window_request_hdr_output()` is the runtime channel. Tell any consumer this.

## Render areas are sub-rects, and the scissor clamp must respect that

⚠ WebGPU has no render-area concept, so the driver emulates Vulkan's with viewport and scissor. A
pass that targets part of a shared texture — **every positional shadow-atlas pass does** — arrives
with a scissor in absolute attachment coordinates. Clamp it against the render area's **right and
bottom edges** (`origin + size`), never its extents. Comparing an absolute coordinate to a width
scissored every off-origin pass to nothing and silently deleted all positional shadows for the
project's entire history (RL-048). An empty scissor raises no validation error.

## Performance — the backend's whole shape is an IPC argument

Every GPU call crosses a WASM→JS→browser-GPU-process IPC boundary at 40–250× native per-call cost, so
Godot's "commands are free" forward-mobile renderer becomes **IPC-bound, not GPU-bound**. The optimization
hierarchy, in order: **eliminate calls** (batching, merging, dedup) → **shrink payloads** → **move work to
build time**. That campaign took web from 3.25× slower than native to roughly parity. Read
`references/site/PERFORMANCE_AND_OPTIMIZATION.md` before any perf work, and never micro-optimize a
call that could be removed.

## Driver telemetry — `window.__cgPerf` (added 2026-08-30)

The driver publishes an **always-on, release-safe** telemetry channel at `window.__cgPerf`, plus a
greppable `[CGPERF]` boot line. Storage and layout: `drivers/webgpu/cgperf_channel.h`; the JS boundary
is `_cgperf_install()` / `_cgperf_publish_build()` in the driver `.cpp`. The 1 Hz `[PERF]` text line is
unchanged and byte-compatible.

```
__cgPerf.version        1
__cgPerf.build          { engine_commit, pipeline_id, threads, adapter{vendor,architecture,device,description} }
__cgPerf.counters       live getter over the heap; 15 monotonic doubles (see the header's Counter enum)
__cgPerf.frames         live getter → { head, cap: 3600, stride: 13, count, buf: Float64Array }
__cgPerf.frames_schema  13 names, fixed order, index == column
__cgPerf.compiles       plain array, cap 512, { t, frame, kind: render|compute|module, label, ms, baked }
__cgPerf.events         plain array, cap 256, { t, frame, type, detail, count, t_last, frame_last }
__cgPerf.ts             live getter → { supported, requested, degraded_frames } — OPT-IN, see below
```
Oldest→newest row `i`, field `f`: `buf[((head - count + i) % cap) * stride + f]`.

Five rules, each of which cost something to learn:

- ⚠ **Never cache a typed-array view over the wasm heap.** `-sALLOW_MEMORY_GROWTH=1` detaches it, and
  the heap grows during world load — exactly when the interesting stalls happen. Both getters
  re-derive from `Module['HEAPF64']` / `Module['HEAPU32']` on every read.
- ⚠ **One clock.** `emscripten_get_now()` is `performance.timeOrigin + performance.now()`, an absolute
  epoch value; every published timestamp is that minus the **window's** `timeOrigin`, captured once
  with `MAIN_THREAD_EM_ASM_DOUBLE`, so it equals the page's `performance.now()` from any thread. The
  one-time install and boot blob are `MAIN_THREAD_EM_ASM` so the object lands on the page's `window`
  and not a worker's global — `proxy_to_pthread` is off by default but is one linker flag away.
- ⚠ **`EM_JS_DEPS` is mandatory** for a JS-library helper used only inside an `EM_ASM` body
  (`UTF8ToString` here). Emscripten does not scan those bodies; miss it and the template links clean
  and dies in the browser.
- ⚠ **clang-format formats `EM_ASM` bodies as C++, and this repo is clang-format green.** A JS object
  literal's `key : value` desynchronises its brace tracking and it reindents the whole file; `!==` is
  not a C++ token and gets rewritten to `!= =`, which silently breaks the JS. Build every object with
  property assignments, use function *declarations* rather than assigned function expressions (the
  semicolon gets stripped), and never write `:` or `!==` in an `EM_ASM` body. ⚠ The pre-existing
  `WEBGPU_VERBOSE` diagnostic block already carries two `== =` from this trap and does not parse.
- ⚠ **`EM_ASM` is a macro** — its body splits on every top-level comma; parentheses protect one,
  brackets and braces do not. Field-name lists cross the boundary newline-joined, once.

Per-frame cost is bounded structurally, not by discipline: the ring is static `.bss` (≈366 KB), and
the only per-frame JS crossings are two-to-three `emscripten_get_now()` imports, one of which replaces
the `EM_ASM_DOUBLE` `begin_segment` already paid. A `static_assert` in the header fails the build if a
name list ever drifts from its enum.

`build.pipeline_id` is the **template's** Tint translation stamp, newly generated for `webgpu=yes`
builds by `drivers/webgpu/SCsub` from the same input list and builder as the editor's copy, so the two
agree by construction. Comparing it against the editor's stamp is what detects a template that
translates differently from the pck it was fed.

### Reading `compiles`, `events` and `fence_lag` (added 2026-08-30, chunk 2)

- ⚠ **A `compiles` record times the `wgpuDevice*Create*` call's RETURN, not the GPU's compile.** Dawn
  defers real backend compilation to first draw — a fully baked project measured ≈0 s of JS-visible
  GPU compile while the stall reappeared at first draw. What the number *is* worth: it is the
  **synchronous render-thread** cost, which is exactly what `pipeline_hash_map_rd.h`'s inline compile
  spends inside the frame. Do not read a 0.3 ms `'render'` record as "pipeline creation is free".
- Five creation sites, all recorded: the main-path and specialization `createShaderModule`, the base
  and Uint16-strip `createRenderPipeline` (a strip primitive genuinely pays two), and
  `createComputePipeline`. `baked` on a pipeline record comes from `WGShader::used_baked_wgsl`; on a
  specialization module it is always `false`, because specialization re-translates from SPIR-V and a
  bake can never serve that path.
- ⚠ **Consecutive identical `events` records coalesce** into `count` / `t_last` / `frame_last` instead
  of pushing. `acquire_fail` and `resize_skip` can fire every frame of a bad run, and 256 identical
  records would evict every other event in the session — destroying the context that makes the run
  diagnosable. The `counters` carry the true totals regardless. Every event site also keeps its
  original `WARN_PRINT_ONCE` / `ERR_PRINT_ONCE` / `console.error`: those are the only signal a session
  without the in-page harness gets.
- **`fence_lag` is signed, and the sign is the whole point.** `fence_wait()` force-signals a fence the
  GPU has not reported on, to avoid deadlocking the single-threaded browser main loop — so the driver
  reports completions it never observed and the CPU can run arbitrarily far ahead. Positive = a real
  `signal - submit` measurement from the work-done callback. Negative = the callback had not fired,
  and the magnitude is how far past the submit the CPU had already run. Zero = no fence waited that
  frame. ⚠ The force-signal itself is deliberately **unchanged** — measuring it is in scope, fixing it
  is not. ⚠ `WGFence::signal_time_ms` is stamped **before** the `freed` check in
  `_fence_work_done_callback`, which deletes the fence and returns.

### GPU timestamp queries — opt-in, and how to judge the numbers (added 2026-08-30, chunk 3)

Timestamp readback is **off by default and always will be until `degraded_frames` says otherwise.**
Turn it on for one session with **`?cgperf_ts`** in the URL (no re-export needed — that is the whole
point of the flag), or with the project setting **`rendering/rendering_device/webgpu_timestamps`**.
⚠ That setting is registered from the web-only driver, so **it never appears in the editor's Project
Settings dialog** — write the line into `project.godot` by hand.

- **Why it was off.** The imported driver hard-disabled it: a stuck `mapAsync` on the readback buffer
  produces `buffer used in submit while mapped` validation errors that corrupt rendering. ⚠ Reading
  the code says the hazard is **already defended three times over**, all landed in the same import
  commit (`813189e2c4`): `command_buffer_end` drains → unmaps → drains → re-checks and **skips the
  resolve entirely** on a still-stuck buffer, so the copy is never encoded;
  `command_queue_execute_and_present` never issues a second `mapAsync` while one is outstanding; and
  `_timestamp_readback_callback` discards stale callbacks by generation. **That is a reading, not a
  result** — none of it has ever been exercised, which is why the flip is opt-in rather than default.
- ⚠ **`__cgPerf.ts.degraded_frames` is the number that decides whether a GPU timing is real.** It
  counts every resolve the skip path threw away. While it climbs, rendering stays correct and the
  timings quietly stop advancing — the failure mode is *stale numbers*, not an error. A nonzero value
  means the run's GPU times are incomplete and a consumer must say so. A stuck buffer also costs one
  extra `wgpuInstanceProcessEvents` per pool per frame for the rest of the session; that is the one
  real cost of the flip, and the counter is how it gets caught.
- The skip path now also emits a `WARN_PRINT_ONCE`. It was previously silent in every tier.
- `ts` is a **live getter** over the heap for the same reason `counters` is: `degraded_frames` is
  bumped by a plain `double` store from C++ on a path that can run every frame, so an `EM_ASM` there
  would put a JS crossing on the per-frame path in exactly the state where the driver is struggling.

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
