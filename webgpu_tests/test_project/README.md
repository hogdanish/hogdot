# WebGPU Shader Coverage Test Project

A Godot 4.6 project that programmatically creates a scene exercising **100% of RenderingDevice shader paths**. When exported with the WebGPU template and run in a browser, it forces compilation of all shader variants through the SPIR-V → WGSL pipeline.

## What it exercises

### Environment Shaders
- `sky.glsl` — Procedural sky with radiance
- `tonemap.glsl` — ACES tone mapping
- `ssao.glsl` + blur/importance/interleave — Screen-space ambient occlusion
- `ssil.glsl` + blur/importance/interleave — Screen-space indirect light
- `screen_space_reflection.glsl` + downsample/filter/resolve — SSR
- `volumetric_fog.glsl` + `volumetric_fog_process.glsl` — Volumetric fog
- `sdfgi_*.glsl` (5 shaders) — Signed distance field GI
- `voxel_gi.glsl` + `voxel_gi_sdf.glsl` — Voxel-based GI
- `bokeh_dof.glsl` — Depth of field
- Glow/bloom blur shaders

### Material Shaders (scene_forward_clustered.glsl variants)
- Normal mapping (`NORMAL_USED`)
- Emission (`EMISSION_USED`)
- Metallic/roughness (standard PBR)
- Clearcoat (`CLEARCOAT`)
- Anisotropy (`ANISOTROPY`)
- Subsurface scattering (`SSS_USED`) + `subsurface_scattering.glsl`
- Refraction (`REFRACTION_USED`)
- Heightmap/parallax (`HEIGHT_USED`)
- Detail maps (`DETAIL_ALBEDO`, `DETAIL_NORMAL`)
- Rim lighting (`RIM_USED`)
- Backlight/transmission (`TRANSMITTANCE_USED`)
- Alpha scissor (depth prepass variant)
- Alpha hash
- Alpha depth pre-pass
- Unshaded mode
- UV2 coordinates
- Billboard mode
- Proximity fade
- Distance fade
- Vertex grow

### Lighting & Shadows
- `cluster_store.glsl` + `cluster_render.glsl` — Light clustering (7 lights)
- Directional shadow (4 splits)
- Omni point shadow
- Spot shadow
- Volumetric light energy

### Particles
- `particles.glsl` — GPU particle simulation
- `particles_copy.glsl` — Particle data copy
- Trail particles (`USE_PARTICLE_TRAILS`)
- Turbulence
- Collision (sphere + box)
- Attractors

### Instancing & Skinning
- `skeleton.glsl` — Bone-based vertex skinning
- MultiMesh instanced rendering (64 instances with colors + custom data)

### Canvas 2D
- `canvas.glsl` — 2D rendering pipeline
- ColorRect (basic draw)
- Label (MSDF text rendering)
- NinePatchRect (nine-patch mode)
- PointLight2D (canvas lighting path)

### Post-Processing & AA
- `taa_resolve.glsl` — Temporal anti-aliasing
- `motion_vectors.glsl` — Motion vector generation
- FSR2 (temporal upscaling, 6+ compute shaders)
- Luminance reduction (auto-exposure)

### Other
- `decal_data_inc.glsl` — Decal rendering (2 decals: albedo+normal, emission)
- Reflection probes (real-time + interior with ambient override)
- Fog volumes (box + ellipsoid shapes)
- Color correction/adjustment

## Usage

### With SPIR-V dump (for shader validation)
```bash
# Build engine with dump enabled:
GODOT_DUMP_SPIRV=/tmp/spirv_dump godot --headless --path . --quit

# Validate all dumped SPIR-V through Tint:
node ../shader_corpus/validate_spirv_dump.mjs /tmp/spirv_dump/
```

### Export for web (CI smoke test)
```bash
godot --headless --path . --export-release "WebGPU" export/index.html
```

### Run in headless Chrome
```bash
# Serve the export and verify no shader errors in console
npx playwright test smoke_test.mjs
```

### Driver microbenches (`[CGBENCH]`)

Three scenes measure what the WebGPU driver *costs*, as opposed to whether it is correct. They read
`window.__cgPerf` — the driver's always-on telemetry channel — and print one `[CGBENCH] …` line per
step. They are reached through the same `?scene=` dispatcher as the gates.

```bash
node smoke_test.mjs ./export --scene=benchcompile  --expect-prefix='[CGBENCH]'
node smoke_test.mjs ./export --scene=benchdraws    --expect-prefix='[CGBENCH]'
node smoke_test.mjs ./export --scene=benchsubmits  --expect-prefix='[CGBENCH]'

# the baked/unbaked A/B, for free — same scene, the other checked-in export
node smoke_test.mjs ./export-unbaked --scene=benchcompile --expect-prefix='[CGBENCH]'

# dump the driver's telemetry channel out of the live page (also a pass/fail gate)
node smoke_test.mjs ./export --scene=benchdraws --expect-prefix='[CGBENCH]' \
     --dump-cgperf=/tmp/cgperf.json
```

| key | measures |
| --- | --- |
| `benchcompile` | first-use pipeline/shader-module cost, by shader class, attributed **by time window** |
| `benchdraws` | draw throughput against a ramped instance count (64 → 8192) |
| `benchsubmits` | encoder splits and `submit_ms` against a ramped SubViewport count |

- ⚠ **These measure the driver, not a game.** Anything gameplay-shaped belongs in CommonGrounds'
  own `/bench`.
- ⚠ **A field printed as `na` was not measured** — never treat it as zero. Every bench runs natively
  too, where there is no `__cgPerf` channel and the driver-only columns are all `na`.
- ⚠ **Check the adapter line before believing a number.** `smoke_test.mjs` prints
  `adapter=<vendor>/<architecture>` from the driver's own boot blob and warns when it is a software
  rasteriser. On macOS the Linux-CI Chrome flags (`--use-angle=vulkan`) silently force SwiftShader,
  so the harness now chooses its flags per platform; `--gpu-args='<flags>'` overrides.
- ⚠ **`--headless` exports are never baked** (the engine warns and carries on), so a bench run
  against one reports `baked_wgsl_hit=0`. That is the unbaked arm of the A/B, not a bug.
- ⚠ **Keep the window frontmost on a native run, and the tab foreground on web.** An occluded
  window stops being asked for frames: the counters freeze and the ramp goes perfectly flat, which
  reads as "draw calls are free". `benchdraws` and `benchsubmits` detect that themselves and
  **fail** the run with `stale=1` on the affected steps rather than reporting the flat curve.

## Pass criteria

- All frames render without `[SHADER]` errors in console
- No device-lost events
- GDScript reports `PASS` in output
- For a `[CGBENCH]` run: `PASS` and no `stale=1` on any line
