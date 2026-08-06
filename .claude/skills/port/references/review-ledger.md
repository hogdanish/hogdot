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
**Disposition:** deferred — carried faithfully; it is not a 4.7.1 blocker and the honest fix (a free
list keyed by slot size, or a compacting rebuild when waste exceeds a threshold) is well past the
"trivial, obviously correct" bar. Revisit in Phase 5 alongside RL-012, which shares the same
function.

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
**Disposition:** deferred — carried faithfully. The fix is small and obvious in isolation (upload
`[0, skeleton_atlas_used)` immediately after creating the new buffer), but it changes runtime
behavior on a path no test exercises yet, and the port's audit trail depends on ported code matching
its cited source. **Fix in Phase 5, as a separate commit citing this ID**, once a browser run can
demonstrate the before/after.

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
**Disposition:** deferred — this is inherited mainline code, not a carried hunk, so there is nothing
to port faithfully; it is a **new gap the rebase-forward created**. Chase it in Phase 5 with the
other Tint translation failures, applying the same two substitutions the fork already established.
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
