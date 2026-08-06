---
name: build-export
description: Compiling hogdot — the scons invocations for the macOS editor and the web export templates, the ccache/pre-commit/Emscripten toolchain and why each is pinned the way it is, running Godot's own lint gates, the unit-test target, and getting a build into CommonGrounds.
when_to_use: Load before running scons, before linting, when a build or link fails, when choosing which verification tier a change needs to reach, or when an Emscripten or web-export problem appears. Boundary — what to build and in what order is the port skill; what the WebGPU backend does is godotwebgpu; the tier policy itself is the verification rule.
user-invocable: false
---

# Building hogdot

⚠ **Status — no `scons` build has ever been run in this repo.** Every build command below is upstream- or
fork-documented, **not yet observed here**. **Correct each one in place the first time you actually run
it**, and say which tier it reached (`.claude/rules/verification.md`). Do not let a command sit here
unmarked after it has been proven or disproven.

**Verified 2026-08-06:** `pre-commit run clang-format --files core/object/worker_thread_pool.cpp` →
`Passed`. So the lint path genuinely works end to end, the pinned v21.1.7 downloads correctly, and an
untouched 4.7.1 file is already format-clean. Everything else here is still documentation.

## The toolchain (installed and verified 2026-08-06)

| Tool | Version | Notes |
| --- | --- | --- |
| `scons` | brew | Godot's build system. |
| `ccache` | 4.13.6 | ⚠ **Picked up automatically by Godot's SConstruct — pass nothing.** XDG-native; config at `~/.config/ccache/ccache.conf`, cache at `~/.cache/ccache`, cap raised to 30G there (5 GiB stock thrashes on an engine build). |
| `pre-commit` | 4.6.1 | The only way to run Godot's `.pre-commit-config.yaml`. |
| `emcc` | 6.0.5 | Web targets only. `EM_CACHE` → `~/.cache/emscripten` (fish `conf.d/xdg-apps.fish`). |

⚠ **`clang-format` is deliberately NOT installed and must stay that way.** Godot pins
`mirrors-clang-format` **v21.1.7** in `.pre-commit-config.yaml` and pre-commit fetches that exact version
itself. A Homebrew `clang-format` would be a different version and would reformat the whole engine into a
diff nobody can review. **Always `pre-commit run`, never a bare `clang-format`.**

## Commands

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

# lint — Godot's own gates (clang-format, clang-tidy, ruff, mypy, codespell, XML validation, …)
pre-commit run --all-files
pre-commit run <hook-id> --files <path>      # scoped; much faster
```

⚠ **First `pre-commit run` is slow** — it initialises environments for **every** hook in the config, not
just the one you asked for (clang-format, clang-tidy 21.1.6, ruff, mypy, codespell, check-jsonschema, plus
local node/eslint/jsdoc/svgo and an xmlschema env) under `~/.cache/pre-commit`. Measured 2026-08-06: a
single-file `clang-format` run took minutes on a cold cache and seconds after. Run it scoped to touched
files while porting; save `--all-files` for before a real commit.

⚠ **Builds are long and belong in the background** (`run_in_background`), and a failed build's **first**
error is the only real one — C++ template and macro errors cascade. Pipe to a file and read the head.

## Emscripten — the decision record

Chosen 2026-08-06: **Homebrew `emscripten` 6.0.5**, over pinning emsdk to 5.0.0.

The reasoning, because it will need revisiting if a web build misbehaves:

- `--use-port=emdawnwebgpu` requires Emscripten **≥ 4.0.10**; it *replaced* `-sUSE_WEBGPU=1`, which was
  removed in 5.0. So 4.0.10 is a **floor**, not a target — the fork's `platform/web/detect.py` says so in
  a comment, and `review_v3/06_build_system.md` states the integration is "forward-compatible with
  Emscripten 5.x".
- The fork actually **shipped and benchmarked on 5.0.0** (`notes/manualy_run_benchmark_scenes.md` records
  `Build configuration: Emscripten 5.0.0`), and `drivers/webgpu/README.md` lists "Emscripten 5.x" as the
  prerequisite. Mainline Godot 4.7.1 requires ≥ 4.0.0.
- ⚠ **6.0.5 is therefore one unverified major ahead of the last version GodotWebGPU was proven on.** When
  web-only breakage appears, **suspect the toolchain before the port**. The fallback is a manual
  `emscripten-core/emsdk` clone pinned to 5.0.0 — emsdk holds versions side by side, but it lives outside
  Homebrew, so `brewup`/`brew autoupdate` and the Brewfile would not cover it.

⚠ An **earlier claim that the fork targeted "4.0.10+" and that 6.0.5 was a two-major gap was wrong** —
corrected here from the fork's own sources. Don't reintroduce it.

## Getting a build into CommonGrounds

`/Users/ethan/Projects/commongrounds` is the sole consumer — in-browser multiplayer, Mobile renderer, web
export, wants compute shaders. Read access is granted in `.claude/settings.json`.

FILL: the actual handoff — whether CommonGrounds points at `bin/godot.macos.editor.arm64` directly or at
an installed editor, and where its export templates are expected. Derive from that repo's `build-export`
skill and record it here the first time a build is handed over.

## Not yet established

- Cold and warm build times on this M5, and the ccache hit rate that justifies the 30G cap.
- Whether `pre-commit run --all-files` passes on an untouched 4.7.1 checkout. One file is confirmed clean;
  the whole tree is not. ⚠ Establish this baseline **before** the first port commit, so any later failure
  is attributable to the port rather than to upstream.
- Whether mainline `platform=web` builds cleanly on Emscripten 6.0.5. ⚠ **This is the highest-value cheap
  experiment available** — it separates a toolchain problem from a port problem before any WebGPU code
  exists to blame.

---
*Source of truth for building hogdot — correct it in the same change as any build command you actually run.*
