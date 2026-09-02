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
  ⚠ **`freeze_spec_constant_ops` is CONDITIONAL as of 2026-08-30** — the runtime-overrides
  prototype. Default OFF, so every runtime translation freezes exactly as it always has. Turn it on
  per session with **`?webgpu_overrides`** in the URL or the project setting
  **`rendering/rendering_device/webgpu_runtime_overrides`** (web-only driver ⇒ never in the editor's
  Project Settings dialog; write the line into `project.godot` by hand). With it on the freeze is
  skipped, Tint emits `@id(N) override`, `has_override_declarations` goes true for
  runtime-translated shaders, and `_create_module_with_spec_constants`'s per-variant-per-stage
  fan-out — **58% of every shader module the driver creates** — stops existing for them.
  ⚠ **"Does Tint accept live spec constants" was never an open question**: `tint_convert_cli
  --overrides` has skipped this one pass and run the identical remaining twelve passes and the
  identical `tint_wrapper_spirv_to_wgsl` since the WGSL bake shipped, so every WGSL blob in a baked
  pck is the evidence. What is unproven is the *runtime* taking that path for shaders the baker
  never saw — hence the flag.
  ⚠ **The mode is part of the `_spv_to_wgsl_cached` key** (a fixed XOR salt). The same SPIR-V
  translates to two different WGSL texts under the two modes; a shared key would serve whichever
  ran first to whoever asked second, silently. An overrides translation that fails **retries
  frozen** and caches the result under the overrides key, bumping
  `counters.override_translate_fallback` — nonzero means the flag did not take for that many
  shaders and each reverted to the fan-out, which is the first number to read when an A/B win looks
  small.
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
fly behind a cache (`_get_compatible_bind_group`).

⚠ **Three lifetime rules hold that path together** (fixed 2026-08-30; all three were live defects,
and together they are the best explanation for the 3310 validation errors and ~1655 consecutive
frames whose `Queue.Submit` was rejected in the `20260830-151615` cold-r2 artifact):

1. **A uniform set's `source_shader` is a weak back-reference and must never be dereferenced
   directly.** `shader_free` deletes the `WGShader` and clears nothing, and `new` may hand the same
   address to a different shader — so a raw pointer compare is an ABA test, not an identity test.
   `WGShader::generation` plus the driver's `live_shader_generations` map make it decidable;
   `_resolve_source_shader()` is the only legal reader and nulls the field when it is stale. A
   `shader_free_epoch` compare keeps the common case a single integer test, because that path runs
   thousands of times per frame.
2. **`rebind_cache`'s KEY holds a reference.** `wgpuBindGroupLayoutAddRef` on insert,
   `wgpuBindGroupLayoutRelease` in `uniform_set_free`. The layouts belong to a *target* shader that
   can be freed while the uniform set lives on; without the retain the address is recycled and a
   later lookup returns a bind group built for a dead layout.
3. **A failed rebind is never cached and never falls back to `p_us->handle`.** `p_us->handle` was
   built with the *source* layout; binding it against a pipeline expecting the target layout is
   precisely the "bind group layout … does not match" error, and caching the failure made every
   later frame repeat it forever. The function returns `nullptr` and both call sites SKIP the set —
   locally wrong instead of contagiously wrong. ⚠ The dynamic-offset unpack must still run for a
   skipped set or every later set in the same call reads the wrong 4-bit slot of the mask.

⚠ **You cannot detect a failed `wgpuDeviceCreateBindGroup` after the fact.** emdawnwebgpu allocates
the wrapper and only then calls `device.createBindGroup()` (`library_webgpu.js`), so it returns
non-null unconditionally; and WebGPU's *contagious invalidity* means a validation failure yields a
live-looking but internally invalid object. Error scopes do not help either — `popErrorScope`
resolves through a JS promise, which cannot run while wasm holds the stack, **and** pushing a scope
would capture the very validation error `counters.uncaptured_error` is the gate for, turning a
regression into a silent pass. So the failure is detected **before** the create, structurally: WebGPU
requires a bind group's entries to correspond exactly to its layout's, so a uniform set that does not
supply every binding the target layout declares cannot produce a valid bind group. That check is
synchronous and cannot false-positive — it only fires where the create was already going to fail.
`counters.bindgroup_rebind_fail` and the `bindgroup_rebind_fail` event (set index, both shader
names, coverage) are the record; **any nonzero value means some geometry drew with a stale binding.**

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
⚠ **`thread_model = Multi-Threaded` is CLAMPED, not fatal, since 2026-09-01.** Mainline's only guard
is `#if !defined(THREADS_ENABLED)`, which the threaded template does not trip — so that setting used
to spawn a render thread that aborted in `getJsObject()` on its first frame, in the browser, with
nothing in the engine's logs naming the setting. `main/main.cpp` now forces
`separate_thread_render = 0` under `WEB_ENABLED` with one `WARN_PRINT`. Still unsupported; now
unsupported survivably.

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
  granted, the browser's preferred canvas format + the canvas default otherwise. Nothing is
  recreated.
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

### WGSL-only shader containers (opt-in, added 2026-09-01)

`rendering/rendering_device/webgpu_wgsl_only_containers` (default **false**) makes the shader baker
drop every stage's SPIR-V payload from a container whose WGSL bake succeeded, and set
`FLAG_WGSL_ONLY` (bit 1) beside `FLAG_HAS_BAKED_WGSL`. Roughly half the baked bytes in a pack.

- **Why it is safe:** the only consumer of `WGShader::stage_spirv` is
  `_create_module_with_spec_constants`, and a baked shader never reaches it — the baker translates
  with `tint_convert_cli --overrides`, so the WGSL carries `@id(N) override` declarations,
  `has_override_declarations` is true, and specialization becomes `WGPUConstantEntry` values at
  pipeline creation. All three call sites are also guarded by `is_empty()`.
- ⚠ **It removes the fallback.** A stage whose baked WGSL fails to decompress at runtime has
  nothing left to translate from and the shader **fails to create**, where an ordinary baked
  container would have degraded to live Tint. `FLAG_WGSL_ONLY` exists so the driver's error says
  that rather than "empty SPIR-V for shader stage".
- ⚠ **The bake state is part of the export cache key** (`wgsl-<pipeline id>-wgslonly`). The export
  platform caches customized resources by a per-plugin hash and never re-validates them, so a shared
  key would serve a SPIR-V-carrying container to a WGSL-only export, or the reverse, forever and
  silently — the same shape as the 2026-09-01 stale-container defect.
- The setting is honored only when WGSL baking is actually available; with a missing or stale
  `tint_convert_cli` it warns and keeps the SPIR-V, because a container with neither is empty.
- ⚠ Registered from the **editor** side (the export plugin), so unlike the `webgpu_*` runtime
  settings it does appear where a project can set it — but it still only matters at bake time.
- `HeaderData` is unchanged in size: `flags` was already a `uint32_t`. ⚠ It must stay exactly this
  size, because `from_bytes()` parses the header extra block before it validates `format_version`.

### The SDR canvas format is the browser's, not a constant (added 2026-09-01)

`_swap_chain_pick_format()` returns `navigator.gpu.getPreferredCanvasFormat()` for the SDR case
instead of the `BGRA8Unorm` it hardcoded since the port began. The HDR branch is unchanged.

- The glue is **`godot_js_display_preferred_canvas_format()`** in `library_godot_display.js` (0 =
  bgra8unorm, 1 = rgba8unorm; 0 on any error, which is the old behavior), declared in
  `platform/web/godot_js.h` beside the two HDR probes it mirrors. The driver resolves it once into a
  file-scope static — the answer is a property of the platform, not of a canvas or a device.
- ⚠ **Getting it wrong is invisible.** The browser accepts either format and silently converts every
  presented frame to the one the compositor wants; nothing logs, and the cost is a full-screen blit
  per frame. This is what the API exists to prevent.
- ⚠ **Measured 2026-09-01: Chrome on Apple silicon answers `bgra8unorm`,** so on the machine every
  number in this repo is taken on, the change is a no-op. It is `rgba8unorm` platforms (Android, some
  Linux/Vulkan-backed Chrome) that were paying the conversion. Do not expect a local A/B to move.
- The chosen format is on the boot line as `canvas_fmt=`, and the *configured* format (which HDR can
  still promote) stays on the `reconfigure` event's `fmt=`/`hdr=` fields.
- ⚠ Any format added here needs a `_wgpu_to_data_format()` case, or the swap chain's render-pass
  attachment becomes `DATA_FORMAT_MAX` and every pipeline built against it is rejected for a colour
  mask mismatch.

## Render areas are sub-rects, and the scissor clamp must respect that

⚠ WebGPU has no render-area concept, so the driver emulates Vulkan's with viewport and scissor. A
pass that targets part of a shared texture — **every positional shadow-atlas pass does** — arrives
with a scissor in absolute attachment coordinates. Clamp it against the render area's **right and
bottom edges** (`origin + size`), never its extents. Comparing an absolute coordinate to a width
scissored every off-origin pass to nothing and silently deleted all positional shadows for the
project's entire history (RL-048). An empty scissor raises no validation error.

## Performance — measured 2026-09-01, and the IPC story is only half of it

Every GPU call crosses a WASM→JS→browser-GPU-process boundary, so the fork's campaign (batching,
merging, dedup; `references/site/PERFORMANCE_AND_OPTIMIZATION.md`) was right to count calls. But the
2026-09-01 session's bed (`webgpu_tests/perf/`, CommonGrounds-shaped scenes, real Chrome, rAF busy
time + a per-frame WebGPU API census) found the frame was dominated by **two defects that count as
one call each**, present in GodotWebGPU 4.6.2 and hogdot alike:

| defect | per frame (40 SubViewport puppets) | fix |
| --- | --- | --- |
| dynamic-persistent buffers (`MultiUmaBuffer`: canvas + mobile instance data) flushed as a whole 2 MB slice per update | 169 `writeBuffer` calls, **163 MB**, 48 % of CPU samples | range-aware `RDD::buffer_flush(id, offset, size)`; callers pass what they wrote; the canvas flushes only its own instances (`instance_data_flush_from`) — the slice base is derived from `frame_idx` on every call |
| "proactive encoder isolation" (5f5efee119): finish + `queue.submit` + new encoder before every render pass whose attachment is TextureBinding\|RenderAttachment, i.e. every render target | **65 submits** | off by default; `rendering/rendering_device/webgpu_encoder_isolation=true` or `?webgpu_encoder_isolation` restores it (it only ever preserved earlier passes when a validation error invalidated a command buffer) |

Result on the M5: `world` 55.9 fps / **15.0 ms** busy → 118.5 fps (vsync cap) / **1.5 ms**; 81 puppets
31 → 120 fps. Per-draw cost after the fix is ~1.2 µs (draw + setBindGroup), linear to 4096 draws.
Material sets with dynamic offsets are no longer rebound when unchanged. ⚠ **Every driver change gets
a screenshot A/B** (`bench.mjs --screenshot`, `hold`): the first flush patch made 39 of 40 puppets
vanish while the fps "improved". The ledger is `webgpu_tests/perf/HANDOFF.md`.

### Bind groups are content-addressed and shared (added 2026-09-01)

`uniform_set_create` no longer creates a `WGPUBindGroup` unconditionally. The finished
`(layout, entries)` pair is hashed (murmur3 over the raw bytes) and resolved in
`bind_group_content_cache`; an identical live pair hands back the existing group with a fresh
reference. A WebGPU bind group is immutable, so two built from the same layout and entry list are
indistinguishable to everything downstream.

- ⚠ **The slot retains everything it keys on** — the layout and every entry's buffer, sampler and
  texture view. Handles are addresses, and an address released to zero references can be recycled by
  emdawnwebgpu's object table; without the retain the byte compare would be an ABA test, which is
  RL-052's rebind-cache failure one level down.
- ⚠ **Entries compare in ORDER.** WebGPU treats them as a set, so a differently-ordered equivalent
  list misses. That costs a creation, never a wrong group.
- **Refcounting:** the slot holds one reference plus one per sharer, so a shared group outlives
  whichever uniform set is freed first and dies with the last. `uniform_set_free` releases
  `us->handle` and then the slot, unconditionally.
- **`counters.bindgroups_created` still counts real creations only**, which is what makes the win
  readable; the hits are `counters.bindgroups_shared`. ⚠ Read the two together — `created + shared`
  is the number of uniform sets built, and only the ratio distinguishes "the cache worked" from "the
  game built fewer sets".
- Everything else on `WGUniformSet` stays per-set: `cached_entries`, `bound_textures`,
  `dynamic_buffers`, `source_shader` and the `rebind_cache`. The rebind path
  (`_get_compatible_bind_group`) is untouched, including its deliberately-uncached failure branch.
- ⚠ Sets that build their own texture views (`temp_views`, the `rw_storage` shadow views) get a
  unique address per set and therefore never share. That is a miss, not a bug.
- ⚠ `set_object_name` on a shared group is last-writer-wins. Labels are diagnostic; do not read one
  as proof of which uniform set is bound.

### Encoder-owned redundant state (added 2026-09-01)

Three per-draw calls were unconditional and are now cached on `WGCommandBuffer::RenderState`:

| call | why it was unconditional | the cache |
| --- | --- | --- |
| `setPipeline` for the Uint16 strip variant | `command_render_draw_indexed(_indirect)` re-selected `render_handle` vs `render_handle_u16` on **every** indexed draw of a strip mesh, because the index format can change after the pipeline bind | `last_set_pipeline` holds the HANDLE, so the wrapper-identity check in `command_bind_render_pipeline` cannot answer it |
| `setViewport` | the engine re-issues the same rect per draw list | `last_viewport` (the requested values) |
| `setScissorRect` | same, plus the render-area clamp | `last_scissor` (the values **after** the clamp) |

⚠ **All three are per-ENCODER and must be dropped whenever a new `WGPURenderPassEncoder` begins**
— `reset_encoder_redundancy()`, called at both `BeginRenderPass` sites and at the push-constant-ring
mid-pass restart. A fresh encoder starts with the default full-attachment viewport and scissor and
no pipeline, and **the restart path deliberately restores neither the viewport nor the scissor**, so
a cache surviving that boundary would skip the very call that re-establishes them and draw the rest
of the pass at the attachment's extents. The restart also rebinds the **base** pipeline handle, and
records exactly that, so the next strip draw re-selects its variant.


Pipelines: on web `PipelineHashMapRD` compiles inline (RL-043), so the first draw of a new mobile
variant waited ~130 ms for Dawn's GPU-process compile while the main thread was idle (rAF busy < 1 ms).
`RDD::pipeline_creation_set_deferred` + `pipeline_is_ready` let non-blocking requests use
`wgpuDeviceCreateRenderPipelineAsync` while the ubershader draws; the completion is
`AllowSpontaneous` and only stores handles (the fork's parked attempt lost fps to per-draw polling and
Tint-worker plumbing, `references/notes/finish_async_shader_comp.md` — none of that is here).

## Driver telemetry — `window.__cgPerf` (added 2026-08-30)

The driver publishes an **always-on, release-safe** telemetry channel at `window.__cgPerf`, plus a
greppable `[CGPERF]` boot line. Storage and layout: `drivers/webgpu/cgperf_channel.h`; the JS boundary
is `_cgperf_install()` / `_cgperf_publish_build()` in the driver `.cpp`. The 1 Hz `[PERF]` text line is
unchanged and byte-compatible.

```
__cgPerf.version        1
__cgPerf.build          { engine_commit, pipeline_id, threads, adapter{vendor,architecture,device,description} }
__cgPerf.counters       live getter over the heap; 20 monotonic doubles (see the header's Counter enum)
__cgPerf.frames         live getter → { head, cap: 3600, stride: 13, count, buf: Float64Array }
__cgPerf.frames_schema  13 names, fixed order, index == column
__cgPerf.compiles       plain array, cap 512, { t, frame, kind: render|compute|module, label, ms, translate_ms, baked }
__cgPerf.events         plain array, cap 256, { t, frame, type, detail, count, t_last, frame_last }
__cgPerf.ts             live getter → { supported, requested, degraded_frames } — OPT-IN, see below
```
Oldest→newest row `i`, field `f`: `buf[((head - count + i) % cap) * stride + f]`.

⚠ **`frames_schema` slots 2..6 are driver-local creation counts** (render pipelines, compute
pipelines, shader modules, bind-group layouts, bind groups) — **not** the engine's five
`RENDERING_INFO_PIPELINE_COMPILATIONS_*` deltas, which the driver cannot see (deviation D-3, and the
channel says so out loud in `frames_schema_note`). A consumer that wants both merges its own
engine-side ring by `frame_idx`: on web one engine iteration is one `begin_segment` is one rAF, so
the two rings are at identical granularity by construction.

**Consumer protocol** — CommonGrounds' `perf` skill, `references/hogdot-tooling.md`, owns how the
game repo reads this channel; do not restate it here.

### The two release-visible console lines (D-1, D-7)

```
[CGPERF] build engine=<sha12> pipeline_id=<stamp> baked=0/0 threads=<0|1> adapter=<vendor>/<device|architecture> canvas_fmt=<bgra8unorm|rgba8unorm>
[CGPERF] baked=<hit>/<hit+miss> spv_wgsl=<hit>/<hit+miss> engine=<sha12> rd_miss=<n>
```

- The **first** goes out at driver init, before the first frame, so a build-currency assertion can
  key on `[CGPERF] build engine=` immediately and a device lost during boot still leaves provenance
  behind. Its `baked=0/0` is structural, not a measurement — no shader has loaded yet.
- The **second** is emitted once, ~3 s after the first `begin_segment`, and is the only line
  carrying a true baked ratio. Same `[CGPERF] ` prefix on purpose, so one grep finds both.
  ⚠ Its `rd_miss=` field is **not** redundant with `baked=` (added 2026-09-01). `baked_wgsl_miss`
  counts containers that reached the driver without WGSL; `shader_rd_miss` counts `ShaderRD`
  versions that found no container in either cache, which the driver structurally cannot see —
  a container that never reaches it cannot be counted by it. Measured: a live boot printed a
  `Shader cache miss for …` line and still reported `baked=335/335`. A nonzero `rd_miss` beside a
  full `baked=` ratio means the bake is complete for what was baked and something was never baked.
  ⚠ It is bumped on the miss itself, not inside the `is_print_verbose_enabled()` branch that
  reports it, so it counts in a release run — the only kind the bench measures.
  ⚠ It is the **one** counter fed from outside `drivers/webgpu/`, through
  `cgperf_external_count()` (declared in `cgperf_channel.h`, defined beside the channel instance,
  called from `servers/rendering/renderer_rd/shader_rd.cpp`). Keep that list short: anything the
  driver can observe belongs on the driver side, where it costs no coupling.
- ⚠ **The adapter's second field falls back to `architecture`.** Chrome leaves
  `GPUAdapterInfo.device` and `.description` empty for fingerprinting reasons on every platform
  measured (2026-08-30: `apple/metal-3` reports vendor and architecture, the other two `""`), so the
  literal `<vendor>/<device>` printed `apple/unknown` on the one line meant to identify the machine
  a report came from. All four fields stay on `__cgPerf.build.adapter` verbatim.

Six rules, each of which cost something to learn:

- ⚠ **Never cache a typed-array view over the wasm heap.** `-sALLOW_MEMORY_GROWTH=1` detaches it, and
  the heap grows during world load — exactly when the interesting stalls happen. Both getters
  re-derive from `Module['HEAPF64']` / `Module['HEAPU32']` on every read.
- ⚠ **One clock, and the offset is MEASURED, never assumed.** `emscripten_get_now()` has two
  definitions in one toolchain and the build picks one silently — verified in the generated JS of
  both templates built from this tree (emcc 6.0.8-git, 2026-08-30):

  | build | `_emscripten_get_now` |
  | --- | --- |
  | `threads=yes` | `() => performance.timeOrigin + performance.now()` |
  | `threads=no` | `() => performance.now()` |

  So the install brackets a `MAIN_THREAD_EM_ASM_DOUBLE` read of `performance.now()` between two
  `emscripten_get_now()` reads and stores the midpoint difference as `time_origin_ms`. That is
  correct under both definitions and on a worker, whose own performance origin differs from the
  window's (`proxy_to_pthread` is off by default but is one linker flag away). The one-time install
  and boot blob are `MAIN_THREAD_EM_ASM` so the object lands on the page's `window`, not a worker's
  global.
  ⚠ **This was shipped wrong and the failure was total and silent** (found 2026-08-30 by running the
  gate, not by reading it): hard-coding the `threads=yes` form made every timestamp on a nothreads
  template ≈ `-1.79e12`, and `begin_segment`'s `if (cgperf_prev_begin_ms > 0.0)` guard then never
  fired, so the frame ring — the centrepiece — stayed empty for the entire session with no error
  anywhere. Hence the second rule below.
- ⚠ **Never gate state on the sign of a clock reading.** `cgperf_have_prev_begin`,
  `cgperf_have_first_begin` and `WGFence::submit_stamped` are explicit flags for exactly this reason:
  a `> 0.0` test conflates "not yet stamped" with "stamped on a clock whose zero is not page load",
  and the second case disables the instrument rather than reporting anything.
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

Per-frame cost is bounded structurally, not by discipline: the ring is static `.bss` (≈366 KB, so it
costs no file bytes), and the only per-frame JS crossings are two-to-three `emscripten_get_now()`
imports, one of which replaces the `EM_ASM_DOUBLE` `begin_segment` already paid. A `static_assert` in
the header fails the build if a name list ever drifts from its enum.

**Verified end-to-end 2026-08-30** against freshly built templates on a real GPU (`apple/metal-3`),
not by reading: the ring recorded 403/403 frames on **both** the nothreads and the threads template,
and `compiles[].t` (2960 ms) agreed with `events[].t` (2948 ms) on the page's own `performance.now()`
timeline. Sample ring stats from that run, for calibration: `cpu_frame_ms` p50 8.37 / p95 16.03,
`submit_ms` p50 0.025 / p95 0.055, `draw_calls` p50 1026 / max 8194, `fence_lag` p50 0.87 with 76 of
that dump's 403 frames negative (worst −71.96 ms) — a fifth of the frames completed with the CPU
already past the submit.

`build.pipeline_id` is the **template's** Tint translation stamp, newly generated for `webgpu=yes`
builds by `drivers/webgpu/SCsub` from the same input list and builder as the editor's copy, so the two
agree by construction. Comparing it against the editor's stamp is what detects a template that
translates differently from the pck it was fed.

### Reading `compiles`, `events` and `fence_lag` (added 2026-08-30, chunk 2)

- ⚠ **`ms` times the `wgpuDevice*Create*` call's RETURN, not the GPU's compile.** Dawn
  defers real backend compilation to first draw — a fully baked project measured ≈0 s of JS-visible
  GPU compile while the stall reappeared at first draw. What the number *is* worth: it is the
  **synchronous render-thread** cost, which is exactly what `pipeline_hash_map_rd.h`'s inline compile
  spends inside the frame. Do not read a 0.3 ms `'render'` record as "pipeline creation is free".
- Five creation sites, all recorded: the main-path and specialization `createShaderModule`, the base
  and Uint16-strip `createRenderPipeline` (a strip primitive genuinely pays two), and
  `createComputePipeline`. `baked` on a pipeline record comes from `WGShader::used_baked_wgsl`; on a
  specialization module it is always `false` — but do NOT read that as "the bake misses
  specializations" (a 2026-08-30 audit did, and chased a non-gap): a **baked** shader never reaches
  the spec-module path at all, because its `--overrides` WGSL carries `@id()` declarations and
  specialization becomes `WGPUConstantEntry` at pipeline creation. A `specmod#` record existing at
  all means a bake **miss** (or, with `webgpu_runtime_overrides` on, a frozen-retry fallback —
  `override_translate_fallback` counts those).
- ⚠ **`translate_ms` is the second, separate number, and it is the big one** (added 2026-08-30). `ms`
  brackets only the create call; `translate_ms` brackets everything before it — the SPIR-V
  spec-constant patch, Tint, and every WGSL rewrite pass — which was previously not measured at all.
  Reconciling the 2026-08-30 gauntlet artifacts put the unmeasured half at **23.3x** the measured one
  (293.9 ms measured vs ≈6.8 s of synchronous in-frame work between consecutive records), so any
  sizing taken from `ms` alone describes ~4% of the real cost. `ms` is deliberately unchanged so the
  existing series stays comparable. A `baked` record reports a near-zero — not exactly zero —
  `translate_ms`: baking skips Tint, not the shared rewrite passes. `render`/`compute` records
  report `0.0`, because the modules they consume push their own records.
  ⚠ **`counters.translate_ms` is the monotonic session sum and is the only translate number that
  survives `COMPILE_CAP = 512`.** Every recorded run truncates to its tail; quote the counter, not
  a sum over `compiles[]`. It also charges failed translations, which produce no record.
- **A specialization record names its shader** — `specmod#<n>:<shader>:stg<N>` (added 2026-08-30).
  The id stays first so a `specmod#` prefix match and the consecutive-pair analysis keep working.
- ⚠ **Identical `events` records coalesce** into `count` / `t_last` / `frame_last` instead
  of pushing. `acquire_fail` and `resize_skip` can fire every frame of a bad run, and 256 identical
  records would evict every other event in the session — destroying the context that makes the run
  diagnosable. The `counters` carry the true totals regardless. Every event site also keeps its
  original `WARN_PRINT_ONCE` / `ERR_PRINT_ONCE` / `console.error`: those are the only signal a session
  without the in-page harness gets. ⚠ The comparison window is the **last 8** records, not the last
  one: a single-record window is defeated by any interleaving, and the 3310 `uncaptured_error`s of
  2026-08-30 arrived as a strictly alternating pair that never coalesced, so 256 slots held 128
  frames of a ~1655-frame burst and evicted every earlier event in the session. Do not widen it
  further — a large window stops a genuine per-frame storm of *distinct* events from coalescing.
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
  `_timestamp_readback_callback` discards stale callbacks by generation. That was a reading, not a
  result, which is why the flip shipped opt-in rather than default.
- **First result, 2026-08-30 (chunk 4).** `smoke_test.mjs --query=cgperf_ts` against the `benchdraws`
  bench reported `ts = {supported: true, requested: true, degraded_frames: 0}` over 403 frames on
  `apple/metal-3`, exit 0, with no rendering corruption — the first evidence that path has ever
  produced. ⚠ **One run, one adapter, one browser** (Playwright's bundled Chromium on macOS/Metal);
  the run log does not distinguish which of the two templates carried it, so treat even the
  threads/nothreads split as unproven. Nothing at all is known about Firefox, Safari, or any
  Windows/Linux adapter. That is not enough to flip the default — it is enough to stop calling the
  defense unexercised. The bar for flipping is `degraded_frames = 0` across more than one adapter.
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

## Microbench gates — `[CGBENCH]` (added 2026-08-30, chunk 3)

`webgpu_tests/test_project/` carries three driver microbenches beside the correctness gates, reached
by the same `?scene=<key>` dispatcher (`scripts/shader_coverage.gd`): **`benchcompile`**
(first-use compile cost by shader class), **`benchdraws`** (draw-call throughput vs. ramped instance
count) and **`benchsubmits`** (encoder splits + `submit_ms` vs. ramped SubViewport count). Shared
plumbing is `scripts/bench_common.gd`.

- They emit `[CGBENCH] …` lines only. `smoke_test.mjs` takes `--expect-prefix=<p>`, `--scene=<key>`
  and `--query=<raw>` so one harness drives a bench: e.g.
  `node smoke_test.mjs ./export --scene=benchcompile --expect-prefix='[CGBENCH]'`.
- `--dump-cgperf[=<path>]` reads `window.__cgPerf` out of the live page just before the browser
  closes and writes it as JSON (build blob, counters, `ts`, per-column frame-ring stats, the newest
  24 rows decoded by name, the compile tail, every event). It is also the **channel gate**: absent
  channel, missing `build.engine_commit`, or an empty frame ring fails the run. That last check
  exists because an empty ring beside a live channel is the exact shape of the clock bug of
  2026-08-30, which nothing else noticed.
- ⚠ **The Chrome launch flags decide whether a GPU takes part at all, and getting it wrong is
  silent.** `--use-angle=vulkan --enable-features=Vulkan,UseSkiaRenderer` is what a Linux CI box
  needs; on macOS the same flags push Chrome off Metal onto **SwiftShader**. Measured 2026-08-30,
  same machine, same page: with those flags `navigator.gpu.requestAdapter().info` is
  `google/swiftshader`, without them `apple/metal-3`. Every browser number this harness produced on
  macOS before that date was software-rendered. `smoke_test.mjs` now picks its args per
  `process.platform`, prints them, prints the adapter the run actually got, and warns loudly on a
  software adapter; `--gpu-args='<flags>'` overrides when a specific backend is the point.
- ⚠ **A device lost *after* the scene's verdict is teardown, not a failure.** A scene that does not
  `?hold` quits on pass, the wasm instance goes away, and the always-on listener faithfully reports
  it. Counting that failed a green gate on whichever machine was slow enough to let the quit land
  inside the harness's 1 s poll — a flake whose probability is a function of GPU speed. The harness
  now counts those separately and reports `(+N at teardown, ignored)`.
- ⚠ **These measure the driver, not the game.** They answer "what does a draw call / a pipeline
  create cost here", never "why is CommonGrounds slow". Anything gameplay-shaped belongs in that
  repo's `/bench`.
- ⚠ `benchcompile` attributes compiles **by time window**, not by label — Godot's engine shaders share
  one name across material feature classes, so a label prefix cannot separate unshaded from
  screen-reading. Each class is added in its own phase and the `__cgPerf.compiles` slice that appears
  during that phase is the class's cost.
- The baked/unbaked A/B falls out of the checked-in `export-unbaked/` directory for free: run the same
  scene against both exports and diff `baked_hit`/`baked_miss`.
- The baked/unbaked A/B key is `baked_wgsl_hit` / `baked_wgsl_miss` on the per-phase line.
- ⚠ Without `__cgPerf` (a native run, or an OpenGL web build) every bench still runs and reports the
  engine-visible half, marking the driver-only fields `na`. A row of `na` means *not measured*, never
  zero.
- ⚠ **An occluded window measures nothing, and it looks healthy.** Measured here 2026-08-30: a native
  run whose window lost the foreground reported `eng_draws` frozen at the first step's value and
  `cpu_ms` pinned at ~6.9 ms from 64 instances to 8192 — a perfectly flat, plausible ramp, because
  the compositor had stopped asking for frames. A hidden browser tab does the same thing via
  `requestAnimationFrame`. `benchdraws` and `benchsubmits` cross-check the renderer's own draw and
  object counts against what they spawned and **fail the run** with `stale=1`; keep the window
  frontmost and the tab foreground anyway.
- ⚠ On web `cpu_frame_ms` is clamped by the display: the engine tick IS `requestAnimationFrame`, so
  a step under the refresh budget always reports the refresh interval and the ramp only becomes a
  cost curve once it overruns. `submit_ms` from the ring is the per-frame driver cost that is not
  clamped that way — read it first.

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
