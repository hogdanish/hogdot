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

**Status (2026-08-06, end of phase 7):** **all eight slices are landed** — every one of the 39
conflicts is dispositioned (37 carry fork content; 2 are recorded deliberate drops), plus all 1,447
additive files, all 13 clean mods and the one collision. `pre-commit run --all-files` passes.
`webgpu_tests/test_project` **renders in Chrome on WebGPU with zero GPU validation errors**, and
CommonGrounds boots. The phase-6 fidelity audit re-derived every carried hunk (157 across the first
seven slices) against the fork and found **zero unrecorded adaptations or drops**. Mainline 4.7.1
still contains zero WebGPU references of its own; the entire backend arrives from the fork.

⚠ **`port-surface.sh` never reports "zero conflicts" and is not a progress meter** — it derives the
fork-vs-mainline delta, which is invariant to how much has landed. The per-file check that actually
answers "did we carry it" is in `references/slice-log.md` § *slice 8*.

⚠ **The gate scenes only exercise the engine's own shaders.** Phase 7's CommonGrounds acceptance run
found three blockers in an hour (RL-036/037/038) that phases 4–6 could not have reached, because
`webgpu_tests/test_project` contains no `RDShaderFile`, no `stencil_mode` material and no direct
`RenderingDevice` use from script. Adding those is queued work.

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

**Measured 2026-08-20 against `4.7.2-stable`:** 1,447 additive · 1 collision
(`thirdparty/spirv-headers/include/spirv/unified1/spirv.hpp11`, which mainline grew its own copy of) ·
13 clean · **39 conflicts** · 0 deletions.

⚠ **The collision is resolved in the fork's favor** (`ef55f41`, Phase 2). Phase 1 kept mainline's copy
and was wrong: the fork's is the newer SPIRV-Headers drop, and the vendored SPIRV-Tools does not
compile against mainline's. ⚠ **Decide a collision with a set-difference over identifiers, not with
line counts or tree recency** — `comm -23` of the two files' enumerator names showed 43 additions and
**zero removals**, which is what made the swap safe for mainline's glslang. ⚠ And note *when* it
surfaced: mainline's copy built the macOS editor and the vanilla web template happily through all of
Phase 1, because SPIRV-Tools is only ever compiled under `webgpu=yes`.

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
| 4 | **shaders** | 7 conflicting `.glsl` + the 13 clean ones | `scene_forward_mobile.glsl` is the substantive one (+50/−34). |
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

## The `WorkerThreadPool` export deadlock — no candidate to backport (checked 2026-09-01)

CommonGrounds' headless web export intermittently deadlocks in `WorkerThreadPool` during
`savepack` (their audit WEB-01: 19 threads, none running, main thread on a condvar inside a
~30-frame export stack while `WorkerThread 0/1` block in `pthread_mutex_lock`). **Upstream has no
fix for hogdot to take.** Re-verified against current sources; do not re-derive this from scratch.

- Upstream's own fix for exactly this shape is **`ae564feb2a`** (PR
  [#120072](https://github.com/godotengine/godot/pull/120072), 2026-06-07) — *"Fix a deadlock in
  `WorkerThreadPool`"*. Its message describes this stall verbatim: while the main thread waits in
  `wait_for_group_task_completion()` the `MessageQueue` stops being serviced, and
  `ResourceLoader::_load_complete_inner` needs to push a callable onto it and wait, which can then
  never complete. It patched both wait functions to flush the queue while spinning on `try_wait()`.
- ⚠ **It was reverted** by `b527505338` (PR
  [#120250](https://github.com/godotengine/godot/pull/120250), 2026-06-12) — together with
  `7ab8328204` — for regressions in 4.7.rc2 (node-path error spam
  [#120223](https://github.com/godotengine/godot/issues/120223), texture load corruption
  [#120228](https://github.com/godotengine/godot/issues/120228)). hpvb: *"a better approach is
  needed. For 4.7 we should drop this one."* All three commits are ancestors of `main`, so the fork
  carries the reverted (unfixed) state deliberately and correctly. **Do not re-apply `ae564feb2a`**
  — it is a known-broken patch, not an available fix.
- The four 4.7-cycle `ResourceLoader` threading fixes (`f63ab5fbd9`, `374102cfbe`, `b88a62f805`,
  `8cf4c5d9b2`) are **all already ancestors of `main`**; `resource_loader.cpp` carries
  `b88a62f805`'s `thread_waiting_on` cycle detection in-tree.
- `git log 4.7.2-stable..upstream/4.7` touches `worker_thread_pool.{cpp,h}`,
  `resource_loader.{cpp,h}` and `editor_export_platform.{cpp,h}` **zero times**;
  `..upstream/master` (to 2026-08-31) carries only style and argument-plumbing commits
  (`1c45c14d7f`, `a3088fecf1`, `06a7feabc8`, `7bcda31d0f`, `00120405f4`). There is no re-land of
  #120072 and no open upstream PR for it.
- ⚠ **No open upstream issue tracks the deadlock the revert left behind.** The revert closed the
  regressions it caused and nothing tracks the original. A report carrying CommonGrounds'
  19-thread dump would be the first concrete reproduction since it was called "rare" — worth
  filing once the symbolized stack exists.
- Two fork-local suspects were checked and **both rule themselves out**: `main`'s 16-line local
  change to `worker_thread_pool.cpp` (from `57be40c524`) sits entirely inside the `#else` of
  `#ifdef THREADS_ENABLED`, so it is not compiled into a threaded linuxbsd editor; and
  `shader_baker_export_plugin.cpp` calls `wait_for_task_completion` from the main thread during
  export — structurally the exact hazard — but its `_is_active()` returns `false` with no
  RendererRD driver running, and a `--headless` export has none, so it queues no tasks in CI.
  ⚠ **That second one becomes live in a GUI-editor export**, and is the first place to look if the
  stall ever appears outside headless CI.
- ⚠ **No speculative tuning.** Worker counts, retry counts and kill points are not levers here and
  changing them is forbidden — the containment lives in the consumer's watchdog, and the next step
  is a symbolized stack from a real stall (which is what the debug-symbol sidecar exists for —
  **`build-export`**).

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
