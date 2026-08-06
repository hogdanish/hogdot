---
name: engine
description: Mainline Godot 4.7.1 internals that hogdot's port touches — the RenderingDevice and RenderingDeviceDriver contract, the renderer_rd storage layer (texture/mesh/light), forward-mobile rendering and the compositor, and how a rendering driver is registered and selected.
when_to_use: Load when a port hunk needs the mainline side understood — what a RenderingDeviceDriver method is expected to do, how storage_rd owns a resource, where the forward-mobile pass boundaries are, how driver selection works. Boundary — this is upstream 4.7.1 as it ships; the WebGPU backend is godotwebgpu, slice sequencing is port, and class-level API lookup is the docs skill.
user-invocable: false
---

# Mainline engine internals hogdot touches

⚠ **This skill is a scaffold.** It exists so the knowledge has a home the moment the RD-core slice starts;
it is **not yet authored**. Fill each section from the codebase as that slice lands — the `FILL:` markers
say what to derive and from where. Do not fill it speculatively, and do not copy the fork's 4.6.2-era
descriptions into it (`godotwebgpu/references/index.md` explains why those drift).

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

FILL: what `RenderingDeviceDriver` (in `servers/rendering/rendering_device_driver.h`) actually requires in
4.7.1 — the pure-virtual set, the object-handle convention (`ID` opaque pointers), and which methods have
default implementations a backend may skip. This is the single most important section; the fork adds
+134 lines to this header and everything downstream depends on the shape it settles.

## RenderingDevice ↔ driver split

FILL: which responsibilities sit in `rendering_device.cpp` versus the driver, and what
`rendering_device_graph.cpp` does with barriers and pass ordering. ⚠ Relevant because the WebGPU driver
makes every barrier a no-op — establish what mainline expects a barrier to *mean* before deciding that is
safe under 4.7.1.

## storage_rd

FILL: how `texture_storage` / `mesh_storage` / `light_storage` own GPU resources and hand them to the
driver. ⚠ `texture_storage.cpp` moved +824/−80 upstream since 4.6.2 — the largest single divergence in
the port, so this section earns its keep.

## Forward-mobile and pass structure

FILL: the render pass and subpass structure of `render_forward_mobile.cpp`. ⚠ This is where WebGPU's
absence of subpasses bites hardest (the fork flattens each subpass into its own render pass) — document
what mainline's structure *is* before reasoning about the flattening.

## Driver registration and selection

FILL: how a rendering driver is registered and chosen — `main/main.cpp`, `servers/display/display_server.cpp`,
and the `rendering/rendering_device/driver.*` project settings. Short section; mostly a call-order trace.

---
*Source of truth for mainline internals hogdot depends on — fill and update it as each port slice lands.*
