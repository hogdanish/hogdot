# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**This file is the router/glossary.** `.claude/rules/` are always-on law; `.claude/skills/` are the source of truth per scope; `.claude/work/` is gitignored scratch (plans, specs, notes — **never a `docs/` directory**; ⚠ `doc/` singular is upstream Godot's class reference and is a real part of the engine). When a line here disagrees with a skill, the skill wins — fix both in the same change. General framework doctrine is the global `context-architecture` rule and is **not** restated here; only project deltas live in this repo.

## What this repository is

**hogdot** — Ethan's self-maintained fork of the Godot Engine, existing for exactly one purpose: to carry [GodotWebGPU](https://github.com/dwalter/godotwebgpu)'s WebGPU rendering backend on top of a current mainline Godot release. Its sole consumer is **`/Users/ethan/Projects/commongrounds`** (in-browser multiplayer game; Mobile renderer, web export, wants compute shaders). Read access to that repo is granted in `.claude/settings.json`.

- **Current base**: `4.7.1-stable` · **WebGPU source**: `webgpu/webgpu-4.6.2`, which forked mainline at `4.6.2-stable` and is 165 linear commits ahead with **zero merge commits**.
- **Status (2026-08-06, end of phase 7):** **all 8 slices landed** — every one of the 39 conflicts is dispositioned (37 carry fork content, 2 are recorded deliberate drops). `pre-commit run --all-files` passes for the first time. `webgpu_tests/test_project` renders in Chrome with zero GPU validation errors, and **CommonGrounds boots on WebGPU**. ⚠ **That acceptance run found three blocking defects in an hour that no gate scene could reach** (RL-036/037/038, fixed in `2a68be7`) — the gate scenes exercise only the engine's own shaders, so `RDShaderFile`, `stencil_mode` materials and direct `RenderingDevice` use were all untested and all broken. ⚠ Rendering correctness has still never been judged against a native reference, no performance number exists, and there are open reports of severe stutter and frame pacing. See `.claude/work/plans/PORT-REPORT.md` and `COMMONGROUNDS-FINDINGS.md`.
- ⚠ **`./hogdot/port-surface.sh` derives the port surface; it does NOT measure progress** and will report 39 conflicts forever. The per-file "did we carry it" check is in the slice-8 slice-log entry.
- This is a **long-term** fork: every future mainline release repeats the same rebase-forward exercise. That is why the port surface is _derived by a script_ rather than written down — a checked-in ledger would rot within one release.

## Git architecture (read before any git operation)

| Remote     | Points at                                          | Push                                  |
| ---------- | -------------------------------------------------- | ------------------------------------- |
| `origin`   | `hogdanish/hogdot` — GitHub fork of godotengine/godot | ours                                  |
| `upstream` | `godotengine/godot`                                | **disabled** (push URL set to a stub) |
| `webgpu`   | `dwalter/godotwebgpu`                              | **disabled** (push URL set to a stub) |

- **`main` is the trunk**, based at `4.7.1-stable`. There is deliberately no local `master` — it was deleted so it can never be confused with upstream's.
- The 165 original WebGPU commits are **never rewritten and never lost**: `git log 4.6.2-stable..webgpu/webgpu-4.6.2`. Read them for the _why_ behind any hunk you port; their messages are unusually good.
- The three refs every derivation depends on live in **`hogdot/refs.env`**. Bump `HOGDOT_UPSTREAM_BASE` there — and nowhere else — when moving onto a newer Godot.
- ⚠ `webgpu` is fetched with `--no-tags` on purpose: GodotWebGPU carries Godot's own tags, and letting them in would silently clobber the local `4.6.2-stable` / `4.7.1-stable` that all the port math is measured against.

## The port, in one line

Run **`./hogdot/port-surface.sh --all`** — it classifies every file the fork touches in about a second and is the authority over any number written anywhere. Measured 2026-08-06 against `4.7.1-stable`: **1,447 additive · 1 collision · 13 clean · 39 conflicts · 0 deletions**, of which the 39 conflicts are the entire real integration surface. ⚠ **Start at the RD core.** Everything else — strategy, slice order, per-slice gotchas — is the **`port`** skill.

**The phase-by-phase execution plan is `.claude/work/plans/ROADMAP.md`** (authored 2026-08-06; gitignored scratch, like all of `.claude/work/`). Enter every port session through it — it routes to `STATUS.md` (where we are), `conventions.md` (session protocol, review directive, verification cadence) and the per-phase briefs.

## Skill map

| Skill | Owns |
| --- | --- |
| **`port`** | Sequencing and integrating the port — derivation, the hybrid strategy and why a rebase was rejected, the 8 slices in order, and `references/slice-log.md` (living, append-only). |
| **`godotwebgpu`** | How the WebGPU backend works — the driver, push-constant ring, subpass flattening, `spirv_preprocess.cpp` → Tint → WGSL, `wgsl_precompile.py`, the IPC optimizations. Owns the **50 imported fork documents** in `references/`, mapped by `references/index.md`. |
| **`engine`** | Mainline 4.7.1 internals the port touches — `RenderingDevice`/`RenderingDeviceDriver`, `storage_rd`, forward-mobile, driver registration. ⚠ **Scaffold — fill it as the RD-core slice lands.** |
| **`build-export`** | Compiling the editor and export templates, the ccache/pre-commit/Emscripten toolchain, lint gates, handing a build to CommonGrounds. |
| **`docs`** | Where facts come from — in-tree `doc/classes/` (810 XML files at exactly this version), Context7 for external libs, which upstream URLs are safe to cite. |
| **`claude-framework`** | The framework itself — the skill map, authoring mechanics, frontmatter, budgets, templates. |

Always-on rules (a shared cost — keep the set lean): **`context-scale`** (surviving a 14,000-file repo) · **`port-provenance`** (the commit trailers that keep the fork maintainable) · **`verification`** (nothing is proven by reading it).

## Toolchain

`scons` · `ccache` 4.13.6 · `pre-commit` 4.6.1 · `emcc` **6.0.x** (⚠ moves under you — 6.0.5 → 6.0.6-git within one day; ask `emcc --version`, never a doc) · `glslang` 16.5.0 (⚠ `webgpu=yes` only). All installed and verified 2026-08-06.

⚠ **`ccache` is NOT automatic** — SCons passes the compiler no environment, so it needs the launcher option *plus* exported `CCACHE_DIR`/`CCACHE_CONFIGPATH` *plus* `import_env_vars`. ⚠ **`clang-format` is deliberately absent** — Godot pins v21.1.7 through `pre-commit`, which fetches it itself; always `pre-commit run`, never a bare `clang-format`. ⚠ **Pass `num_jobs=4` on `webgpu=yes` web builds** — the default `-j9` exhausts this machine's 24 GB. Every command, the Emscripten decision record and the LTO analysis are the **`build-export`** skill.

## Keep it current

- A change to a scope updates its owning skill **in the same change**; a new scope gets a new skill plus one glossary line here.
- ⚠ **Numbers in this file are measurements with a date.** When a re-measurement disagrees, the tool wins — update the figure and its date, never quietly leave both.
- Never grow this file past ~200 lines; it routes, skills hold depth. Cut cruft on sight.
