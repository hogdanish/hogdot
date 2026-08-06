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
| `ccache` | 4.13.6 | ⚠ **NOT automatic, and needs THREE things, not one** — see "Making ccache actually work" below. Config `~/.config/ccache/ccache.conf`, cache `~/.cache/ccache`, cap 30G. |
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
# The CCACHE_* exports + import_env_vars are all required; see "Making ccache work".
export CCACHE_DIR="$HOME/.cache/ccache" CCACHE_CONFIGPATH="$HOME/.config/ccache/ccache.conf"
scons platform=macos target=editor arch=arm64 -j"$(sysctl -n hw.ncpu)" \
      cpp_compiler_launcher=ccache c_compiler_launcher=ccache \
      import_env_vars=HOME,CCACHE_DIR,CCACHE_CONFIGPATH
# -> bin/godot.macos.editor.arm64

# web export template, mainline (no WebGPU until the port lands)
# ⚠ EM_CACHE must be BOTH exported AND named in import_env_vars — exporting alone
#   does nothing, because SCons does not pass the environment through (see below).
#   Without it emcc caches its system libs inside the Homebrew Cellar, which
#   `brew autoupdate` deletes every 12 h, forcing a slow sysroot rebuild.
export EM_CACHE="$HOME/.cache/emscripten"
scons platform=web target=template_release import_env_vars=HOME,EM_CACHE

# web export template WITH WebGPU — only meaningful after the port
scons platform=web target=template_release dlink_enabled=yes webgpu=yes opengl3=no threads=no

# unit tests: build them in, then run the suite
scons platform=macos target=editor arch=arm64 tests=yes && bin/godot.macos.editor.arm64 --test

# lint — Godot's own gates (clang-format, clang-tidy, ruff, mypy, codespell, XML validation, …)
pre-commit run --all-files
pre-commit run <hook-id> --files <path>      # scoped; much faster
```

⚠ **`codespell` rewrites your files in place.** Godot sets `write-changes = true` and the
`en-GB_to_en-US` builtin in `pyproject.toml`, so a lint run silently converts British/Canadian
spelling to American in **any** tracked file, `.claude/skills/**` included — the `-our`/`-ise`/`-gement`
endings all get rewritten. **Write US English in this repo** (Ethan dropped the global
Canadian-English preference here for exactly this reason); the alternative is a permanently dirty
tree. A "failed" codespell run reporting `files were modified by this hook` has **already edited your
working tree** — re-run to confirm, don't hand-revert. This paragraph deliberately names no en-GB
word, because codespell would rewrite the example too.

⚠ **`validate-codeowners` fails on any tracked file with no `.github/CODEOWNERS` entry.** `hogdot/`
needed its own line (added `7d5f060`-era, commit `e2450de`). `.claude/**` passes only by accident —
upstream's root catch-all `/*.*` compiles to a regex that matches any path whose first segment
contains a dot. A new top-level directory without a dot in its name will fail this hook.

⚠ **First `pre-commit run` is slow** — it initializes environments for **every** hook in the config, not
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
(codespell spelling, unowned `hogdot/`), both fixed in `e2450de`. There is no upstream noise to
subtract — judge future runs against green.

⚠ **One deliberate exception, from Phase 1 onward: `drivers/webgpu/` is not clang-format clean.**
The vendored trees are covered by the config's global `.*thirdparty/.*` exclude, but
`drivers/webgpu/` and `webgpu_tests/` are not. Measured 2026-08-06, clang-format v21.1.7 would
rewrite **~1,667 insertions / 1,009 deletions** across 6 files, 2,421 lines of it in
`rendering_device_driver_webgpu.cpp` alone.

**Do not format it until Phase 5.** Reformatting before the driver is adapted to the 4.7.1 API
destroys the only cheap way to diff hogdot's driver against the fork's original, which is what the
whole provenance scheme rests on. Format once, mechanically, as its own commit, after adaptation is
done. Until then, lint scoped (`--files`) rather than `--all-files`, and treat a `drivers/webgpu`
clang-format failure as expected.

## Making ccache actually work (solved 2026-08-06 — three things, all required)

⚠ **This bit everyone once and will bite again. `scons … cpp_compiler_launcher=ccache` alone does
nothing measurable.** The root cause is that **SCons does not pass your environment to the processes
it spawns.** Godot builds `env["ENV"]` from scratch and copies over *only* the variables named in its
`import_env_vars` option (`SConstruct`, "Copy custom environment variables if set"). Anything you
`export` in the shell is invisible to the compiler unless you list it.

That produced a genuinely confusing failure: `verbose=yes` prints the compile line as
`ccache clang++ -o … -c …`, so the launcher *is* applied and ccache *is* on the command line — but
ccache then runs with no `HOME` and no XDG variables, silently falls back to macOS-native paths
(`~/Library/Caches/ccache`, `~/Library/Preferences/ccache/ccache.conf`), never reads the 30G config,
and reports nothing to a `ccache -s` that is looking at `~/.cache/ccache`. It is not broken, it is
answering about a different cache.

All three of these are needed:

```bash
export CCACHE_DIR="$HOME/.cache/ccache" CCACHE_CONFIGPATH="$HOME/.config/ccache/ccache.conf"
scons … cpp_compiler_launcher=ccache c_compiler_launcher=ccache \
        import_env_vars=HOME,CCACHE_DIR,CCACHE_CONFIGPATH
```

1. the launcher options (puts `ccache` on the command line),
2. the `CCACHE_*` exports (ccache cannot find the XDG paths without `XDG_*`, which SCons strips),
3. `import_env_vars` (without it, 1 and 2 never reach the compiler).

**Verified 2026-08-06:** first build of one object → `Cacheable calls: 1/1, Misses: 1`; rebuilding
the same object → `Hits: 1/2, Direct: 1/1`. `ccache -s` moving during a real build is the *only*
acceptable proof — the printed command line is not.

⚠ **The same trap applies to `EM_CACHE` for web builds**, and to any other environment variable a
tool in the build reads. `EM_CACHE=… scons platform=web` **does not work**; it needs
`import_env_vars=HOME,EM_CACHE`.

⚠ **Stale caches from before this fix were trashed 2026-08-06**: 192 MB in `~/Library/Caches/ccache`
and 34 MB in `/opt/homebrew/Cellar/emscripten/6.0.5/libexec/cache`. If `~/Library/Caches/ccache`
reappears, something is building without `CCACHE_DIR` reaching it.

## Not yet established

- ccache hit rate across a realistic port session, and whether the 30G cap is justified. Now
  measurable, since ccache demonstrably records.
- Whether `platform=web` **links** on Emscripten 6.0.5 (compilation is confirmed; see status table).
- The CommonGrounds handoff above.

---
*Source of truth for building hogdot — correct it in the same change as any build command you actually run.*
