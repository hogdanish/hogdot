# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**This file is the router/glossary.** `.claude/rules/` are always-on law; `.claude/skills/` will hold the source of truth per subsystem (none exist yet — see _Skills, deliberately absent_); `.claude/work/` is gitignored scratch (plans, specs, notes — **never `docs/`**). When a line here disagrees with a skill, the skill wins — fix both in the same change. General framework doctrine is the global `context-architecture` rule and is **not** restated here; only project deltas live in this repo.

## What this repository is

**hogdot** — Ethan's self-maintained fork of the Godot Engine, existing for exactly one purpose: to carry [GodotWebGPU](https://github.com/dwalter/godotwebgpu)'s WebGPU rendering backend on top of a current mainline Godot release. Its sole consumer is **`/Users/ethan/Projects/commongrounds`** (in-browser multiplayer game; Mobile renderer, web export, wants compute shaders). Read access to that repo is granted in `.claude/settings.json`.

- **Current base**: `4.7.1-stable` · **WebGPU source**: `webgpu/webgpu-4.6.2`, which forked mainline at `4.6.2-stable` and is 165 linear commits ahead with **zero merge commits**.
- ⚠ **Status: nothing is ported yet.** `main` is upstream `4.7.1-stable` plus `hogdot/` and `.claude/`, nothing else. Mainline 4.7.1 contains **zero** WebGPU references (`grep -rn webgpu platform/web/ SConstruct` is empty) — the entire backend arrives from the fork.
- This is a **long-term** fork: every future mainline release repeats the same rebase-forward exercise. That is why the port surface below is _derived by a script_ rather than written down — a checked-in ledger would rot within one release.

## Git architecture (read before any git operation)

| Remote     | Points at                                          | Push                                     |
| ---------- | -------------------------------------------------- | ---------------------------------------- |
| `origin`   | `hogdanish/hogdot` — GitHub fork of godotengine/godot | ours                                     |
| `upstream` | `godotengine/godot`                                | **disabled** (push URL set to a stub)    |
| `webgpu`   | `dwalter/godotwebgpu`                              | **disabled** (push URL set to a stub)    |

- **`main` is the trunk**, based at `4.7.1-stable`. There is deliberately no local `master` — it was deleted so it can never be confused with upstream's.
- The 165 original WebGPU commits are **never rewritten and never lost**: `git log 4.6.2-stable..webgpu/webgpu-4.6.2`. Read them for the _why_ behind any hunk you port; their messages are unusually good.
- The three refs every derivation depends on live in **`hogdot/refs.env`**. Bump `HOGDOT_UPSTREAM_BASE` there — and nowhere else — when moving onto a newer Godot.
- ⚠ `webgpu` is fetched with `--no-tags` on purpose: GodotWebGPU carries Godot's own tags, and letting them in would silently clobber the local `4.6.2-stable` / `4.7.1-stable` that all the port math is measured against.

## The port (the actual work)

Run **`./hogdot/port-surface.sh --all`**. It classifies every file the fork touches in about a second, against whatever `refs.env` currently pins. Trust it over any number written down, including the ones below.

Measured 2026-08-06 against `4.7.1-stable`:

| Class          | Files | Meaning                                                                    |
| -------------- | ----: | -------------------------------------------------------------------------- |
| additive       | 1,447 | paths mainline lacks — apply wholesale, no judgement needed                 |
| collision      |     1 | `thirdparty/spirv-headers/include/spirv/unified1/spirv.hpp11` — mainline grew its own copy; pick a winner |
| clean          |    13 | fork-modified, mainline untouched since 4.6.2 — applies as-is               |
| **conflict**   |**39** | **fork-modified AND mainline-changed — the entire real integration surface** |
| deletion       |     0 |                                                                             |

**1,500 files sounds daunting and isn't.** 1,221 of the additions are vendored third-party drops (`thirdparty/tint` 824, `thirdparty/spirv-tools` 389, `thirdparty/spirv-headers` 8); the fork's own hand-written engine code is **26 files in `drivers/webgpu/`** plus those 39 conflicts. Verified 2026-08-06: no fork-modified file was renamed or removed upstream, so the set intersection the script performs is sound.

### Strategy — hybrid, decided 2026-08-06

Bulk-apply what cannot conflict; hand-port what can, in themed commits. A straight `git rebase --onto` was rejected: replaying 165 commits across 3,444 commits of upstream churn re-resolves the _same_ heavily-churned files dozens of times, and buys nothing that `git log webgpu/webgpu-4.6.2` doesn't already preserve.

1. **Vendored thirdparty** — one mechanical import commit per tree. These are Dawn/Khronos drops the fork patched lightly (6 documented Tint patches); treat them as vendor imports, not code to review.
2. **`drivers/webgpu/`** — additive, lands in one commit, then gets fixed up against 4.7.1's `RenderingDeviceDriver` API. `rendering_device_driver_webgpu.cpp` alone is 360 KB.
3. **The 39 conflicts**, grouped by seam — suggested order, shallowest dependency last:
   - **RD core** — `rendering_device.cpp/.h`, `rendering_device_driver.h`, `rendering_device_graph.cpp/.h`
   - **storage_rd** — `texture_storage.cpp`, `mesh_storage.cpp/.h`, `light_storage.cpp/.h`
   - **forward_mobile + compositor** — `render_forward_mobile.cpp/.h`, `renderer_canvas_render_rd.cpp`, `renderer_compositor_rd.cpp`, `renderer_viewport.cpp`, `effects/tone_mapper.cpp`
   - **shaders** — 8 conflicting `.glsl` + the 13 clean ones
   - **platform/web** — `detect.py`, `display_server_web.cpp/.h`, `emscripten_helpers.py`, `export/export_plugin.cpp`, `js/engine/*.js`
   - **build** — `SConstruct` (declares `webgpu=yes`), `drivers/SCsub` (dispatches to `webgpu/SCsub`), `modules/glslang/config.py`, `.github/workflows/web_builds.yml`
   - **core/scene odds** — `main.cpp`, `core/object/worker_thread_pool.cpp`, `servers/display/display_server.cpp`, `scene/resources/2d/tile_set.cpp`, `scene/resources/compressed_texture.cpp`
   - **meta** — `README.md`, `thirdparty/README.md`, `.gitignore`, `.gitattributes`

⚠ **Start at the RD core** — everything downstream depends on the driver API shape it settles. It is also the highest-risk pair: mainline moved `rendering_device.cpp` by +1628/−96 under a fork change of +397/−26, and `texture_storage.cpp` by +824/−80. Re-check exact churn with `./hogdot/port-surface.sh --conflicts`.

⚠ The fork bundles **unrelated refactors** with WebGPU work — e.g. `platform/web/detect.py` turns `use_assertions` from a `BoolVariable` into a 4-state string option. Check whether 4.7.1 already did the equivalent before porting such a hunk; do not import churn hogdot does not need.

## Building

⚠ **No build has been run in this repo yet — every command below is upstream/fork-documented, not yet verified here.** Correct them in place the first time you run one, and load the (future) `build-export` skill once it exists.

```bash
# macOS editor — the binary CommonGrounds opens. Cold build is tens of minutes.
scons platform=macos target=editor arch=arm64 -j"$(sysctl -n hw.ncpu)"
# -> bin/godot.macos.editor.arm64

# web export template, mainline (no WebGPU until the port lands)
scons platform=web target=template_release

# web export template WITH WebGPU — only meaningful after the port
scons platform=web target=template_release dlink_enabled=yes webgpu=yes opengl3=no threads=no

# unit tests: build them in, then run the suite
scons platform=macos target=editor arch=arm64 tests=yes && bin/godot.macos.editor.arm64 --test

# lint — Godot's own pre-commit set (clang-format, clang-tidy, ruff, mypy, codespell, …)
# ⚠ NOT runnable yet: neither `pre-commit` nor `clang-format` is installed on this machine.
pre-commit run --all-files          # or: pre-commit run <hook-id> --files <path>
```

- ⚠ **Emscripten is not installed on this machine.** No web target can build until it is. Homebrew ships **6.0.5**; mainline 4.7.1 requires ≥ 4.0.0 (`platform/web/detect.py`), and GodotWebGPU was developed against **4.0.10+** for the `emdawnwebgpu` port. That is a major-version gap across a port whose API the fork depends on — treat a clean web build on 6.x as unproven until measured, and suspect the toolchain before the port when web-only breakage appears.
- ⚠ **`ccache` is not installed either.** For a fork you will rebuild after every ported hunk, it is the single highest-leverage install here; Godot's SConstruct picks it up automatically.
- Godot's `webgpu=yes` is a `BoolVariable` in `SConstruct` gated by each platform's `supported` list — `platform/web/detect.py` adds `"supported": ["webgpu"]`. Both edits are in the 39.

## Skills, deliberately absent

`.claude/skills/` is empty by design — skills are the next session's work. Expected set, each owning one scope with `references/` depth:

- **`port`** — the strategy above as the source of truth: derivation, slice order, provenance, per-seam gotchas found while porting.
- **`godotwebgpu`** — how the fork's backend actually works: the driver, `spirv_preprocess.cpp`'s 11+1 SPIR-V passes, the Tint SPIR-V→WGSL pipeline, `wgsl_precompile.py`, browser-specific workarounds. `webgpu_notes/` and `webgpu_site/*.md` arrive with the port and are the raw material.
- **`engine`** — mainline Godot internals hogdot touches: `RenderingDevice`/`RenderingDeviceDriver`, `storage_rd`, forward-mobile.
- **`build-export`** — compiling the editor and export templates and getting them into CommonGrounds. Correct the Building section above when it is written.

Author them with `skill-creator`; placement doctrine is the global `context-architecture` rule.

## Keep it current

- A change to a scope updates its owning skill **in the same change**; a new scope gets a new skill plus one glossary line here.
- ⚠ **Numbers in this file are measurements with a date.** When a re-measurement disagrees, the script wins — update the table and its date, never quietly leave both.
- Never grow this file past ~200 lines; it routes, skills hold depth. Cut cruft on sight.
