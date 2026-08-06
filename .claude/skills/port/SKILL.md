---
name: port
description: The strategy for carrying GodotWebGPU onto the mainline Godot release hogdot tracks — how the port surface is derived with hogdot/port-surface.sh and refs.env, the hybrid bulk-apply-plus-hand-port decision and why a rebase was rejected, the slice order across the 39 conflicting files, and the per-slice findings log.
when_to_use: Load before starting, resuming or sequencing any porting work, when deciding which slice comes next, when a hunk will not apply because mainline moved underneath it, or when rebasing hogdot forward onto a newer Godot release. Boundary — this is sequencing and integration; how the WebGPU backend works is the godotwebgpu skill, commit-message provenance is the port-provenance rule, and compiling the result is build-export.
user-invocable: false
---

# The port — carrying GodotWebGPU onto mainline

hogdot exists to run [GodotWebGPU](https://github.com/dwalter/godotwebgpu)'s WebGPU backend on a current
mainline Godot. That is a **recurring** exercise, once per mainline release, which is why nothing about the
port surface is written down as data — it is derived on demand.

⚠ **Status: nothing is ported yet.** `main` is upstream `4.7.1-stable` plus `hogdot/` and `.claude/`.
Mainline 4.7.1 contains zero WebGPU references; the entire backend arrives from the fork.

## Deriving the surface — never reconstruct it by hand

```bash
./hogdot/port-surface.sh --all          # or --summary --conflicts --clean --additive --collisions
```

It classifies every file the fork touches in about a second against whatever `hogdot/refs.env` pins.
**Trust it over any number written anywhere, including here.** Do not rebuild its answer with `find`,
`git status`, or by opening directories.

The three refs it depends on live in `hogdot/refs.env` — bump `HOGDOT_UPSTREAM_BASE` there, and nowhere
else, to move onto a newer Godot. Its invariant is that `HOGDOT_WEBGPU_FORK_POINT` is the exact merge-base
of the fork and mainline, which is what makes `git diff FORK_POINT WEBGPU_REF` the complete, unambiguous
WebGPU delta. `--no-renames` is deliberate — with rename detection on, a file mainline renamed would drop
silently out of the conflict set.

**Measured 2026-08-06 against `4.7.1-stable`:** 1,447 additive · 1 collision
(`thirdparty/spirv-headers/include/spirv/unified1/spirv.hpp11`, which mainline grew its own copy of) ·
13 clean · **39 conflicts** · 0 deletions.

**1,500 files sounds daunting and isn't.** 1,221 of the additions are vendored third-party drops
(`thirdparty/tint` 824, `thirdparty/spirv-tools` 389, `thirdparty/spirv-headers` 8). The fork's own
hand-written engine code is **26 files in `drivers/webgpu/`** (17,095 lines) plus those 39 conflicts.

## Strategy — hybrid, decided 2026-08-06

Bulk-apply what cannot conflict; hand-port what can, in themed commits.

⚠ **A straight `git rebase --onto` was rejected and should stay rejected.** Replaying the fork's 165
commits across 3,444 commits of upstream churn re-resolves the *same* heavily-churned files dozens of
times, and buys nothing `git log 4.6.2-stable..webgpu/webgpu-4.6.2` doesn't already preserve. Those 165
commits are never rewritten and never lost — read them for the *why* behind any hunk; their messages are
unusually good.

1. **Vendored thirdparty** — one mechanical import commit per tree (Tint, SPIRV-Tools, SPIRV-Headers).
   Dawn/Khronos drops the fork patched lightly (6 documented Tint patches). Vendor imports, not code to
   review. ⚠ Never `Read` these trees (`rules/context-scale.md`).
2. **`drivers/webgpu/`** — additive, lands in one commit, then gets fixed up against 4.7.1's
   `RenderingDeviceDriver` API.
3. **The 39 conflicts**, grouped by seam, in the order below.

## Slice order

⚠ **Start at the RD core.** Everything downstream depends on the driver-API shape it settles, and it is
also the highest-risk pair — mainline moved `rendering_device.cpp` by +1628/−96 under a fork change of
+397/−26. Re-check exact churn with `./hogdot/port-surface.sh --conflicts`; the figures below are
2026-08-06 and will drift.

| # | Slice | Files | Notes |
| --- | --- | --- | --- |
| 1 | **RD core** | `rendering_device.cpp/.h`, `rendering_device_driver.h`, `rendering_device_graph.cpp/.h` | Settles the driver API for everything after. Heaviest churn on both sides. |
| 2 | **storage_rd** | `texture_storage.cpp`, `mesh_storage.cpp/.h`, `light_storage.cpp/.h` | ⚠ `texture_storage.cpp` moved +824/−80 upstream; `light_storage.cpp` +352/−140. |
| 3 | **forward_mobile + compositor** | `render_forward_mobile.cpp/.h`, `renderer_canvas_render_rd.cpp`, `renderer_compositor_rd.cpp`, `renderer_viewport.cpp`, `effects/tone_mapper.cpp` | Where subpass flattening bites. Largest fork-side change (+221/−18). |
| 4 | **shaders** | 8 conflicting `.glsl` + the 13 clean ones | `scene_forward_mobile.glsl` is the substantive one (+50/−34). |
| 5 | **platform/web** | `detect.py`, `display_server_web.cpp/.h`, `emscripten_helpers.py`, `export/export_plugin.cpp`, `js/engine/*.js` | ⚠ First slice that needs Emscripten to verify. |
| 6 | **build** | `SConstruct` (declares `webgpu=yes`), `drivers/SCsub`, `modules/glslang/config.py`, `.github/workflows/web_builds.yml` | Small diffs, high blast radius. |

⚠ **Sequencing refinement (2026-08-06, planning):** a minimal subset of slices 5–6 — SConstruct's
`webgpu` option, `drivers/SCsub`, and `detect.py`'s WebGPU-flag hunks — lands **first, alongside the
RD-core slice**, so `scons platform=web webgpu=yes` can compile `drivers/webgpu/` and the compiler
referees the driver adaptation. Without it, nothing in `drivers/webgpu/` compiles until slice 6 and
errors surface two phases late. The rest of slices 5–6 stays in place. The phase-by-phase execution
plan built on this table is `.claude/work/plans/ROADMAP.md` — enter every port session through it.
| 7 | **core/scene odds** | `main.cpp`, `core/object/worker_thread_pool.cpp`, `servers/display/display_server.cpp`, `scene/resources/2d/tile_set.cpp`, `scene/resources/compressed_texture.cpp` | Mostly one-liners under enormous upstream churn. |
| 8 | **meta** | `README.md`, `thirdparty/README.md`, `.gitignore`, `.gitattributes` | Last. Pure bookkeeping. |

## Judgment calls that recur

- ⚠ **The fork bundles unrelated refactors.** `platform/web/detect.py` turns `use_assertions` from a
  `BoolVariable` into a 4-state string option — nothing to do with WebGPU. **Check whether 4.7.1 already
  did the equivalent before porting such a hunk, and do not import churn hogdot does not need.**
- ⚠ **Adapted ≠ copied.** When mainline moved underneath a hunk, say so in the commit body — what the fork
  did, what 4.7.1 changed, why your version differs. That paragraph cannot be reconstructed later.
- ⚠ **Never silently drop a hunk.** Record every deliberate omission in the commit body *and* in the slice
  log. A dropped hunk with no record is indistinguishable from an oversight forever after.
- Commit trailers (`Webgpu-Port:` / `Webgpu-Source:`) are mandatory and specified in
  `.claude/rules/port-provenance.md` — that rule is always-on law and is not restated here.
- Find the source SHAs for any path with
  `git log --oneline 4.6.2-stable..webgpu/webgpu-4.6.2 -- <path>`.

## Reference material

- [slice-log.md](references/slice-log.md) — **living, append-only.** One entry per slice as it lands, with
  what was adapted, what was dropped and why, and every gotcha found. Add to it in the same change as the
  port commit; this is where the next rebase-forward gets its shortcuts.
- [review-ledger.md](references/review-ledger.md) — **living, append-only.** Every hunk carried from the
  fork is read critically; findings (bugs, perf, smells the author missed) land here. **Default
  disposition: flag and port faithfully — fix now only for 4.7.1 blockers or trivial bugs, always as a
  separate commit citing the ledger ID.** The ledger holds the judgment; the slice log holds what was
  done about it.

---
*Source of truth for port sequencing and integration — update it in the same change as any port commit.*
