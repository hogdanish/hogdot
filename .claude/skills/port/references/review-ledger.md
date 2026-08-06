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
**Disposition:** **fixed-in `d69db15`** (phase 7) — threshold raised to `3.0e+38`, just under
FLT_MAX, at both sites. That restores mainline's `isinf` semantics on every backend while keeping the
substitution WGSL-translatable, so it is preferred over gating it behind WebGPU. Done before the
Phase-9 HDR work on purpose: this threshold is what decides what counts as an out-of-range luminance.

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
the table is generated, and the entire optimization is simply dead. This machine currently has 16.5.0
on `$PATH` against a vendored 16.1.0, so the table is *probably already dead*.

⚠ **Severity raised bug → blocker, 2026-08-06, phase-4 boot gate.** This entry originally read
"correctness is unaffected (a miss is a slow path, not a wrong shader)" and **that was wrong.** A miss
is only a slow path if the runtime path can produce valid WGSL at all — and for a write-only storage
buffer it cannot, because WGSL has no `write` access mode in the storage address space. The dead table
was therefore load-bearing for correctness without anyone knowing. Confirmed by observation: the table
contains particles entries, yet the particles compute shaders still reached live Tint and failed. See
**RL-020**, which this entry is the suspected cause of.
**Disposition:** open, **fix in Phase 5 as RL-020's first hypothesis test.** Point
`wgsl_precompile.py` at the vendored glslang and check whether the table starts hitting. Note that a
hit only *masks* RL-020 — it does not fix it, because any shader absent from the table still takes the
live path. The durable fixes remain: key the table on (shader path, variant, defines) rather than a
SPIR-V hash, and have the build assert the external glslang's version matches `GLSLANG_VERSION_*` from
`thirdparty/glslang/glslang/build_info.h` instead of failing silently.

### RL-010 — 2026-08-06 — perf
**Where:** `servers/rendering/renderer_rd/forward_mobile/render_forward_mobile.cpp`
(`_render_shadow_pass`, `_render_shadow_end`), `render_forward_mobile.h` (`SceneState::ShadowPass`)
**Found while:** slice 3, forward-mobile
**What:** Mainline 4.7.1 added `RSE::LIGHT_AREA`, which renders its shadow into the *same*
positional shadow atlas framebuffer as omni/spot with `using_dual_paraboloid = true`
(`render_forward_mobile.cpp:1568`). It therefore lands in `p_render_data->shadows` and flows into
`scene_state.shadow_passes` — the list the fork's same-framebuffer merge iterates. The fork predates
area lights entirely, so its merge has never seen one. Line-level reading suggests merging *would*
be safe (each pass is scoped by its own viewport/scissor to its own atlas rect, and shadow passes
have no intra-batch read-after-write), but nothing has run it, and the phase brief's standing rule is
to be correctness-conservative rather than speculatively extend a fork optimization.
**Disposition:** fixed-in `<this slice>` — added `ShadowPass::mergeable` (default true), cleared for
area-light passes, and required by the merge loop. Area lights keep one render-pass encoder each on
WebGPU, i.e. they are unoptimized rather than wrong. **Phase 5 follow-up:** with a browser run
available, flip the flag on and confirm area-light shadows still render; the exclusion is one field
and two conditions, so re-enabling is cheap.

### RL-011 — 2026-08-06 — bug
**Where:** `servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp`
(`skeleton_allocate_data`, `_skeleton_atlas_ensure_capacity`)
**Found while:** slice 2, storage-rd
**What:** The skeleton atlas is a pure bump allocator with **no free list and no reclamation**.
`skeleton_atlas_used` only ever increases (`skeleton_atlas_used += float_count`). `skeleton_free()`
calls `skeleton_allocate_data(p_rid, 0)`, which sets `skeleton->size = 0` and so skips the
allocation block entirely — the dead skeleton's slot is never returned. The same applies to a live
skeleton that changes bone count: it takes a fresh slot and abandons the old one. Because
`_skeleton_atlas_ensure_capacity` grows by doubling and **frees and reallocates the GPU buffer** each
time, a scene that spawns and despawns skeletons (any pooled-enemy or streaming setup — which is
exactly what CommonGrounds is) grows GPU memory without bound until allocation fails. This only bites
where `API_TRAIT_SKELETON_BUFFER_DIRECT_WRITE` is set, i.e. WebGPU, where memory is *tightest*.
**Disposition:** **fixed-in `37e82a2`** (phase 7) — `_skeleton_atlas_release()` hands the slot back
and `_skeleton_atlas_alloc()` reuses it, from a free list keyed by slot size in floats. Reuse is
exact-size only, which is the case a pool of identical skeletons produces; a slot whose size never
recurs parks rather than coalescing, and that residual is accepted. A slot freed at the tail goes
straight back to the bump allocator, so a spawn/despawn cycle at the high-water mark does not grow it
at all. ⚠ Every slot is `bones * 12` (3D) or `bones * 8` (2D) floats — both multiples of 4 — which is
what keeps offsets vec4-aligned as `atlas_offset` requires; a future slot size that is not a multiple
of 4 breaks that silently.

### RL-012 — 2026-08-06 — bug
**Where:** `servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp`
(`_skeleton_atlas_ensure_capacity` + `_update_dirty_skeletons` atlas path)
**Found while:** slice 2, storage-rd
**What:** Growing the atlas frees the old storage buffer and creates a new, **uninitialized** one.
The CPU mirror `skeleton_atlas_data` survives (`LocalVector::resize` preserves contents), but nothing
re-uploads it: `_update_dirty_skeletons` only writes the range
`[atlas_dirty_min, atlas_dirty_max)` covering skeletons dirty *this frame*. Every skeleton that is
not dirty on the frame the atlas grows therefore keeps pointing at garbage GPU memory until it next
becomes dirty. Animating skeletons are dirty every frame and hide this; a skeleton posed once and
left static (a ragdoll at rest, a posed prop) renders with undefined bone transforms the moment some
*other* skeleton triggers a grow.
**Disposition:** **fixed-in `37e82a2`** (phase 7, same commit as RL-011) — `_skeleton_atlas_ensure_capacity`
now seeds the new buffer from the CPU mirror, which survives the resize, before returning. Uploads
`min(skeleton_atlas_used, old_capacity)` floats, i.e. the whole old mirror; the slack past the
high-water mark is uninitialized but nothing reads it.

### RL-013 — 2026-08-06 — smell
**Where:** `servers/rendering/renderer_rd/forward_mobile/render_forward_mobile.cpp`
(`_render_list_template`, instance-batching and firstInstance blocks)
**Found while:** slice 3, forward-mobile
**What:** Two inconsistencies in the batching predicates, neither known to misrender:
(1) the firstInstance fast path compares whole push-constant structs with
`memcmp(&push_constant, &prev_fi_push_constant, push_constant_size)`, which reads **padding bytes**.
`prev_fi_push_constant` is zero-initialized but `push_constant` is assembled field-by-field, so
indeterminate padding can make two semantically identical push constants compare unequal. The
failure direction is safe — a spurious difference only forces an extra `draw_list_set_push_constant`,
never a skipped one — so this costs the occasional IPC crossing the optimization exists to avoid.
(2) the batch predicate rejects a candidate with `next_inst->instance_count == 0`, but the *first*
element reaches the same test through `instance_count = owner->instance_count > 1 ? … : 1`, which
silently maps 0 to 1 and accepts it. The two ends of a batch are judged by different rules.
**Disposition:** deferred — no known defect, and both are inside the fork's own performance work
where faithful carriage matters most. Worth revisiting if WebGPU draw-call counts come in above what
the fork's own measurements (`fd5f8c8`, "3.25x to parity") predict.

### RL-014 — 2026-08-06 — bug
**Where:** `servers/rendering/renderer_rd/shaders/forward_mobile/scene_forward_mobile.glsl`
(mainline's area-light loop, ~line 2249)
**Found while:** slice 4, shaders
**What:** The fork rewrites ~20 `instances.data[draw_call.instance_index]` reads to
`instances.data[batch_instance_index]` so that instance-batched draws address the right instance
(`batch_instance_index = sc_multimesh() ? draw_call.instance_index : draw_call.instance_index +
gl_InstanceIndex`). Mainline 4.7.1 then added an area-light loop that reads
`instances.data[draw_call.instance_index].area_lights` — the one remaining unmigrated site, sitting
between an omni loop and a spot loop that the fork *did* migrate. This is not merely unoptimized: the
batch predicate in `_render_list_template` compares omni, spot, reflection-probe and decal counts but
**not** `area_light_count`, so two instances with different area lights can land in the same batch,
and every instance in that batch would read instance 0's `area_lights` bitfield.
**Disposition:** fixed-in `<slice 4>` — retrofitted to `batch_instance_index`, matching every sibling
loop. Safe in both directions: with batching off, `gl_InstanceIndex` is 0 and the two expressions are
identical, so nothing changes on Vulkan/Metal. ⚠ **This deviates from `phase-3-renderer.md`, which
said to "leave it bypassing".** That instruction was written to avoid speculatively *extending* a
fork optimization; here, not extending it leaves a genuine mis-render, so the phase brief has been
corrected in the same change. Compare RL-010, where exclusion *was* the conservative answer because
the merge could simply be skipped without making anything wrong.

### RL-015 — 2026-08-06 — bug
**Where:** `servers/rendering/renderer_rd/shaders/environment/volumetric_fog_process.glsl:804,805,856`
**Found while:** slice 4, shaders
**What:** 4.7.1 added three `any(isnan(x)) || any(isinf(x))` validity checks to volumetric fog. Both
intrinsics are unavailable in WGSL, which is exactly why the fork rewrote `isnan` as
`notEqual(x, x)` in `motion_vectors.glsl` and `isinf` as a magnitude compare in `copy.glsl`
(see RL-001). The fork never saw this file — `git show 4.6.2-stable:…` and the fork's own copy both
contain **zero** occurrences — so no fork hunk covers it and nothing in the port surface flags it.
The build stays green either way: Godot embeds `.glsl` as source and glslang compiles it at runtime,
so this can only surface when volumetric fog is first drawn on WebGPU.
**Disposition:** **fixed-in `2f3d721`** (phase 7) — `VEC4_IS_NAN` / `VEC4_IS_INF` macros applied at
all three sites, using the fork's own substitutions but with a `3.0e+38` infinity threshold rather
than the `3.0e+10` of RL-001. Nothing here depends on the difference: every value these guard is
clamped to `65504.0` on the next line. Sweep re-run at fix time: still exactly these three hits.
⚠ Expect more of this shape at every future rebase-forward: mainline adding a WGSL-hostile intrinsic
to a file the fork never touched is invisible to `port-surface.sh`, which classifies by *fork* delta.
A cheap standing check is `rg 'modf\(|isnan\(|isinf\(' servers/rendering/renderer_rd/shaders/` after
each rebase — that is how this was found.

### RL-016 — 2026-08-06 — blocker
**Where:** `servers/rendering/rendering_device_driver.cpp` (`RenderingDeviceDriver::api_trait_get`)
vs `rendering_device_driver.h` (`enum ApiTrait`)
**Found while:** phase 3 gate, first native windowed run
**What:** The fork adds 8 enumerators to `ApiTrait` but never adds matching cases to the base
`api_trait_get`, whose `default:` is `ERR_FAIL_V(0)`. Both the Vulkan and Metal drivers end their own
switch with `default: return RenderingDeviceDriver::api_trait_get(p_trait)`, so every query for a
WebGPU trait on a native backend falls through to that `ERR_FAIL_V` and prints. Measured: **189
`ERROR: Method/function failed. Returning: 0` at `rendering_device_driver.cpp:59`** in a 180-frame
Mobile-renderer run of `webgpu_tests/test_project`. The *returned* value was already correct — 0 is
the intended native default for all 8 — so nothing rendered wrong; the defect is pure diagnostic
noise, but at a volume that buries real errors and fails the phase gate's "no new errors versus
vanilla" clause. The fork would not have seen this: it is a WebGPU fork and nobody ran its tree on
Metal.
**Disposition:** fixed-in `<separate commit>` — added the 8 canonical cases (all 0/false; 0 on
`API_TRAIT_STAGING_BUFFER_MAX_SIZE_MB` means "no driver cap", per the `if (driver_max_mb > 0)` guard
at `rendering_device.cpp:8910`). Qualifies for fix-now under the review directive on both counts: it
blocks the 4.7.1 native path and the change is mechanical and obviously correct.
⚠ **Standing lesson for the next rebase-forward:** adding an `ApiTrait` enumerator is a **two-file**
change. The header alone compiles, links, and passes every headless check, because headless runs the
dummy driver and never queries these traits. Only a windowed native run surfaces it.

### RL-017 — 2026-08-06 — smell
**Where:** `servers/rendering/renderer_rd/storage_rd/texture_storage.cpp:601-606`
(`TextureStorage::TextureStorage`, default VRS texture)
**Found while:** slice 2, storage-rd — gating-discipline pass
**What:** The fork's other three `texture_storage.cpp` hunks are gated (`#ifdef WEBGPU_ENABLED`,
`#ifndef WEBGPU_ENABLED`), but this one is **not**: it unconditionally moves
`TEXTURE_USAGE_STORAGE_BIT` inside the `vrs_supported ? … : 0` ternary, so on *any* backend that
reports no VRS support the 4×4 default VRS texture is now created without the storage bit. The
comment names WebGPU as the motivation but the code applies everywhere. The change looks
independently defensible — requesting storage on the `R8_UINT` fallback format was arguably wrong to
begin with — and the blast radius is one 4×4 placeholder texture, so no defect is claimed. It is
recorded because an ungated behavioral change in a driver-gated slice is exactly the class the
phase-3 brief's gating-discipline rule exists to catch, and because the *reason* it is safe (the
texture is a placeholder, not a real VRS target) is not written anywhere in the code.
**Disposition:** deferred — carried faithfully and unmodified. Metal reports VRS support on this
machine, so the branch is not even taken here; a backend without VRS is where this would first
matter.

### RL-018 — 2026-08-06 — smell
**Where:** `scene/resources/compressed_texture.cpp:243` (`CompressedTexture2D::get_image`)
**Found while:** slice 7, core-odds
**What:** The fork rewrites `get_image()` to reload the image from disk instead of calling
`RS::texture_2d_get()`, because on single-threaded WASM that starts an async GPU readback which
returns zeros and never completes. The reasoning is sound, but the new path is **not gated** — no
`WEB_ENABLED`, no `WEBGPU_ENABLED` — so it changes behavior on every platform. Two consequences the
comment does not mention: desktop now pays a file open plus a full image decode where it previously
did a GPU readback, and, more importantly, `get_image()` no longer reflects the *texture* — it
reflects the *asset on disk*. Anything that modified the texture through RenderingServer will read
back stale content. The GPU path survives only as a fallback for textures with no `path_to_file`.
**Disposition:** deferred — carried faithfully. It is correct for the platform this fork exists to
serve, and the desktop editor is not hogdot's product. Revisit if the editor misbehaves around
runtime-modified textures.

### RL-019 — 2026-08-06 — bug (latent)
**Where:** `scene/resources/compressed_texture.cpp:249-262` (same hunk as RL-018)
**Found while:** slice 7, core-odds
**What:** The hand-rolled `.ctex` header parse drops two checks the real loader performs 200 lines
above it: the `version > FORMAT_VERSION` guard, and the `FORMAT_BIT_STREAM` test that decides whether
`p_size_limit` applies (it hardcodes `0`). A `.ctex` written by a newer Godot is therefore fed
straight to `load_image_from_file` instead of being rejected with "file is too new". In practice it
degrades rather than corrupts — a bad parse yields an invalid or empty image and the code falls
through to the GPU path — so no user-visible defect is claimed today. It becomes real the moment the
texture format version is bumped, which is exactly when nobody will be looking here.
**Disposition:** deferred — the skip count itself was verified correct against 4.7.1's writer before
carrying (magic + 8 × `get_32()`), which is the part that would have silently corrupted data.

### RL-020 — 2026-08-06 — **blocker**
**Where:** `drivers/webgpu/spirv_preprocess.cpp` (absence) + `drivers/webgpu/wgsl_precompile.py`
**Found while:** phase-4 boot gate, first browser run
**What:** Write-only storage buffers cannot be translated. Tint turns SPIR-V `NonReadable` (GLSL
`writeonly`) into `ptr<storage, T, write>`, which is invalid WGSL — the storage address space permits
only `read` and `read_write`. Every skeleton and particles compute shader fails, their pipelines and
uniform sets then fail on a null shader, and the engine hits a WASM `unreachable` trap before the
main loop. ~150 occurrences from one cause.

This is **not** a dropped port hunk and **not** upstream drift: `writeonly` counts are identical in
`skeleton.glsl` / `particles.glsl` / `particles_copy.glsl` at 4.6.2 and 4.7.1, and the fork has no
`NonReadable` handling either — it strips `NonWritable` (the read-only direction) in three places and
nothing else. The fork evidently never hit this at runtime, which points at its precompiled-WGSL
table absorbing these shaders. See **RL-009**, now upgraded from a perf question to this blocker's
suspected cause: the table contains particles entries yet these shaders still reached live Tint, so
the lookup missed.
**Disposition:** open, **fix in Phase 5** — this is the phase-5 gate's first task, ahead of any
rendering-correctness work. Two candidate fixes, cheapest first: (1) pin `wgsl_precompile.py` to
Godot's vendored glslang so the table's SPIR-V hashes match the runtime's and the entries hit;
(2) add a `NonReadable`-stripping pass to `spirv_preprocess.cpp` so live translation produces
`read_write` — the robust general fix, and the only one that helps a shader absent from the table.
(1) is a hypothesis test; (2) is the real repair. Expect to need both.

### RL-021 — 2026-08-06 — bug
**Where:** `drivers/webgpu/tint_cli/build.sh` (the SPIRV-Tools and Tint compile loops)
**Found while:** phase 5, standing up the native `tint_convert_cli`
**What:** The parallelism throttle is `if (( $(jobs -r | wc -l) >= JOBS )); then wait -n 2>/dev/null
|| true; fi`. **`wait -n` needs bash >= 4.3.** macOS ships bash **3.2.57** as `/bin/bash` and there is
no Homebrew bash on this machine, so `wait -n` fails instantly with `invalid option`, `2>/dev/null ||
true` swallows it, and the throttle becomes a no-op — the script then spawns one background `c++` per
source file with no bound at all (~1,200 concurrent compilers on a 24 GB machine). This is **not
hypothetical**: `wgsl_precompile.py` invokes `build.sh` from inside every `webgpu=yes` SCons build, so
it already ran that way in phase 4. `set -e` does not catch it either, because the failures are in
background jobs.
**Disposition:** **fixed** in the same commit as RL-020's repair — replaced with a portable
`throttle()` poll (`while (( $(jobs -r | wc -l) >= JOBS )); do sleep 0.05; done`) that works on bash
3.2 and 5.x alike, and made `JOBS` overridable from the environment so the build can be capped below
`hw.ncpu`. Trivial and obviously correct; leaving it would have made every future `webgpu=yes` build
a machine hazard.

### RL-022 — 2026-08-06 — bug
**Where:** `drivers/webgpu/tint_cli/build.sh` (link step, `[[ -f "$obj" ]] && LINK_OBJS+=…`)
**Found while:** phase 5, same build
**What:** Compile failures are **silently discarded**. `compile_one` runs as a background job, so
`set -e` cannot see it; `wait` with no arguments always returns 0; and the link step then filters the
object list with `[[ -f "$obj" ]]`, dropping any object that failed to compile. A build that lost
half of Tint would still print `Built: bin/tint_convert_cli` and exit 0, failing only if the missing
code happened to be referenced. Observed here as `199 objects` / `368 objects` against SCsub source
lists of 389 / 824 — that particular gap is the `find` filters, not failures, but nothing in the
script distinguishes the two cases.
**Disposition:** deferred — not blocking (the binary links and runs correctly), and a real fix means
collecting per-job exit statuses, which is more than a drive-by change. Revisit if a `webgpu=yes`
build ever produces a `tint_convert_cli` that misbehaves rather than failing.

### RL-023 — 2026-08-06 — **blocker**
**Where:** `thirdparty/tint/src/tint/lang/spirv/reader/lower/texture.cc`
(`State::Process` / `ConvertUserCall`), triggered by
`servers/rendering/renderer_rd/shaders/area_lights_inc.glsl`
**Found while:** phase 5, first browser run after RL-020's repair
**What:** Tint aborts with `texture.cc:606 internal compiler error: TINT_ASSERT(tex_ty)`
translating `scene_forward_mobile.glsl:color_pass:frag` — the main scene shader, so nothing renders.
Root cause, established by instrumenting a scratch copy of Tint: `ConvertUserCall` forks a function
when a call site converts one of its handle parameters, retargets that call, and destroys the
original **only if no remaining usage is a Call**. An original kept alive solely by *another dead
original* survives with its parameters still typed `spirv.image`. Its texture builtins are still
reachable through `ir.Instructions()`, so the lowering picks them up and asserts on a non-texture
type. Observed exactly twice, on `fetch_ltc_lod` and
`fetch_ltc_filtered_texture_with_form_factor` — the LTC helpers, which take `texture2D`/`sampler2D`
parameters and are called from more than one site.

⚠ **This is 4.6.2→4.7.1 drift, not a port defect.** `area_lights_inc.glsl` does not exist at
`4.6.2-stable` and does not exist on the fork (`git cat-file -e` on both). Area lights are a 4.7.1
addition — the same feature RL-010 flagged on the shadow-atlas side — and they are the first Godot
shaders to pass sampler/texture handles through functions called from several sites. GodotWebGPU
could not have hit this.
**Disposition:** **fixed** — vendored Tint patch `0007-drop-unreachable-functions-in-texture-lowering.patch`,
following the existing six-patch convention in `thirdparty/tint/patches/`. It sweeps functions
unreachable from any entry point after `UpdateValues()`, before the builtin worklist is collected.
Measured over the 193 SPIR-V modules `wgsl_precompile.py` produces: Tint failures 10 → 9, nothing
newly failing. This is a genuine upstream Tint bug and the best of the seven patches to report
upstream; recorded as such in `thirdparty/tint/patches/README.md`.

### RL-024 — 2026-08-06 — bug
**Where:** the SPIR-V preprocessing chain (pass not yet isolated), seen via
`drivers/webgpu/wgsl_precompile.py`
**Found while:** phase 5, building a native failure corpus with `bin/tint_convert_cli`
**What:** Three shader variants fail *SPIR-V validation* after preprocessing, before Tint even
starts: `effects/tonemap.glsl:bicubic:frag`, `tonemap.glsl:bicubic_1d_lut:frag` and
`effects/taa_resolve.glsl:default:comp`, all with
`OpFunctionCall Argument <id> ...'s type does not match Function <id> ...'s parameter type`.
A preprocessing pass is therefore rewriting either a function signature or its call sites but not
both — `split_combined_samplers` and `flatten_binding_arrays` are the two that rewrite handle types,
and both must keep `OpTypeFunction`, `OpFunctionParameter` and `OpFunctionCall` in step. Producing
invalid SPIR-V is a defect regardless of what Tint does with it.
**Disposition:** deferred — these three take the live path and fail there too, so they are real, but
they are effects shaders rather than anything on the boot path. Isolate with the `tint_bisect` recipe
in the slice log (pass mask + `spv_tool --val`) once the gate scenes render.

### RL-025 — 2026-08-06 — bug
**Where:** `drivers/webgpu/wgsl_precompile.py` (`SHADER_REGISTRY`)
**Found while:** phase 5, native corpus run
**What:** The registry's per-shader define sets have drifted against 4.7.1. Eleven of the 193 modules
fail at **glslangValidator**, before any WebGPU code is involved — `octmap_downsampler`,
`octmap_filter`, `octmap_roughness`, `ssao_blur`, `ssil_blur`, `subsurface_scattering`,
`cluster_render`, `giprobe_write`, plus three `SKIP: (no stage)` entries whose stage names the
registry no longer matches. The errors are structural, e.g. `ssao_blur`:
`'sample_blurred_wide' : no matching overloaded function found` followed by `'' : missing #endif` —
the assembled source is not a valid translation unit because a `#define` the 4.7.1 shader now needs
is absent from the registry entry. ⚠ **Silent by construction:** `precompile_wgsl` counts the
failures and carries on, the build stays green, and the shader simply never enters the table.
**Disposition:** deferred — the table is a build-time optimization, and after RL-020's repair a
missing entry is a slow path rather than a wrong one. Fix alongside RL-009 (the whole table is
currently dead from the glslang hash skew, so re-deriving the registry only pays off once the lookup
hits). ⚠ Do not treat a green `webgpu=yes` build as evidence the registry is current — grep the build
log for `glsl failures`.

### RL-026 — 2026-08-06 — **blocker**
**Where:** `drivers/webgpu/rendering_device_driver_webgpu.cpp` — `_stages_to_wgpu_visibility()` and
every BGL entry built from it in `shader_create_from_container()`
**Found while:** phase 5, first browser run after RL-023's repair
**What:** Every `SceneForwardMobileShaderRD` pipeline layout is rejected with
`The number of samplers (18) in the Vertex stage exceeds the maximum per-stage limit (16)`, which
invalidates every scene render pipeline in turn. The canvas stays black while the engine reports no
error of its own.

The driver derives a bind-group-layout entry from Godot's *reflection* — i.e. every binding the GLSL
declares — and gives each one a blanket `Vertex | Fragment` visibility for any shader that uses
either stage. WebGPU counts each entry against `maxSamplersPerShaderStage` for every stage it is
visible to, referenced or not. Measured on this machine's adapter (Chrome, apple/metal-3):
`maxSamplersPerShaderStage` is **16**, and `engine.js` already requests the adapter maximum, so 16 is
a ceiling rather than a default that could be raised.

⚠ **This is 4.6.2→4.7.1 drift meeting a fork design with zero headroom, not a port defect.**
`_stages_to_wgpu_visibility` is byte-identical to the fork's. `scene_forward_mobile_inc.glsl`
declares **exactly 16** `uniform sampler` objects at `4.6.2-stable` — precisely at the limit — and
4.7.1 adds three area-light uniforms, two of which (`ltc_lut1`, `ltc_lut2` at set 0 bindings 15/16)
are `sampler2D`. `split_combined_samplers` mints one sampler apiece, giving 18. GodotWebGPU shipped
one sampler away from this failure and would have hit it on the next upstream release that added any.
(Third area-lights entry in the RL-010 / RL-023 series.)

Measured with `bin/tint_convert_cli` over the real forward-mobile WGSL, both `color_pass` and
`uber_color_pass`:

| stage | samplers declared | **referenced** | textures declared | **referenced** |
| --- | ---: | ---: | ---: | ---: |
| vertex | 18 | **0** | 12 | **0** |
| fragment | 18 | **8** | 12 | **9** |

Every one of the vertex stage's 18 samplers appears exactly once in the WGSL — its own declaration.
glslang does not strip unused uniforms from the SPIR-V and Tint's writer emits every module-scope
handle it finds, so the declaration list wildly overstates what a stage uses. WGSL itself only
requires a binding in the pipeline layout when an entry point *statically uses* it.

**Disposition:** **fixed** — `_wgsl_binding_is_referenced()` plus a `narrow_visibility()` post-pass
over both BGL entry lists (the per-set one and the merged push-constant one). Each stage's WGSL is
scanned for `@group(G) @binding(B) var NAME`, and the stage bit is recorded only when `NAME` occurs
more than once with identifier boundaries. Every entry is then masked down to the stages that really
reference it, and a binding no stage references gets visibility `0`, which is legal and costs no
slot. Textual reference counting over-approximates static use, so it can only remove a bit that was
spurious — it can never hide a binding a shader actually reads, and a mistake would surface loudly at
pipeline creation rather than as silent corruption.

⚠ **Samplers were only the first cap of four.** The first build narrowed sampler and texture entries
alone, and the browser immediately returned
`The number of storage buffers (11) in the Vertex stage exceeds the maximum per-stage limit (10)`
on the same pipeline layouts. Blanket visibility overruns *every* per-stage class Godot gets near, so
the pass now covers buffer entries too. Adapter limits measured here: 16 samplers, 48 sampled
textures, 10 storage buffers, 12 uniform buffers.

⚠ The fork's own mechanism for the storage-buffer half of this, the `//SSBO_USED:group,binding`
metadata the driver parses into `wgsl_buffer_stages`, is **dead**: nothing in the tree emits it
(`rg SSBO_USED` finds only the parser and the fork's docs), so `wgsl_buffer_stages` is always empty
and the narrowing at both of its call sites never fires. It was a naga-era feature the Tint migration
dropped, and its comment — "Firefox/wgpu enforces Metal's limit of 8 storage buffers per shader
stage" — shows the fork knew about this failure class and believed it was handled. Left in place: it
is inert, and `narrow_visibility` runs after it and subsumes it. Removing it is cleanup for a later
pass, not a fix.

### RL-027 — 2026-08-06 — **blocker**
**Where:** `drivers/webgpu/rendering_device_driver_webgpu.cpp` — the WGSL post-processing in
`shader_create_from_container()` *and* `_create_module_with_spec_constants()`; the dead
`wgsl_depth_alias_bindings` machinery
**Found while:** phase 5, the run after RL-026's repair
**What:** With the per-stage visibility fixed, every `SceneForwardMobileShaderRD` render pipeline
still failed, now with a single distinct cause:
`Texture binding (group:1, binding:8) is TextureSampleType::Depth but used statically with a sampler
(group:1, binding:28) that's SamplerBindingType::Filtering`. Binding 8 is `shadow_atlas`, binding 28
is `SAMPLER_LINEAR_CLAMP` (bindings are doubled by the preprocessor, so these are Godot's 4 and 14).

Godot uses one shadow atlas two ways in the same shader:
`textureSampleCompare(shadow_atlas, shadow_sampler, …)` for the PCF lookup, and
`textureLod(sampler2D(shadow_atlas, SAMPLER_LINEAR_CLAMP), …)` for the blocker search
(`scene_forward_lights_inc.glsl`, 7 sites at 4.7.1). `fix_depth2_images` promotes the image's
`Depth=2` to `Depth=1` so Tint accepts the Dref sample, which makes it a `texture_depth_2d` — and
WebGPU then permits only comparison or non-filtering samplers on it. **No bind-group layout can
satisfy both uses:** the atlas is a depth format, whose only legal sample types are `depth` and
`unfilterable-float`, and neither accepts a filtering sampler.

⚠ **This is a fork defect the naga→Tint migration left behind, not 4.7.1 drift.** The GLSL pattern
is present at `4.6.2-stable` too (5 sites), and the driver still carries the machinery that used to
handle it — `wgsl_depth_alias_bindings`, `WGShader::depth_alias_bindings`, the BGL alias entries and
the `uniform_set_create` binding — all keyed on a WGSL variable named `<orig>_depth_alias`. **Nothing
produces that name.** `git grep depth_alias webgpu/webgpu-4.6.2` finds only the same consumers on the
fork's own tip, and there is no producer in `spirv_preprocess.cpp` or in vendored Tint. naga split
mixed-usage depth textures and named the clone; Tint does not, and the consumer side was never
retired. GodotWebGPU on 4.6.2 hits this the moment a scene casts a shadow.

**Disposition:** **fixed** — `_rewrite_depth_texture_samples()`, a WGSL pass that turns
`textureSample`/`textureSampleLevel` on a `texture_depth_2d` into
`textureLoad(tex, vec2<i32>(coord * vec2<f32>(textureDimensions(tex, level))), level)`. A texel fetch
takes no sampler, so the conflict disappears. `textureSampleGrad`/`Bias` are deliberately not
handled: their extra operands have no `textureLoad` equivalent and no Godot shader takes a gradient
off a depth texture.

The behavioral change is nearest instead of linear sampling on that lookup, and it costs less than
it sounds: linear filtering of a 32-bit depth format is not a required Vulkan format feature
(`VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT` is optional for `D32_SFLOAT`), so the desktop
backends this GLSL was written for are not reliably interpolating it either.

⚠ **The driver has two WGSL-producing paths and they must stay in step.**
`_create_module_with_spec_constants()` re-runs Tint on spec-constant-patched SPIR-V and repeats only
*some* of `shader_create_from_container()`'s WGSL passes — its own comment says "must match
shader_create_from_container", which is a convention, not a mechanism. Adding the rewrite to one path
only produced a *new* failure rather than a fix:
`Entry point's stage (ShaderStage::Fragment) is not in the binding visibility in the layout
(ShaderStage::None)` — the layout was built from rewritten WGSL where `SAMPLER_LINEAR_CLAMP` had
become unused, while the specialized module still sampled with it. Hence the shared helper. Any
future WGSL pass must be added to both, and this divergence is itself worth a follow-up cleanup.

### RL-028 — 2026-08-06 — **blocker**
**Where:** `drivers/webgpu/spirv_preprocess.cpp` — `flatten_binding_arrays()`, the pass-4 rewrite loop
**Found while:** phase 5, the run after RL-027's repair, when every scene pipeline finally *created*
**What:** With pipeline creation fixed, every draw failed instead:
`[Buffer] bound with size 3712 at group 0, binding 14 is too small. The pipeline requires a buffer
binding which is at least 63744 bytes.` Binding 14 is Godot's set 0 binding 7, the `DirectionalLights`
UBO — correctly sized at 8 × 464 = 3712 by the engine.

Dumping the generated WGSL showed Tint emitting `@size(7505u)` on `DirectionalLightData.shadow_normal_bias`
in the **fragment** stage only (the vertex stage was clean). That inflates the struct to 7968 and the
array to 8 × 7968 = **63744** — the exact number Dawn reported. Tint was faithful: its writer emits
`@size` when the next member's recorded offset exceeds the natural one, so the *input* offsets were
wrong. Dumping the SPIR-V offsets straight out of the shader container gave the correct layout
(`… 80 96 112 128 144 160 176 240 …`), which put the corruption between the container and Tint — i.e.
in preprocessing. A per-pass scan for implausible `OpMemberDecorate … Offset` values named the pass on
the first run: **`flatten_binding_arrays`**.

Root cause: the pass eliminates arrays of handle types by **substituting id values word-by-word across
every instruction in the module**, excluding only `OpConstant`/`OpSpecConstant` values and `OpSwitch`
case labels. Every other *literal* operand is treated as a candidate id. `OpMemberDecorate %type
<member> Offset <value>` has two literal words and neither was excluded, so any member offset that
numerically equals a mapped id gets rewritten into that id. Observed on the forward-mobile fragment
shader, which has ~8,500 ids: offset 112 → 7601 and offset 160 → 8329.

⚠ **The blast radius is far wider than one struct.** The same substitution runs over `OpDecorate`
(`Binding`, `DescriptorSet`, `Location`, `ArrayStride`, `SpecId`…), `OpName`/`OpMemberName` string
payloads (a one-character name packs to a word inside the id range), `OpTypePointer`'s storage class,
`OpVariable`'s storage class, `OpCompositeExtract`'s literal indices, `OpVectorShuffle`'s components,
and the memory-operand masks on `OpLoad`/`OpStore`. Any of those can be silently corrupted whenever
the literal collides with a mapped id — which becomes likelier the bigger the shader. This is a fork
defect, present at `4.6.2-stable`, not 4.7.1 drift; it simply needs a module with enough ids to
collide, which is why smaller shaders and the test fixtures never caught it.

**Disposition:** **fixed** — `_is_literal_operand(op, index)`, a per-opcode table of which operand
words are literals rather than `<id>`s, consulted by both the needs-rewrite scan and the rewrite
itself. Opcodes not in the table fall through to the previous behavior, so the change can only make
the pass more conservative. Verified in Chrome: the per-pass offset scan goes silent, the WGSL loses
its `@size`, **all GPU validation errors go to zero, and `webgpu_tests/test_project` renders.**

⚠ **`wgsl_precompiled.gen.h` was NOT regenerated by this change** — SCons does not list
`spirv_preprocess.cpp` as a dependency of the generated table (recorded in the phase-5 slice log). The
table therefore still holds WGSL produced by the buggy pass. It is harmless today only because the
table is entirely dead (**RL-009**, glslang hash skew) so every lookup misses and takes the live path.
⚠ **Fixing RL-009 without first regenerating the table would resurrect this bug**, and it would then
appear only for shaders that hit the cache — the worst possible failure mode. Regenerate the table in
the same change as any RL-009 repair.

### RL-029 — 2026-08-06 — **blocker**
**Where:** `servers/rendering/renderer_rd/forward_mobile/scene_shader_forward_mobile.cpp:843`
(`actions.base_varying_index = 15`) vs `LIMIT_MAX_SHADER_VARYINGS`
(`drivers/webgpu/rendering_device_driver_webgpu.cpp:9622`)
**Found while:** phase 6 audit, workstream D (fork issue tracker cross-check)
**What:** Mobile renderer + web export leaves **exactly one** inter-stage varying slot for user
shaders. The engine hardcodes `base_varying_index = 15`, reserving 15 slots, against WebGPU's
spec-floor `maxInterStageShaderVariables` of **16**. Desktop Vulkan reports ≥31, so the reservation is
invisible natively — this ceiling exists only on WebGPU. Corroborated by GodotWebGPU issue #1
(moodster321, 2026-05-16), which reports `SHADER ERROR: Too many varyings used in shader (17 used,
maximum supported is 16)` followed by cascading `[Invalid RenderPipeline]` validation errors.

⚠ **This is a confirmed hard blocker for CommonGrounds, hogdot's sole consumer**, which targets
exactly this configuration. Measured against the game's own shaders 2026-08-06 (read-only access);
each varying costs one location, so a `vec3` is 1 slot:

| shader | varyings | slots needed | over budget by |
| --- | --- | ---: | ---: |
| `game/maps/common/city/city_windows_glow.gdshader` | `vec3`,`vec3`,`float`,`float` | 4 | **+3** |
| `game/maps/common/city/city_windows.gdshader` | `vec3`,`vec3`,`float`,`float` | 4 | **+3** |
| `game/entities/corrosion/corrosion_overlay.gdshader` | `vec3`,`vec3` | 2 | **+1** |
| `game/entities/prop/rope/rope_ribbon.gdshader` | `float`,`vec3` | 2 | **+1** |
| `game/entities/vehicle/flying/ufo/tractor_beam.gdshader` | `vec3`,`vec3` | 2 | **+1** |

Nine further spatial shaders declare exactly one varying and sit precisely at the limit with zero
headroom (`puppet_billboard`, `puppet_boil`, `water`, `water_bubble`, `lineboil_sprite3d`,
`tank_tread`, `flare`, `spiral_dust`, `impact_slash`).

⚠ **No hogdot gate scene exercises this.** `webgpu_tests/test_project` uses no custom spatial shaders
with varyings, which is why phases 4–5 went green with the defect fully present. The port is *not*
validated for its actual consumer.

⚠ **The documented fallback does not work.** Switching to `rendering_method.web="forward_plus"` hits
`TINT_UNIMPLEMENTED unhandled SPIR-V BuiltIn: HelperInvocation` in Tint's SPIR-V reader — the same
subsystem RL-023's patch 0007 already touches.
**Disposition:** **fixed-in `dc917d5`** (phase 7). Two independent causes, and the second was not in
the original analysis:

1. **The device never asked for the locations it could have had.** `platform/web/js/engine/engine.js`
   requests the adapter maximum for nine limits but **not** `maxInterStageShaderVariables`, so the
   device fell back to the WebGPU default of 16 on an adapter offering far more. Measured in Chrome
   here (apple/metal-3): **adapter 28, default device 16.** One line in `limitsToMax`.
2. **The engine reserved more locations than it uses.** `scene_forward_mobile.glsl` left locations 10
   and 11 empty and spread the rest to 14. Repacked into 0..12 with no behavioural change: `dp_clip`
   9→7 (sharing with the vertex-lighting pair — `MODE_DUAL_PARABOLOID` only ever appears with
   `MODE_RENDER_DEPTH`, which excludes them), `batch_instance_index` 10→9, `point_coord_interp` 14→10,
   `screen_position` 12→11, `prev_screen_position` 13→12.

`base_varying_index` is then `RD::has_feature(SUPPORTS_MULTIVIEW) ? 13 : 11`: the motion-vector pair
at 11–12 exists only in the `MODE_RENDER_MOTION_VECTORS` variant, which is multiview-only on this
renderer, and the WebGPU driver reports `multiview_capabilities.is_supported = false`
unconditionally, so web gets 11.

**Net: 1 user varying slot → 5 on a spec-floor 16-variable device, → 17 on this machine's adapter.**
That clears every CommonGrounds shader in the table above.

⚠ An aliased location is a **loud glslang error**, not a mis-render, so the location-7 sharing fails
safe if a future variant breaks the exclusion. ⚠ The budget table now lives at the top of the
shader's vertex stage and **must** stay in step with `base_varying_index` — they are two files.
⚠ `forward_clustered` was deliberately **not** repacked: it has the same flat 15 and the same gap, but
CommonGrounds is Mobile and Forward+ on web is separately blocked by Tint's unimplemented
`HelperInvocation`. Carried forward as a Phase-7 tail item, not silently dropped.

Gate: `webgpu_tests/test_project/shaders/varying_stress.gdshader` (`7830eb6`), four user varyings, two
instances, every varying read in `fragment()`.

### RL-030 — 2026-08-06 — bug (latent)
**Where:** `drivers/webgpu/spirv_preprocess.cpp:2194` (`_is_literal_operand`), the RL-028 repair
**Found while:** phase 6 audit, workstream B — the mandated ★ scrutiny of RL-028
**What:** RL-028's fix is sound in mechanism but its opcode table is **materially incomplete**, and
the fall-through default is the *unsafe* direction: an opcode absent from the table returns `false`
("this word is an `<id>`") and its literal operands are therefore still eligible for rewriting — the
exact RL-028 failure mode, just at a different opcode. (The header comment "Adding an opcode here can
only make the pass more conservative" is true of *additions* but obscures that the default itself is
permissive.)

Audited mechanically against SPIRV-Tools' grammar-generated operand tables
(`thirdparty/spirv-tools/generated/core_tables_body.inc`, which encodes the same
`spirv.core.grammar.json` data — note the brief's cited path
`thirdparty/spirv-headers/.../spirv.core.grammar.json` **does not exist in this tree**). Restricting
to opcodes glslang actually emits for Godot, **18 opcode families carry unprotected literals**:

| opcode | literal word | what it is |
| --- | ---: | --- |
| `OpExtInst` (12) | 4 | the **GLSL.std.450 instruction number** — every `sqrt`/`pow`/`mix`/… call |
| `OpImageSample*` / `OpImageFetch` / `OpImageGather` / `OpImageRead` / `OpImageWrite` (87–99) | 4–6 | the image-operands bitmask |
| `OpSpecConstantOp` (52) | 3 | the wrapped opcode |
| `OpArrayLength` (68) | 4 | the member index |
| `OpBranchConditional` (250) | 4,5 | branch weights |
| `OpDecorateId` (332) | 2 | the decoration |

`OpExtInst` is the dangerous one: a rewritten instruction number silently calls a **different builtin**.

**Empirically not firing today, with zero margin.** Reproduced `flatten_binding_arrays`' pass-1 map
construction over the engine's real 182-module SPIR-V corpus (dumped from `wgsl_precompile.py`): the
pass is live in **26** modules, and no uncovered literal currently equals a rewritable id. But the
lowest rewritable ids observed are **52 and 53** (`sdfgi_integrate.glsl`) and **72/73**
(`volumetric_fog_process.glsl`) — squarely inside the GLSL.std.450 instruction-number range (1–81).
The two value spaces already overlap; only the accident that those shaders do not call
`FrexpStruct`(52)/`Ldexp`(53) prevents corruption. Any shader edit or id renumbering can close that
gap silently, which is precisely how RL-028 lay dormant until a shader grew large enough.
**Disposition:** **fixed-in `845c61e`** (phase 7) — the table now covers **every** core opcode up to
SPIR-V 1.6 carrying a non-`<id>` operand (105 of them), generated from
`thirdparty/spirv-tools/generated/core_tables_body.inc` rather than hand-listed, with the generation
recipe recorded in the code comment so a SPIRV-Tools bump can be re-derived the same way. Beyond the
18 families named above this also caught `OpDecorateId`/`OpExecutionModeId` needing the *opposite*
rule to `OpDecorate` (their trailing operands really are `<id>`s), `OpGroupMemberDecorate`'s
alternating pairs, the `OpSDot` family, and the group-operation opcodes.
⚠ **The claim in this entry that `OpSwitch` is "handled separately and correctly" was wrong** — see
**RL-033**, found while implementing this fix.

### RL-031 — 2026-08-06 — bug
**Where:** `drivers/webgpu/rendering_device_driver_webgpu.cpp:207`
(`_rewrite_depth_texture_samples`), the RL-027 repair
**Found while:** phase 6 audit, workstream B — the mandated ★ scrutiny of RL-027
**What:** The rewrite emits
`textureLoad(tex, vec2<i32>(coord * vec2<f32>(textureDimensions(tex, level))), level)` with **no
clamp**. The call it replaces sampled through `SAMPLER_LINEAR_CLAMP`, whose **clamp-to-edge** address
mode was load-bearing; `textureLoad` has no address mode, and WGSL specifies an out-of-range texel
address as returning the zero value.

The directional blocker search generates out-of-range coordinates by construction
(`scene_forward_lights_inc.glsl:425`):
`vec2 suv = pssm_coord.xy + (disk_rotation * directional_penumbra_shadow_kernel[i].xy) * tex_scale;`
— an unbounded screen-space disk offset added directly in UV space, so a fragment near a PSSM split
edge pushes taps outside `[0,1]`. Those taps now return `d = 0.0`, the test `if (d > pssm_coord.z)`
fails, and the sample contributes nothing instead of clamping to the edge texel. Consequences, in
increasing severity: penumbra width mis-estimated at split edges → **and if every tap leaves bounds,
`blocker_count == 0`, which takes the `//no blockers found, so no shadow` branch and drops the shadow
entirely.** Silent — no validation error, no log line.

(The positional/atlas path at `:565` is safe: its offset is applied to the direction vector before the
dual-paraboloid projection, so the result stays inside `uv_rect`.)
**Disposition:** **fixed-in `e886ff7`** (phase 7) — the generated fetch now clamps the texel
coordinate to `[0, textureDimensions - 1]`.

The non-filtering-sampler alternative was evaluated as the audit asked, and **rejected**: it costs one
more sampler binding, and this adapter reports `maxSamplersPerShaderStage` = 16 against a scene shader
that already declares 18 and only fits because `narrow_visibility()` masks them per stage (RL-026).
Spending a sampler to save a clamp is the wrong trade on the one resource with no headroom. The
reasoning is now in the code so it is not re-litigated.
Noted and judged non-blocking: the pass skips offset-form calls (`argc` mismatch), which would fail
loudly at pipeline creation rather than silently — and no Godot shader takes an offset sample off a
depth texture (the 6 files using `textureLodOffset`/`textureOffset` are all colour-buffer effects).

### RL-032 — 2026-08-06 — smell
**Where:** commits `5829f06` and `7d5f060` (`Webgpu-Source:` trailers)
**Found while:** phase 6 audit, workstream A4 — provenance spot-check
**What:** Two `port` commits cite fork SHAs that touch **none** of the files the commit changes,
which defeats the purpose of the trailer — `.claude/rules/port-provenance.md` exists so the next
rebase-forward can trace any line to its source.
- `5829f06` (`port(ci): add the WebGPU web template jobs`) changes `.github/workflows/web_builds.yml`
  but cites `69a9b2f`, which touches `SConstruct`, `drivers/SCsub` and `drivers/webgpu/`.
- `7d5f060` (`port(clean): apply 11 conflict-free fork modifications`) changes HTML/JS/shader files
  but cites `f329e39`, which vendored the naga-converter machinery.

16 of the 17 port commits carry both trailers correctly; the 17th (`1c9e8e4`) omits `Webgpu-Source`
legitimately, being hogdot-authored adaptation rather than carried fork code.
**Disposition:** open — **Phase 7, size S.** History is never rewritten here (`conventions.md` § git
mechanics), so the repair is a forward-only correction note recording the right SHAs for both paths,
found with `git log --oneline 4.6.2-stable..webgpu/webgpu-4.6.2 -- <path>`.

### RL-033 — 2026-08-06 — bug
**Where:** `drivers/webgpu/spirv_preprocess.cpp` — the `is_literal` lambda in
`flatten_binding_arrays()`'s rewrite loop, `switch_alternating` branch
**Found while:** phase 7, implementing RL-030's table
**What:** The OpSwitch predicate was **off by one**. `OpSwitch` is
`<id selector> <id default>` followed by (literal, label) pairs, so its literals sit at words
3, 5, 7, …; the code tested `p_i >= 2 && ((p_i - 2) % 2 == 0)`, i.e. 2, 4, 6, …. Both halves are
wrong: word 2 (the default **label id**) was frozen as a literal, and every **case literal** was
treated as an id and therefore left rewritable — which is precisely the RL-028 defect, still live
inside RL-028's own fix. The frozen half is harmless (label ids are never in this pass's maps); the
rewritable half is not.
⚠ **The phase-6 audit examined this predicate and passed it** ("`OpSwitch`'s alternating
literal/label operands are handled by a separate, correct predicate", RL-030). That is a reminder
that an audit finding of *correct* is only as good as the spec it was checked against — this one was
checked by reading, not against the grammar.
**Disposition:** **fixed-in `845c61e`** — predicate corrected to `p_i >= 3 && ((p_i - 3) % 2 == 0)`.
⚠ A 64-bit switch selector would make each case literal **two** words wide and break the alternation
again; Godot has none and glslang does not emit them for GLSL, and that assumption is now recorded in
the code.

### RL-034 — 2026-08-06 — bug (latent)
**Where:** `drivers/webgpu/spirv_preprocess.cpp:88-91` — `OP_COPY_MEMORY`, `OP_COPY_MEMORY_SIZED`,
`OP_IN_BOUNDS_PTR_ACCESS_CHAIN`
**Found while:** phase 7, cross-checking opcode numbers against `spirv.hpp11` for RL-030
**What:** Three opcode constants named the wrong instruction. `OP_COPY_MEMORY` was **38**, which is
`OpTypePipe`; `OP_COPY_MEMORY_SIZED` was **39**, which is `OpTypeForwardPointer`; the real values are
63 and 64. `OP_IN_BOUNDS_PTR_ACCESS_CHAIN` was **216** instead of **70**. All three are consumed by
`infer_readonly_storage`'s write-detection switch, so a storage buffer written *only* through
`OpCopyMemory`/`OpCopyMemorySized` or reached through an in-bounds pointer access chain would not be
recorded as written and could be narrowed to `read`. The wrong constants also made the switch match
`OpTypePipe`/`OpTypeForwardPointer` instead, whose word 1 is a type id — a no-op insertion into
`written_vars`, so no false positive either.
Latent rather than live: glslang emits none of these three forms for Vulkan GLSL (aggregate assignment
becomes `OpStore`/`OpCopyLogical`, and `OpPtrAccessChain` needs `VariablePointers`). It also fails
**loudly** — Tint rejects a write to a `read` storage buffer — rather than silently.
**Disposition:** **fixed-in `845c61e`** — corrected to 63, 64 and 70.

### RL-035 — 2026-08-06 — smell
**Where:** `servers/rendering/renderer_rd/forward_clustered/scene_forward_clustered.glsl` /
`scene_shader_forward_clustered.cpp:904` (`actions.base_varying_index = 15`)
**Found while:** phase 7, fixing RL-029 on the mobile renderer
**What:** Forward+ carries the same flat 15-location reservation and the same gaps that RL-029 fixed
on Mobile, so a Forward+ user shader on WebGPU has the same one-slot ceiling. It was deliberately
**not** repacked in `dc917d5`: CommonGrounds targets Mobile, Forward+ on web is separately blocked by
Tint's unimplemented `HelperInvocation` in the SPIR-V reader (RL-029), and repacking a second scene
shader doubles the blast radius of a change whose safety argument rests on per-variant
mutual-exclusion analysis. Recorded so the omission is a decision rather than an oversight.
**Disposition:** deferred — do it when Forward+ on web becomes reachable, i.e. alongside a Tint
`HelperInvocation` patch. The mobile repack in `dc917d5` is the worked example to copy.
