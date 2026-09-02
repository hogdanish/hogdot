# hogdot → CommonGrounds performance handoff (2026-09-01)

Ledger for agents working in the `commongrounds` repo. Every number was measured with
`webgpu_tests/perf` on an M5 MacBook Pro in Google Chrome unless a row says otherwise; the
"4× throttle" rows use Chrome's CPU throttling as a stand-in for a mid-range laptop. Reproduce
anything here with `webgpu_tests/perf/README.md`.

The engine changes are commits `052f063100` (perf), `cc3e6d778c` (shader baker), `c8800be0ef`
(bed) and `2aba519efc` (docs) on hogdot `main`. Rebuild the editor and templates from that HEAD
(or newer) before exporting: `GODOT_VERSION_HASH` is part of every shader-cache path.

## What changed and what it means for the game

| Change | Effect on a frame | What the game must do |
| --- | --- | --- |
| Range-accurate flush of dynamic persistent buffers (`RD::buffer_flush(rid, offset, size)`) | Every canvas render (each puppet SubViewport, the HUD) and each 3D instance-list upload pushed its whole ~2 MB buffer through `queue.writeBuffer`; 40 puppets were 163 MB/frame and half the CPU time of a frame. Now only the written bytes move. | Nothing; automatic. If game code calls `RenderingDevice.buffer_flush` directly, pass the written size. |
| Per-render-pass encoder split off by default | One `queue.submit` per frame instead of one per render pass (65/frame at 40 puppets). | Nothing. If a frame ever renders black after a WebGPU validation error, set `rendering/rendering_device/webgpu_encoder_isolation=true` (or add `?webgpu_encoder_isolation` to the URL) to get the old behavior back, and report the validation error. |
| Redundant material `setBindGroup` skipped | Consecutive draws sharing a material no longer rebind it. | Nothing. |
| Deferred (async) pipeline creation for forward-mobile variants | A new material's first draw no longer stalls ~130 ms (Dawn compiled the pipeline in the GPU process on the frame that first used it); the ubershader draws for a frame or two while the specialized pipeline compiles in the background. | **Preload before first use** (below). The mechanism only helps when the ubershader pipeline already exists; a material created and drawn in the same frame still pays for its ubershader. |
| Shader baker: containers baked without WGSL are never reused | Earlier exports had 13 of 16 scene shader versions unbaked despite `shader_baker/enabled=true`, costing 2.4–4.2 s of Tint at boot and a specialization re-translation per pipeline variant. | Nothing to change, but **the first export after updating hogdot re-bakes everything** (slower export once). Then check the boot line: `[CGPERF] baked=<hit>/<hit+miss>` should be ~all hits; `window.__cgPerf.counters.translate_ms` should be well under a second. |
| Buffers carry labels | The bed's writeBuffer census attributes bytes per buffer kind. | Optional: copy `head_include.js` into the game's shell for the same census in `/bench`. |

## Numbers

`world` = 40 puppets in 600² SubViewports, 120 props, 12 soft-particle emitters with omni bursts,
water reading depth+screen, HUD; sky+glow+fog+AgX; 3D scale 0.5; release nothreads template.

| scene / phase | before (hogdot main d12af5ff) | after (this pass) |
| --- | --- | --- |
| world, steady | 54.0 fps · 15.7 ms CPU busy · 65 submits · 163 MB writeBuffer | **119.9 fps (vsync cap) · 1.6 ms** · 2 submits · 0.55 MB |
| world, 4× CPU throttle | 32.6 fps · 28.2 ms | **120 fps · 5.1 ms** |
| sprites3d 81 puppets | 29.3 fps · 11.2 ms | **114–120 fps · 1.8 ms** |
| sprites3d 81 puppets, 4× throttle | 23.7 fps · 39.5 ms | **120 fps · 5.3 ms** |
| sprites3d 162 puppets | 13.4 fps · 22.4 ms | 67–72 fps · 2.8 ms (now GPU-bound, see below) |
| ui 1024 widgets, 4× throttle | 55.5 fps · 19.6 ms | 77.3 fps · 8.6 ms |
| draws 4096 unique materials | (hung on an invalid pipeline) | 120 fps · 5.6 ms (~1.2 µs per draw; unchanged cost, browser API bound) |
| spawn, reveal of preloaded materials | 34–43 ms hitch | **no hitch** (async pipelines) |
| boot, world | 2.97 s to first frame, 3.3–4.2 s Tint | 1.35–1.44 s to first frame, 0.17 s Tint (baked) |

GodotWebGPU 4.6.2 (the fork's origin) measured the same as pre-patch hogdot on every scene it
could render (it fails to draw the `draws` scene at all), so hogdot had not regressed; both
carried the same two defects.

## Where the remaining cost is

1. **Puppet SubViewports are now the GPU-side limit.** At 162 puppets the CPU is at 2.8 ms but
   the frame is 14 ms: 162 × 600 × 600 × RGBA16F (`viewport/hdr_2d=true`) is ~470 MB of render
   targets redrawn and resampled every frame. On an integrated GPU this bites far earlier than on
   the M5. Levers, in order of payoff: fewer/lower-resolution viewports (600² for a sprite that
   covers ~40 screen pixels is ~200× oversampled), `hdr_2d` off for puppet viewports (halves the
   bandwidth; the puppets are 8-bit art), update-on-change instead of every frame
   (`render_target_update_mode = UPDATE_ONCE` when the animation frame changes), or one atlas
   SubViewport for all puppets with per-billboard UV regions (one render pass instead of 243).
2. **Per-draw browser cost (~1.2 µs CPU per draw+bind on the M5, ~4× that throttled).** The game's
   ~130 draws are fine; 1000+ would not be. Keep material sorting and merged meshes.
3. **HUD churn.** Every `Label.text` change re-lays out and re-uploads; 1024 changing widgets cost
   8.6 ms throttled. Change text only when the value changes.
4. **Pipeline compiles at load** still cost ~120–140 ms per batch of new shader variants, now at
   preload time instead of first draw. Spread preloads across frames on a loading screen.

## The engine-friendly pattern (do this, not what the game happens to do today)

- **Preload, then reveal.** Instantiate VFX/vehicle/character scenes (or at least their
  materials on a mesh) *hidden* during the loading screen, one batch per frame. That triggers
  Godot's pipeline precompilation (ubershader + default specializations) while nothing is on
  screen; later, the first visible use draws with the ubershader for a frame while the specialized
  pipeline compiles asynchronously, with no hitch. Materials created and drawn in the same frame
  still hitch (the ubershader itself is new).
- **Keep every shader in a resource the exporter can see.** The baker bakes what it finds in
  exported `.tres`/`.tscn` files and `Sprite3D`/`Label3D` nodes; a `StandardMaterial3D.new()`
  built in script with a feature combination no resource uses is not baked and translates live
  (~60 ms per stage on the M5). Duplicate a resource-backed material and change parameters
  instead of setting feature flags in code.
- **Export with a live editor and `--rendering-method mobile`** (run-web.sh already does), never
  `--headless`. Check the export log for `Shader baker: baking WGSL with … (pipeline id …)`; a
  `baking SPIR-V only` warning means the Tint CLI beside the editor is stale — rebuild it with
  `drivers/webgpu/tint_cli/build.sh` in hogdot and re-export.
- **Verify the bake at boot**, not by faith: `[CGPERF] baked=` line, `__cgPerf.counters`
  (`baked_wgsl_hit`, `baked_wgsl_miss`, `translate_ms`). `run-web.sh`'s pck bake counter parses
  pck format v4; if the engine bumps it, update the parser rather than trusting "0 baked".
- **Measure CPU cost as rAF busy time, not fps.** At 120 Hz everything under 8.3 ms reads as
  120 fps. The bed's `head_include.js` gives busy time and the WebGPU call census on any template;
  the runner's `--throttle 4` is the median-hardware check. Every rendering change deserves a
  screenshot A/B against the previous build (a wrong flush made the game 2× "faster" by not
  drawing 39 of 40 puppets).

## What the game showed on the final build (local run, 2026-09-01)

`scripts/run-web.sh --release` against editor + templates at `a8bfd599d7`: the export log says
`Shader baker: baking WGSL with … (pipeline id 2fb05bbd195d27ec)`, the boot line reads
`[CGPERF] baked=331/355`, `encoder_splits=0`, no `Invalid …` or device-lost messages, 60 fps
(the game's cap) in menu and world with ~190 draws and ~49 render passes per frame.

Ethan's own playtest on this build: smooth at the 60 fps cap, and close to 120 fps most of the
time with the cap raised to 120.

Two things for the CommonGrounds agent to chase:

- After entering the world the counters read `baked_wgsl_hit=594, baked_wgsl_miss=581,
  translate_ms≈4000`: roughly half the scene-shader creates after world entry are not served by
  the bake, while the fresh export cache holds WGSL for every one of its 738 variants and a
  verbose boot shows only 12 `Shader cache miss` versions in the menu. The misses therefore come
  from shader *versions the exporter never saw*: materials or shaders built or mutated in code
  after load (feature flags set on a `StandardMaterial3D.new()`, `Shader.code` edits, per-instance
  shader variants). Find them: copy `_build/web`, set `"args":["--verbose"]` in `index.html`, boot
  into the world, and count the `Shader cache miss for SceneForwardMobileShaderRD/…` lines; each
  names a version that has no exported resource. Move each to a `.tres`, and duplicate resources
  instead of building materials in script.
- The export log prints hundreds of `Index p_pass = 1 is out of bounds (draw_passes.size() = 1)`
  errors: the baker asks every `GPUParticles3D` for draw passes 1–3 regardless of its pass count.
  Harmless noise from the upstream baker, but it hides real warnings; filter it in run-web.sh or
  fix upstream.

## Before the playtest deploy (checklist for the CommonGrounds agent)

1. Pull hogdot `main` at or after `2aba519efc`; rebuild `bin/godot.macos.editor.arm64`,
   `bin/tint_convert_cli` (`drivers/webgpu/tint_cli/build.sh`) and the templates the presets
   reference (`godot.web.template_release.wasm32.nothreads.zip` for "Web", the threads zip for
   "Web Threads"). Same commit for all three, or the bake misses silently.
2. `scripts/run-web.sh --release`; expect a slower first export (full re-bake). Confirm the export
   log's `baking WGSL with` line and no `SPIR-V only` warning.
3. Boot in Chrome; read `[CGPERF] build engine=<hash>` (must be the new hash) and the `baked=`
   line; `translate_ms` under a second; `[PERF]` line's `RP/f` unchanged and no
   `[Invalid …]` GPUDevice errors in the console.
4. Play a reel: enter the world, spawn VFX, vehicles. If anything renders black/missing, try
   `?webgpu_encoder_isolation` — if that fixes it, a validation error is being hidden; capture the
   console and file it against hogdot.
5. Then start on the levers above, biggest first: puppet viewport size/`hdr_2d`/update mode, and
   preloading VFX scenes hidden on the loading screen.

## What CommonGrounds did with it (2026-09-01, evening)

The game-side pass that consumed this handoff, for the record (its own numbers live in the game's
`perf` skill, `references/remediation-log.md`):

- **r7** (`541e2cd7e9`) was pinned and deployed first; the compile reel's worst post-warm frame went
  2098 ms → 285 ms from the engine alone, on the same game code.
- **The bake was never matching any shader with a `varying`.** The origin-naming miss line
  (`a5dffac0e6`) showed 11 of 14 remaining misses were bare `.gdshader`s the baker had baked, all
  declaring varyings: the Metal editor generated user varyings from location 13
  (`SUPPORTS_MULTIVIEW`), the browser from 11, and the version sha1 never agreed. Pinned to 11 in
  `fdfcba8691` (RL-059). Plus the three Octmap raster versions the desktop editor never instantiates
  (`4dc8c05960`) and `SpriteBase3D` in the baker's scene walk. Result on the game's offline boot:
  26 unbaked versions → 2, `[CGPERF] baked=428/428` at the boot line, `translate_ms` 3.6 s → 0.85 s,
  the loading-screen warm 8.6 s → 4.1 s.
- **r8** (`fdfcba8691`) carries all of it. The general rule is RL-059: anything reaching
  `ShaderCompiler::DefaultIdentifierActions` that varies with the running device invalidates the
  bake by construction, and the counters cannot tell it from a game-side miss — read the origin.
- Still open on this side: a WGSL-only shader container for the WebGPU target (each baked version
  is ~1 MB with SPIR-V + WGSL; 19 more versions cost the game's pack ~17 MB raw), and a
  `bench.mjs`-style throttle arm for the game's own harness.

## r9 — the second engine batch (2026-09-01)

Contained fixes on top of `fdfcba8691`, one per commit. Everything below is either a no-op unless
a project opts in, or a pure removal of work.

### Two new project settings, both default-off

| setting | default | what it does | when to set it |
| --- | --- | --- | --- |
| `rendering/2d/backbuffer/max_mipmaps` | `0` (unlimited, today's behavior) | Caps the canvas backbuffer's gaussian-blur mip chain. Every level costs one render pass on **every frame** a `CanvasItem` shader with `hint_screen_texture` and a mipmap filter is visible — ~11 passes at 1080p, whatever LOD the shader reads. | Set it to the highest LOD any such shader samples, rounded up. A glass blur reading LOD ≤ 3.5 needs `5`. |
| `rendering/3d/screen_texture/max_mipmaps` | `0` (unlimited) | The same, for the 3D screen-texture copy (`hint_screen_texture` in a spatial shader), which on Mobile mips `RB_TEX_BLUR_0` with a raster pass per level. | Same rule. |

- ⚠ **The 2D cap shortens the backbuffer TEXTURE, not just the loop.** That is deliberate: with
  fewer declared levels, a shader sampling past the end reads the last generated level (the
  sampler's own LOD clamp), which is defined. Set the cap too low and the blur gets coarser — it
  never reads garbage.
- ⚠ **The 3D cap is loop-only**, because the copy usually targets the shared blur texture whose
  remaining levels glow and DOF also write. Levels above the cap keep whatever was last written
  there (zeros on WebGPU, which zero-initializes every resource) — defined, but not a copy of the
  screen. If a spatial shader samples above the cap it gets stale content, not a crash.
- Both are read when the target is (re)built, i.e. on a viewport resize.
- ⚠ These are web-visible in the editor's Project Settings dialog (unlike the `webgpu_*` ones, which
  a web-only driver registers and which must be written into `project.godot` by hand).

### Driver work, automatic

| change | effect |
| --- | --- |
| The SDR canvas format is now `navigator.gpu.getPreferredCanvasFormat()` instead of a hardcoded `BGRA8Unorm` | The browser was silently converting every presented frame wherever the two disagreed. ⚠ Chrome on Apple silicon answers `bgra8unorm`, so this is a **no-op on the measuring machine** and only helps `rgba8unorm` platforms (Android, Vulkan-backed Chrome). The chosen format is on the boot line as `canvas_fmt=`. |
| `setPipeline` for the Uint16 strip variant, `setViewport` and `setScissorRect` are skipped when unchanged on the current encoder | The strip one ran on **every indexed draw of every strip mesh**. All three caches reset at every encoder boundary. |
| Bind groups with byte-identical `(layout, entries)` are shared instead of recreated | `counters.bindgroups_created` still counts real creations only; hits are the new `counters.bindgroups_shared`. ⚠ Read the two together — `created + shared` is the number of uniform sets built, and only the ratio separates "the cache worked" from "the game built fewer sets". |
| `thread_model = Multi-Threaded` is clamped to single-threaded on web with one `WARN_PRINT` | It used to abort in `getJsObject()` on the first frame of a threaded template, with nothing naming the setting. |
### Two new instruments

- **`RenderingServer.texture_debug_usage()`** is now bound to scripting (it was C++-only), returning
  an array of dictionaries: `texture`, `width`, `height`, `depth`, `format`, `bytes`, `path`.
- **`counters.shader_rd_miss`** counts every `ShaderRD` cache miss — the class the existing
  `baked_wgsl_miss` structurally cannot see, because a container that never reaches the driver
  cannot be counted by the driver. It is also on the second console line as `rd_miss=N`.
  ⚠ It is bumped on the miss itself, not on the `print_verbose` that reports it, so it counts in a
  non-verbose run too.

### One more setting: WGSL-only shader containers

`rendering/rendering_device/webgpu_wgsl_only_containers` (default **false**) drops the SPIR-V
payload from every baked container whose WGSL bake succeeded — roughly half the baked bytes in the
pack. Read at BAKE time by the export plugin, so it must be set before the export that bakes.

- ⚠ **It removes the runtime's fallback.** A stage whose baked WGSL fails to decompress has nothing
  left to translate from and the shader fails to create, where an ordinary baked container would
  degrade to live Tint. This is a pack-size decision, not a speed one.
- ⚠ **The first export after flipping it re-bakes everything** — the bake state is part of the
  export cache key, deliberately, so the two modes can never serve each other's containers.
- It is ignored (with a warning) when `tint_convert_cli` is missing or stale, because a container
  with neither WGSL nor SPIR-V would be empty.

### What r9 measured on the game (2026-09-01, 22:00)

Engine `ba8e0c5ff7`, coherent set (editor + `tint_convert_cli` + all four templates, `production=yes`
on release). Game at `deacd433`, release nothreads export, `cg bench web idle --window 20`.

⚠ **Read the frame numbers as unattributed.** Seven game-side commits landed between the 20:48
baseline (`917ca7d3`) and this measurement (`deacd433`) — including the glass-copy paper cuts, the
crosshair's `filter_linear_mipmap` removal and water's no-screen-read tier — every one of which
removes render passes. The `48-49 → 38-40` drop in `render_passes` p50 is theirs, not the engine's.
The release templates also carry `production=yes` (thin LTO) where the baseline's did not. Nothing in
the busy series below is a clean engine A/B, and none of it should be quoted as one.

| measurement | baseline (20:48, game `917ca7d3`) | r9 (22:00, game `deacd433`) |
| --- | --- | --- |
| `web.harness.busy` p50 | 3.8 / 4.8 ms | 4.9 / 5.4 / 5.4 / 4.9 ms |
| `render_passes` p50 | 48 / 49 | 39 / 40 / 38 / 39 |
| `bindgroups_created` (56 s) | 25 913 / 17 095 | 24 981 / 21 326 / 22 254 / 20 747 |
| `uncaptured_error`, `device_lost`, `bindgroup_rebind_fail` | 0 | 0 |
| `baked_wgsl_hit` / total | 822 / 845 | 826 / 849 |

**The two clean A/Bs, both at game `deacd433` with only the named setting moved:**

| A/B | off | on |
| --- | --- | --- |
| `rendering/2d/backbuffer/max_mipmaps` `0` → `5` | `render_passes` p50 **39** | **34** (−5/frame, at a 2400×1998 canvas) |
| `rendering/rendering_device/webgpu_wgsl_only_containers` `false` → `true` | `index.pck` **90 099 648 B**, `webgpu.cache` **73 359 016 B** in 140 entries | **27 179 360 B**, **10 438 920 B** in 139 entries |

The WGSL-only saving is **62.9 MB, −69.8 % of the pack and −85.8 % of the shader cache**, and the two
deltas agree to 200 bytes — the whole reduction is the dropped SPIR-V. `baked_wgsl_hit` is unchanged
at 826/849, `spv_wgsl_cache_miss` unchanged at 44 (the 23 shaders whose WGSL bake fails keep their
SPIR-V and still translate live, exactly as intended), and `uncaptured_error` is 0. ⚠ One container
fewer appears in the WGSL-only pack (139 vs 140) with no runtime difference in any counter; unexplained,
and worth a second look before this setting ships on.

**`bindgroups_shared` was 54-68 out of 20 000-25 000 creations** — 0.3 %. The content cache is correct
and costs almost nothing, but this workload has almost no duplicate bind groups to find: the RD layer's
own `UniformSetCacheRD` already dedupes upstream of the driver. That is a measured negative result, not
a pending win — do not budget for it.

`shader_rd_miss` reads **2** on the game (against 22 on the fork's own coverage project), so the game's
bake now covers all but two versions.
