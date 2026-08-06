---
name: build-export
description: Compiling hogdot — the scons invocations for the macOS editor and the web export templates, the ccache/pre-commit/Emscripten toolchain and why each is pinned the way it is, running Godot's own lint gates, the unit-test target, and getting a build into CommonGrounds.
when_to_use: Load before running scons, before linting, when a build or link fails, when choosing which verification tier a change needs to reach, or when an Emscripten or web-export problem appears. Boundary — what to build and in what order is the port skill; what the WebGPU backend does is godotwebgpu; the tier policy itself is the verification rule.
user-invocable: false
---

# Building hogdot

**Status — the macOS editor build is now OBSERVED, not documented.** Measured 2026-08-06 on the M5:

| What | Result |
| --- | --- |
| `scons platform=macos target=editor arch=arm64` | **builds**, `bin/godot.macos.editor.arm64`, 130 MB |
| Cold build, 2,890 objects, `-j$(sysctl -n hw.ncpu)` | **~4–5 minutes**, not "tens of minutes" |
| `pre-commit run --all-files` on untouched 4.7.1 | **clean** — every hook passes (see below) |

⚠ **Godot cold-builds in minutes on this machine.** The plan's "builds are long, work around them"
posture is calibrated for far slower hardware. Backgrounding a build is still right, but do not
restructure a session around a wait that is shorter than a single reference read.

⚠ **`bin/` did not exist and `arch=arm64` is required** — plain `scons platform=macos` picks a
different default.

## The toolchain (installed and verified 2026-08-06)

| Tool | Version | Notes |
| --- | --- | --- |
| `scons` | brew | Godot's build system. |
| `ccache` | 4.13.6 | ⚠ **NOT automatic — you must pass `cpp_compiler_launcher=ccache c_compiler_launcher=ccache`.** XDG-native; config at `~/.config/ccache/ccache.conf`, cache at `~/.cache/ccache`, cap raised to 30G there (5 GiB stock thrashes on an engine build). |
| Vulkan SDK | LunarG, installed 2026-08-06 | Needed for `-lMoltenVK` at link time. Installed with `sh misc/scripts/install_vulkan_sdk_macos.sh` — headless, no sudo, lands in `~/VulkanSDK`. Outside Homebrew, so `brewup` does not cover it. |
| `pre-commit` | 4.6.1 | The only way to run Godot's `.pre-commit-config.yaml`. |
| `emcc` | 6.0.5 | Web targets only. `EM_CACHE` → `~/.cache/emscripten` (fish `conf.d/xdg-apps.fish`). |

⚠ **`clang-format` is deliberately NOT installed and must stay that way.** Godot pins
`mirrors-clang-format` **v21.1.7** in `.pre-commit-config.yaml` and pre-commit fetches that exact version
itself. A Homebrew `clang-format` would be a different version and would reformat the whole engine into a
diff nobody can review. **Always `pre-commit run`, never a bare `clang-format`.**

## Commands

```bash
# macOS editor — the binary CommonGrounds opens. ~4-5 min cold, seconds incremental.
# ⚠ The two launcher options are what actually enable ccache. Without them the 30G
#   cache stays empty and every build is uncached (measured 2026-08-06, the hard way).
scons platform=macos target=editor arch=arm64 -j"$(sysctl -n hw.ncpu)" \
      cpp_compiler_launcher=ccache c_compiler_launcher=ccache
# -> bin/godot.macos.editor.arm64

# web export template, mainline (no WebGPU until the port lands)
# ⚠ Set EM_CACHE explicitly. Fish's conf.d/xdg-apps.fish redirects it out of the
#   Cellar, but Claude's Bash tool runs under zsh and never sees that export, so
#   emcc silently caches its system libs in
#   /opt/homebrew/Cellar/emscripten/<ver>/libexec/cache — which `brew autoupdate`
#   deletes every 12 h, forcing a slow sysroot rebuild. Observed 2026-08-06.
EM_CACHE="$HOME/.cache/emscripten" scons platform=web target=template_release

# web export template WITH WebGPU — only meaningful after the port
scons platform=web target=template_release dlink_enabled=yes webgpu=yes opengl3=no threads=no

# unit tests: build them in, then run the suite
scons platform=macos target=editor arch=arm64 tests=yes && bin/godot.macos.editor.arm64 --test

# lint — Godot's own gates (clang-format, clang-tidy, ruff, mypy, codespell, XML validation, …)
pre-commit run --all-files
pre-commit run <hook-id> --files <path>      # scoped; much faster
```

⚠ **`codespell` rewrites your files in place.** Godot sets `write-changes = true` and the
`en-GB_to_en-US` builtin in `pyproject.toml`, so a lint run silently converts en-GB spelling
(`judgement`, `behaviour`, `colour`) to en-US in **any** tracked file, `.claude/skills/**` included.
**Write US English in this repo** — the alternative is a permanently dirty tree. A "failed" codespell
run that reports `files were modified by this hook` has already edited your working tree; re-run to
confirm, don't hand-revert.

⚠ **`validate-codeowners` fails on any tracked file with no `.github/CODEOWNERS` entry.** `hogdot/`
needed its own line (added `7d5f060`-era, commit `e2450de`). `.claude/**` passes only by accident —
upstream's root catch-all `/*.*` compiles to a regex that matches any path whose first segment
contains a dot. A new top-level directory without a dot in its name will fail this hook.

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

## The lint baseline (established 2026-08-06, before the first port commit)

`pre-commit run --all-files` on untouched 4.7.1 **passes every hook**. The snapshot is
`.claude/work/plans/research/lint-baseline.txt`; the only two failures in it were hogdot's own files
(codespell spelling, unowned `hogdot/`), both fixed in `e2450de`. **Any lint failure from here on is
ours.** There is no upstream noise to subtract — judge future runs against green, not against a diff.

## Not yet established

- ccache hit rate across a realistic port session, now that the launcher options are actually passed.
  The 30G cap is still unjustified by measurement.
- Whether `platform=web` **links** on Emscripten 6.0.5 (compilation is confirmed; see status table).
- The CommonGrounds handoff above.

---
*Source of truth for building hogdot — correct it in the same change as any build command you actually run.*
