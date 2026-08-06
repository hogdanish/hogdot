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

## Parallelism — this machine has 24 GB, and the default `-j` will exhaust it

⚠ **Always pass `num_jobs=4` and `nice -n 10` for `webgpu=yes` web builds.** SCons auto-detects 10
cores and defaults to **`-j9`**. Nine concurrent `em++` processes on the Tint / SPIRV-Tools
translation units drove this machine to 100 % RAM and made it unusable (measured 2026-08-06, Ethan
reported it mid-session). ⚠ **The tell is a pegged machine with quiet fans** — that is swap thrash,
which is I/O-bound, so it never spins the fans up. Do not read a quiet fan as a healthy build.

Which knobs actually reach the spawned processes — the distinction that matters, because Godot's build
spawns tools through scripts:

| Knob | Reaches children? | Why |
| --- | --- | --- |
| `num_jobs=N` / `-j N` | ✅ | SCons *is* the spawner, so it caps the count directly. |
| `nice -n 10 scons …` | ✅ | Niceness is inherited across `fork`/`exec`, so it covers every child. |
| Environment variables | ❌ | The `import_env_vars` trap below — name them or they are silently dropped. |

⚠ **`EMCC_CORES` is an environment variable**, so emcc's *own* internal parallelism is not covered by
`num_jobs` and is dropped unless named in `import_env_vars`. It is the knob that matters during a
ThinLTO link, where emcc — not SCons — decides how many backend threads to run.

## LTO — possible here, but not worth it before Phase 5

⚠ **LTO is OFF by default and was never the cause of any memory problem here.** `lto` defaults to
`"none"` (`SConstruct:183`) and only becomes `"auto"` when `production=yes` is passed
(`SConstruct:681`). Nothing in Phases 1–2 passed either.

- On web, `lto=auto` resolves to **`thin`**, not `full` (`platform/web/detect.py:173-174`; it falls
  back to `full` only below Emscripten 4.0.9, which does not apply at 6.0.5). ThinLTO's peak memory is
  a small multiple of one module, not the whole program — the ~30 GB figure in Godot's docs is for
  monolithic desktop `-flto`. **A production web template with LTO does fit in 24 GB.**
- ⚠ **"Push through once so it caches" does not apply to LTO.** ccache caches *object compilations*;
  LTO does its work at **link** time, which ccache never caches. Every relink pays it again, forever.
  What does cache is the ordinary compile of Tint + SPIRV-Tools (~1,200 files) — and that happens with
  `lto=none` anyway.
- **Therefore: keep `lto=none` for all port iteration; spend LTO exactly once, on the
  `production=yes` template handed to CommonGrounds.**

⚠ **Linker choice is not a lever.** Web output has no alternative linker — `wasm-ld` is part of the
LLVM/Emscripten toolchain and `emcc` drives it; `mold`/`lld` swaps do not apply to wasm. On macOS the
link is seconds inside a ~4-minute build, so it is not the bottleneck, and `mold` has no Mach-O
support anyway.

## The toolchain (installed and verified 2026-08-06)

| Tool | Version | Notes |
| --- | --- | --- |
| `scons` | brew | Godot's build system. |
| `ccache` | 4.13.6 | ⚠ **NOT automatic, and needs THREE things, not one** — see "Making ccache actually work" below. Config `~/.config/ccache/ccache.conf`, cache `~/.cache/ccache`, cap 30G. |
| Vulkan SDK | LunarG, installed 2026-08-06 | Needed for `-lMoltenVK` at link time. Installed with `sh misc/scripts/install_vulkan_sdk_macos.sh` — headless, no sudo, lands in `~/VulkanSDK`. Outside Homebrew, so `brewup` does not cover it. |
| `pre-commit` | 4.6.1 | The only way to run Godot's `.pre-commit-config.yaml`. |
| `emcc` | 6.0.5 | Web targets only. `EM_CACHE` → `~/.cache/emscripten` (fish `conf.d/xdg-apps.fish`). |
| `glslang` | brew 16.5.0 | ⚠ **Hard dependency of `webgpu=yes` only**, installed 2026-08-06. Provides `glslangValidator` on `$PATH`, which `drivers/webgpu/wgsl_precompile.py` shells out to. Without it the build dies at `wgsl_precompiled.gen.h` — see the WGSL precompile section below. |

⚠ **`webgpu=yes` needs a host toolchain that no other target needs.** Two host-side steps run before a
single driver object compiles, and both fail in ways that look nothing like a port problem:
1. `drivers/webgpu/tint_cli/build.sh` compiles a **native** `bin/tint_convert_cli` (~570 objects, 13 MB).
   It is a separate build inside the build and respects none of SCons's flags.
2. `wgsl_precompile.py` then shells out to `glslangValidator` for 70 shader files and pipes the SPIR-V
   through `tint_convert_cli` to generate `drivers/webgpu/wgsl_precompiled.gen.h`.

⚠ **`glslangValidator: Permission denied` means "not installed", not a permissions problem.** `execvp`
reports `EACCES` rather than `ENOENT` when it walks a `$PATH` containing an unsearchable entry (this
machine has a stale `/pkg/env/global/bin`), and Python surfaces that as `PermissionError`. Worse,
`wgsl_precompile.py` catches only `FileNotFoundError`, so the real message never reaches you. Check
`command -v glslangValidator` before believing the errno.

⚠ **Homebrew's glslang is 16.5.0; Godot vendors 16.1.0** (`thirdparty/README.md:417`,
`thirdparty/glslang/glslang/build_info.h`). `wgsl_precompile.py` shells out to the **Homebrew** one at
build time; the engine compiles GLSL→SPIR-V with the **vendored** one at runtime. The precompiled table
is keyed on a hash of the SPIR-V blob, so the two producing different blobs means the table misses.

⚠⚠ **An earlier version of this file said that skew "costs cache hits, never correctness". That was
wrong, and the phase-4 boot gate disproved it.** A miss is not a graceful degradation: it falls through
to live Tint, and live Tint **cannot translate a write-only storage buffer at all** — WGSL has no
`write` access mode for the storage address space. Skeleton and particles compute shaders fail, and the
engine traps on `unreachable` before the main loop. See ledger **RL-020** (the blocker) and **RL-009**
(the dead table, now its suspected cause). Until that is resolved, treat the two glslang versions as a
**correctness** dependency, not a cache-efficiency one — and do not "just uninstall" the Homebrew copy
either, since `wgsl_precompile.py` needs `glslangValidator` on `$PATH` by that exact name and the
vendored build does not provide it. The Vulkan SDK also ships a `glslang`
(16.4.0, `~/VulkanSDK/1.4.357.0/macOS/bin/glslang`), but only under the new name, not
`glslangValidator`.

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

# web export template WITH WebGPU — the Phase 2 command, run 2026-08-06.
# ⚠ num_jobs=4 + nice are REQUIRED here: the default -j9 exhausts 24 GB on the
#   Tint/SPIRV-Tools sources. See "Parallelism" above.
# ⚠ Needs `glslangValidator` on $PATH (brew glslang) or it dies generating
#   wgsl_precompiled.gen.h, long before any driver object compiles.
export EM_CACHE="$HOME/.cache/emscripten" CCACHE_DIR="$HOME/.cache/ccache" \
       CCACHE_CONFIGPATH="$HOME/.config/ccache/ccache.conf"
nice -n 10 scons platform=web target=template_debug webgpu=yes opengl3=no threads=no \
     num_jobs=4 import_env_vars=HOME,CCACHE_DIR,CCACHE_CONFIGPATH,EM_CACHE

# the eventual release template (adds dlink_enabled; spend LTO only here, via production=yes)
scons platform=web target=template_release dlink_enabled=yes webgpu=yes opengl3=no threads=no

# ⚠ configure-only smoke test — seconds, compiles nothing. Godot runs platform
#   detection and every module config.py before printing help, so this catches an
#   undeclared option, a config.py KeyError or a broken SConscript for free.
scons platform=web target=template_debug webgpu=yes opengl3=no threads=no --help

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
