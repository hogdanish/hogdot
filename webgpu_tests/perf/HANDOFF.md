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
