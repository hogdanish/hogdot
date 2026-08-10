---
name: engine
description: Mainline Godot 4.7.1 internals that hogdot's port touches — the RenderingDevice and RenderingDeviceDriver contract, the renderer_rd storage layer (texture/mesh/light), forward-mobile rendering and the compositor, and how a rendering driver is registered and selected.
when_to_use: Load when a port hunk needs the mainline side understood — what a RenderingDeviceDriver method is expected to do, how storage_rd owns a resource, where the forward-mobile pass boundaries are, how driver selection works. Boundary — this is upstream 4.7.1 as it ships; the WebGPU backend is godotwebgpu, slice sequencing is port, and class-level API lookup is the docs skill.
user-invocable: false
---

# Mainline engine internals hogdot touches

⚠ **This skill is still being filled.** Sections marked `FILL:` are not yet authored; the bullets under
them are what porting has actually established, and are trustworthy. Add to each section as the slice
that touches it lands — never speculatively, and never by copying the fork's 4.6.2-era descriptions
(`godotwebgpu/references/index.md` explains why those drift). As of 2026-08-06 (Phase 3 complete) the
`ApiTrait` mechanism, storage_rd and forward-mobile bullets are written; the pure-virtual set, the
RD↔driver split, and driver registration are not.

⚠ **The `docs` skill comes first for anything class-level.** `doc/classes/RenderingDevice.xml` is 215 KB
of in-tree, exactly-this-version reference. Don't re-document what it already states — this skill is for
the *C++ internals* the XML doesn't cover.

## Scope — the files, straight off the conflict list

These are the mainline files GodotWebGPU modifies *and* 4.7.1 moved. Re-derive with
`./hogdot/port-surface.sh --conflicts`.

| Seam | Files |
| --- | --- |
| RD core | `servers/rendering/rendering_device.cpp/.h`, `rendering_device_driver.h`, `rendering_device_graph.cpp/.h` |
| storage_rd | `servers/rendering/renderer_rd/storage_rd/{texture,mesh,light}_storage.cpp/.h` |
| forward-mobile | `servers/rendering/renderer_rd/forward_mobile/render_forward_mobile.cpp/.h` |
| compositor / viewport | `renderer_canvas_render_rd.cpp`, `renderer_compositor_rd.cpp`, `renderer_viewport.cpp`, `effects/tone_mapper.cpp` |
| registration | `main/main.cpp`, `servers/display/display_server.cpp` |

## The driver contract

FILL: the pure-virtual set, the object-handle convention (`ID` opaque pointers), and which methods have
default implementations a backend may skip. This is the single most important section; the fork adds
+134 lines to this header and everything downstream depends on the shape it settles.

**`ApiTrait` — the capability-query mechanism, and its one trap.** A backend advertises optional
behavior by overriding `api_trait_get(ApiTrait)`; callers read it through thin
`RenderingDevice::supports_*()` wrappers. Every native driver's override ends in
`default: return RenderingDeviceDriver::api_trait_get(p_trait)`, and that base implementation's own
`default:` is **`ERR_FAIL_V(0)`** (`rendering_device_driver.cpp`).

⚠ **Adding an `ApiTrait` enumerator is therefore a two-file change**: the enum in
`rendering_device_driver.h` *and* a canonical default case in `rendering_device_driver.cpp`. Omit the
second and the value is still correct (0), but every query from a native backend prints
`ERROR: Method/function failed. Returning: 0`. ⚠ **No cheap verification tier catches this** — it
compiles, links, and passes a headless boot, because headless runs the **dummy** driver and never
queries these traits. It took a windowed native run to surface 189 of them (ledger RL-016,
fixed in `4dc5bbb`). `ApiTrait` is never serialized and is only used symbolically, so appending new
enumerators after mainline's is safe and renumbering is a non-issue.

## RenderingDevice ↔ driver split

FILL: which responsibilities sit in `rendering_device.cpp` versus the driver, and what
`rendering_device_graph.cpp` does with barriers and pass ordering. ⚠ Relevant because the WebGPU driver
makes every barrier a no-op — establish what mainline expects a barrier to *mean* before deciding that is
safe under 4.7.1.

## storage_rd

FILL: the general resource-ownership model. What the port established (2026-08-06, slice 2):

- **`LightStorage::light_omni_get_shadow_mode()` is the single choke point for omni shadow mode.**
  Everything downstream (atlas layout, pass count, `_render_shadow_pass`'s dual-paraboloid branch)
  follows from its return value, which is why the fork can force dual-paraboloid globally by
  short-circuiting this one function. Returns `RSE::LightOmniShadowMode` in 4.7.1.
- **`MeshStorage` skeletons: one storage buffer per skeleton, one uniform set per skeleton.**
  `skeleton_allocate_data()` creates `skeleton->buffer` + `uniform_set_mi`; `_update_dirty_skeletons()`
  walks an intrusive `skeleton_dirty_list` and issues one `buffer_update` each. ⚠ **`skeleton_free()`
  is `skeleton_allocate_data(p_rid, 0)`** — freeing is expressed as resizing to zero bones, so any
  allocation scheme added here must handle `p_bones == 0` as its release path. The fork's atlas does
  not, which is ledger RL-011.
- ⚠ **The skeleton compute shader's push constant is shared with `skeleton.glsl`.** The fork renames
  its `pad1` field to `bone_offset` on both sides. Mainline sets `pad1 = 0`, so the shader change is
  inert until `mesh_storage.cpp` lands — the two can be ported in separate commits, unlike the canvas
  binding pair below.
- **`TextureStorage::_validate_texture_format()` is where a `Image::Format` becomes an
  `RD::DataFormat` plus a swizzle.** Backends without component swizzle (WebGPU) must convert the
  pixel data instead, which is why the fork's L8/LA8 handling lives here and nowhere else.

## Forward-mobile and pass structure

FILL: the subpass structure proper. What the port established (2026-08-06, slice 3):

- **Shadow rendering is three phases, not one.** `_render_shadow_begin()` clears
  `scene_state.shadow_passes` → `_render_shadow_pass()` is called once per light/pass and *appends*
  to that list via `_render_shadow_append()` without touching the GPU → `_render_shadow_process()`
  fills the instance buffer → `_render_shadow_end()` is where every draw list is actually opened.
  ⚠ **That deferral is what makes the fork's pass-merging possible at all**: by `_render_shadow_end()`
  the whole frame's shadow work is a flat `LocalVector<ShadowPass>` that can be regrouped freely.
- **`ShadowPass` carries no light type.** It is `{element_from, element_count, flip_cull, pass_mode,
  rp_uniform_set, lod…, framebuffer, rect, clear_depth}` — deliberately light-agnostic. Anything that
  must treat one light type differently in `_render_shadow_end()` has to be *recorded* into the struct
  at append time; there is no way to recover it later. hogdot adds `mergeable` for exactly this
  (RL-010).
- ⚠ **`_render_shadow_append()` takes 18 parameters.** Do not add a 19th. Record the pass index range
  before calling it and post-process `scene_state.shadow_passes` after it returns.
- **Omni, spot and area lights all render into the same atlas framebuffer**
  (`light_storage->shadow_atlas_get_fb()`), each scoped to its own `atlas_rect`; only directional uses
  `direction_shadow_get_fb()`. Omni dual-paraboloid splits its rect in two across `p_pass` 0/1; area
  lights (new in 4.7.1) set `using_dual_paraboloid = true` without splitting.
- ⚠ **`instances.data[draw_call.instance_index]` in `scene_forward_mobile.glsl` is a contract with
  `_render_list_template()`, not a local detail.** Once instance batching is on, the correct index is
  `batch_instance_index` (`= draw_call.instance_index + gl_InstanceIndex` for non-multimesh). Every
  mainline addition that reads instance data direct from `draw_call.instance_index` is a latent
  mis-render — grep for it after every rebase-forward. See RL-014.
- ⚠ **`renderer_canvas_render_rd.cpp` and `shaders/canvas_uniforms_inc.glsl` are a matched pair.**
  The SET3 binding indices are duplicated between them with nothing to detect a mismatch but a runtime
  `uniform_set_create` failure that kills all 2D rendering, editor UI included. Change both or
  neither, in one commit.
- **Every area light sets `uses_softshadow`** — unconditional on light type at
  `renderer_scene_cull.cpp:1795`. An instance pairing any area light therefore carries
  `use_soft_shadow = true` into pipeline specialization and the batch predicate (phase 10; RL-046's
  exposure analysis rests on this).
- ⚠ **`VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME` is not draw calls on forward-mobile** — the
  renderer fills it with `instances->size()` (`render_forward_mobile.cpp:965`). Batching is
  invisible to it; nothing script-visible counts real draws.
- **Within a depth bucket the opaque render list runs in reverse creation order** (probe-verified
  2026-08-10 on WebGPU). The batch representative — whose pipeline specialization the whole merged
  draw uses — is whichever eligible instance that ordering lists first.

## Driver registration and selection

FILL: how a rendering driver is registered and chosen — `main/main.cpp`, `servers/display/display_server.cpp`,
and the `rendering/rendering_device/driver.*` project settings. Short section; mostly a call-order trace.

---
*Source of truth for mainline internals hogdot depends on — fill and update it as each port slice lands.*
