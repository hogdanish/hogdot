# Review ledger — living, append-only

Every hunk carried from GodotWebGPU is read with a critical eye during porting: bugs, inconsistencies,
regressions, performance concerns, questionable design — anything the original author may have missed.
Findings land **here**, not in the code. This file is the record that lets "port now, judge later" be
safe instead of sloppy.

## The directive

- **Default disposition is `deferred`** — record the finding, port the hunk faithfully, move on.
  The port's audit trail depends on ported code matching its cited source; silent "improvements"
  poison provenance.
- **Fix now only when** the finding (a) blocks compilation or correctness on 4.7.1, or (b) is a
  trivial, obviously-correct bug fix (≤ ~5 lines). Either way the fix is a **separate commit** from
  the port commit, its message referencing the ledger ID. Never mix a fix into a port commit —
  `.claude/rules/port-provenance.md` explains why.
- ⚠ A finding that changes what gets ported (a hunk deliberately dropped or altered because of it)
  must ALSO appear in the slice-log entry and the port commit body. The ledger records the judgment;
  the slice log records what was done about it.
- ⚠ **Never delete or rewrite an entry.** Later information gets a new entry linking the old ID.

## Entry format

```markdown
### RL-NNN — YYYY-MM-DD — <severity: blocker | bug | perf | smell | question>
**Where:** `path/to/file.cpp` (area/function)
**Found while:** <slice or phase>
**What:** <the concern, 1–4 lines, with evidence — line refs, measurements, or reasoning>
**Disposition:** deferred | fixed-in <sha> | wontfix — <one line why>
```

Severities: **blocker** (breaks 4.7.1 correctness/compile — must be fixed now) · **bug** (latent
defect, works by luck or fails in an edge case) · **perf** (measurable cost the author missed or
accepted) · **smell** (design/consistency concern, no known defect) · **question** (needs
investigation before it can be classified).

---

## Entries

### RL-001 — 2026-08-06 — bug
**Where:** `servers/rendering/renderer_rd/shaders/effects/copy.glsl` (both `main()` sanitize paths)
**Found while:** phase 1, clean-mods
**What:** The fork replaces `isinf(color)` with `greaterThan(abs(color), vec4(3.0e+10))` and
`isnan(color)` with `notEqual(color, color)`, presumably because Tint/WGSL does not give usable
`isinf`. The NaN replacement is exact. The infinity replacement is **not**: `3.0e10` is 28 orders of
magnitude below `FLT_MAX` (~3.4e38), so ordinary finite HDR values above 3e10 are now clamped to
`vec4(100.0)` as if they were infinite. This changes glow/luminance behavior on **every** RD
backend, not just WebGPU, since these shaders are shared.
**Disposition:** deferred — carried faithfully. Revisit in Phase 5; the honest fix is to gate the
substitution behind the WebGPU backend, or raise the threshold to just below `FLT_MAX`.

### RL-002 — 2026-08-06 — bug
**Where:** `servers/rendering/renderer_rd/shaders/canvas_sdf.glsl`,
`servers/rendering/renderer_rd/shaders/effects/resolve.glsl` (`MODE_RESOLVE_GI`)
**Found while:** phase 1, clean-mods
**What:** Both reduce a "large sentinel" initializer from `1e20` to `1e6` — in `canvas_sdf.glsl` the
initial nearest-distance `d`, in `resolve.glsl` the initial `best_depth`. No comment explains it;
the likely motive is Safari/WGSL rejecting large float literals (cf. fork commit `d1da774`,
"shorten large float literals"). `1e6` is still far above any plausible SDF distance or depth, so
this is probably safe, but it is a silent narrowing of a sentinel's headroom on all backends and
would fail if a scene ever exceeded it.
**Disposition:** deferred — carried faithfully. Low risk; recorded so a future "why is the SDF wrong
in a huge scene" bug has a starting point.

### RL-003 — 2026-08-06 — smell
**Where:** `modules/glslang/config.py` (`can_build`)
**Found while:** phase 1, clean-mods
**What:** The fork appends `or env["webgpu"]` to the or-chain. `env["webgpu"]` raises `KeyError` when
the option is undeclared; it is only harmless on desktop because `env["vulkan"]` short-circuits
first. On the web platform vulkan/d3d12/metal are all False, so this is a hard configure-time crash
until `SConstruct` declares the option. Using `env.get("webgpu", False)` would have made the file
independent of slice ordering.
**Disposition:** deferred — hunk not carried in Phase 1; lands in Phase 2 alongside the SConstruct
option. Recorded in the clean-mods slice-log entry.

### RL-004 — 2026-08-06 — question
**Where:** `servers/rendering/renderer_rd/shaders/canvas.glsl` (end of `main()`)
**Found while:** phase 1, clean-mods
**What:** The fork's only change to this file is an added blank line before the closing brace — no
semantic content. Carried for faithfulness, but it is pure diff noise against mainline and a
candidate to drop at the next rebase-forward.
**Disposition:** deferred — carried faithfully.

### RL-005 — 2026-08-06 — bug
**Where:** `servers/rendering/rendering_device.cpp` (`_end_frame`, the upload-staging unmap loop)
**Found while:** slice 1, rd-core
**What:** The fork adds an unconditional
`for (…) driver->buffer_unmap(upload_staging_buffers.blocks[i].driver_id);` at the top of
`_end_frame`, and its own comment asserts this "is a no-op on Vulkan/Metal since buffer_map()
returns GPU-visible memory". **It is not a no-op and the map/unmap counts do not balance.** A
staging block is mapped exactly **once**, at block creation (`rendering_device.cpp:896`,
`block.data_ptr = driver->buffer_map(block.driver_id)`), and its `data_ptr` is then cached and
used for the block's entire lifetime (e.g. `rendering_device.cpp:1133`, `:2612`).
`RenderingDeviceDriverVulkan::buffer_unmap` is `vmaUnmapMemory` (`rendering_device_driver_vulkan.cpp:2109`),
and the matching `buffer_create` for `MEMORY_ALLOCATION_TYPE_CPU` does **not** pass
`VMA_ALLOCATION_CREATE_MAPPED_BIT` (`:1975–1992`) — so VMA's map counter reaches zero on the very
first `_end_frame`, every cached `data_ptr` dangles, and every subsequent frame unmaps below zero.
This is a native-backend regression introduced by a WebGPU-motivated hunk, on the shared path.
**Disposition:** deferred at port time — carried faithfully in the `rd-core` commit so the diff
matches its source. Escalate to a fix if the Phase 2 boot gate reproduces it; the likely shape is
gating the loop behind a driver trait (or routing it through the already-defaulted no-op
`RenderingDeviceDriver::buffer_flush`) rather than calling `buffer_unmap` on every backend.

### RL-006 — 2026-08-06 — smell
**Where:** `servers/rendering/rendering_device_driver.h` (`buffer_create_with_data`)
**Found while:** slice 1, rd-core
**What:** The new `buffer_create_with_data()` mirrors `buffer_create()` but silently drops its
`uint64_t p_frames_drawn` parameter. `frames_drawn` is what a driver needs to size and phase a
`BUFFER_USAGE_DYNAMIC_PERSISTENT_BIT` ring (cf. `buffer_persistent_map_advance(BufferID, uint64_t)`),
and `storage_buffer_create` can set that flag *and* supply initial data — in which case the fork's
fast path takes the with-data overload and the driver never learns the frame index. No current
backend trips it (only WebGPU sets `API_TRAIT_BUFFER_CREATE_MAPPED_AT_CREATION`, and persistent
buffers are not created with data on the paths hogdot exercises), but the API as declared cannot
express the combination.
**Disposition:** deferred — carried faithfully. Add the parameter at the next rebase-forward, or
have `RenderingDevice` skip the fast path when `BUFFER_USAGE_DYNAMIC_PERSISTENT_BIT` is set.

### RL-007 — 2026-08-06 — smell
**Where:** `servers/rendering/rendering_device.cpp` (`texture_update`, format-promotion preamble)
**Found while:** slice 1, rd-core
**What:** The fork's hunk ends with a body-less conditional whose only content is a comment:
`if (gpu_pixel_size > 0) { /* Format was promoted by the driver (e.g. R8→R32Float on WebGPU). */ }`.
It has no semantics — leftover scaffolding from an earlier revision of the hunk.
**Disposition:** **not carried** — the empty block was dropped; the two lines that do the work
(`gpu_pixel_size` / `staging_pixel_size`) landed unchanged. Recorded in the `rd-core` commit body
and slice-log entry per the drop rule.

### RL-008 — 2026-08-06 — smell
**Where:** `servers/rendering/rendering_device.cpp` (`shader_compile_binary_from_spirv`, `GODOT_DUMP_SPIRV`)
**Found while:** slice 1, rd-core
**What:** The CI shader-dump hunk names its output `<shader_name>.<stage>.spv`, so two shaders that
share a name in different directories overwrite each other, and every `FileAccess::open` failure is
swallowed silently — a dump that produced nothing looks identical to one that produced everything.
`(p_spirv[i].shader_stage < 5)` is also a bare magic number against `SHADER_STAGE_*`; it still
selects the right five names on 4.7.1 (the new raytracing stages sort after `COMPUTE` and fall
through to the `"spv"` default), so it is correct today but not self-maintaining.
**Disposition:** deferred — carried faithfully. Debug-only path behind an env var; revisit in Phase 5
when the fork's CI shader-validation flow is actually run.

### RL-009 — 2026-08-06 — bug
**Where:** `drivers/webgpu/wgsl_precompile.py` (`precompile_wgsl`, `compute_spv_hash`) and the
`wgsl_precompiled.gen.h` lookup in `rendering_device_driver_webgpu.cpp`
**Found while:** slice 1, driver-fixup (first `webgpu=yes` build)
**What:** The precompiled SPIR-V→WGSL table is keyed by **a hash of the SPIR-V blob**
(`entries.append((compute_spv_hash(spv_data[key]), wgsl))`). That SPIR-V is produced at *build* time
by an **external** `glslangValidator` taken from `$PATH`, while at *run* time the engine produces
SPIR-V with the **vendored** glslang compiled into it (`thirdparty/glslang`, 16.1.0 per
`thirdparty/README.md:417`). Nothing checks that the two are the same version, or even compares them.
Any byte of divergence changes the hash, every lookup misses, and the engine silently falls back to
the runtime `spirv_preprocess` + Tint path. **The failure mode is invisible**: the build is green,
the table is generated, the rendering is correct, and the entire optimization is simply dead — which
is the worst possible shape for a performance feature. This machine currently has 16.5.0 on `$PATH`
against a vendored 16.1.0, so the table is *probably already dead*.
**Disposition:** deferred — correctness is unaffected (a miss is a slow path, not a wrong shader), so
this is not a Phase 2 blocker and the port stays faithful. **Measure the hit rate in Phase 5** before
trusting any WebGPU startup-time benchmark; the honest fixes are to key the table on
(shader path, variant, defines) instead of a SPIR-V hash, or to have the build assert that the
external glslang's version matches `GLSLANG_VERSION_*` from `thirdparty/glslang/glslang/build_info.h`.
