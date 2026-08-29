---
name: build-export
description: Compiling hogdot — the scons invocations for the macOS editor and the web export templates, the ccache/pre-commit/Emscripten toolchain and why each is pinned the way it is, running Godot's own lint gates, the unit-test target, fork CI and the cg-release artifact channel, and getting a build into CommonGrounds.
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
| Vulkan SDK | LunarG, installed 2026-08-06 | Needed for `-lMoltenVK` at link time. Headless, no sudo, lands in `~/VulkanSDK`; outside Homebrew, so `brewup` does not cover it. ⚠ Prefer **`./hogdot/install-vulkan-sdk-macos.sh`** (pinned + sha256-verified, what CI runs) over upstream's `misc/scripts/install_vulkan_sdk_macos.sh` (fetches `latest`, verifies nothing) — using the same one locally keeps the dev machine on the SDK the release channel builds against. |
| `pre-commit` | 4.6.1 | The only way to run Godot's `.pre-commit-config.yaml`. |
| `emcc` | 6.0.x | Web targets only. `EM_CACHE` → `~/.cache/emscripten` (fish `conf.d/xdg-apps.fish`). ⚠ **Do not pin a patch version in prose** — `brew autoupdate` moves it every 12 h. Measured 6.0.5 on 2026-08-06 morning and **6.0.6-git** the same afternoon, and RL-039 is what a stale version assertion costs. `emcc --version` is the answer. |
| `glslang` | brew 16.5.0 | ⚠ **No longer a build dependency of `webgpu=yes`** — see below. Still needed for the offline dev tooling in `webgpu_tests/shader_corpus/` (`compile_fixtures.sh`, `validate_spirv_dump.mjs`) and for `bin/tint_convert_cli` corpus work. |

⚠ **`webgpu=yes` needs one host toolchain step no other target needs:**
`drivers/webgpu/tint_cli/build.sh` compiles a **native** `bin/tint_convert_cli` (~570 objects, 13 MB).
It is a separate build inside the build and respects none of SCons's flags.

⚠ **The build-time SPIR-V→WGSL precompile table is gone, and `glslang` is not a build-time dependency
any more.** `wgsl_precompile.py` and `wgsl_precompiled.gen.h` were **deleted in `28a9960` (phase 7,
2026-08-06)** — measured 100% dead across every phase-4/5/6/7 run (`table_count=141`, 600+ lookups,
0 hits; every shader took the live Tint path regardless). `drivers/webgpu/SCsub` no longer shells out to
`glslangValidator` at build time, so its absence no longer breaks a `webgpu=yes` build. See ledger
**RL-025** (moot) and **RL-009** (the original dead-table finding) in
`.claude/skills/port/references/review-ledger.md`. The engine still compiles GLSL→SPIR-V with its own
**vendored** glslang at runtime, which never depended on the Homebrew copy — that skew (RL-020/RL-009)
is retired along with the table it affected.

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
# `glslangValidator` is NOT required to build this target (the precompile step
#   that needed it was deleted in 28a9960) — only for the offline shader_corpus tooling.
export EM_CACHE="$HOME/.cache/emscripten" CCACHE_DIR="$HOME/.cache/ccache" \
       CCACHE_CONFIGPATH="$HOME/.config/ccache/ccache.conf"
nice -n 10 scons platform=web target=template_debug webgpu=yes opengl3=no threads=no \
     num_jobs=4 import_env_vars=HOME,CCACHE_DIR,CCACHE_CONFIGPATH,EM_CACHE

# the eventual release template (adds dlink_enabled; spend LTO only here, via production=yes)
scons platform=web target=template_release dlink_enabled=yes webgpu=yes opengl3=no threads=no

# ⚠ threads=yes is supported as of 2026-08-10 and both templates ship. Same command,
#   threads=yes — cold 7m34s, warm relink ~1m, same num_jobs=4 memory law.
#   ⚠ The ONLY difference in the artifact name is the suffix: threads=yes writes
#   godot.web.template_*.wasm32.zip, threads=no adds `.nothreads`. A preset naming the
#   wrong one is silent at export and fails at runtime. Serving a threaded build needs
#   COOP/COEP or it cannot start. Everything else: .claude/work/plans/THREADS.md
nice -n 10 scons platform=web target=template_debug webgpu=yes opengl3=no threads=yes \
     num_jobs=4 import_env_vars=HOME,CCACHE_DIR,CCACHE_CONFIGPATH,EM_CACHE

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

⚠ **A missing final newline in README.md blocked every fork CI run ever** (found 2026-08-27):
upstream's `static_checks.yml` runs prek's `file-format` hook, which fails on a file without a
trailing newline, and `runner.yml` gates every build job on static-checks — so one missing `\n`
at EOF failed all of fork CI. Fixed the same day; `pre-commit run file-format --files <path>`
catches it locally before CI does.

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

**CI pin, decided 2026-08-27: emsdk `6.0.8` for every `webgpu=yes` CI build** — the two WebGPU jobs
in `web_builds.yml` (per-matrix `em-version-override: webgpu` → `EM_VERSION_WEBGPU`) and all four
templates in `cg_release.yml`. Rationale: the driver targets emdawnwebgpu's current `webgpu.h`
(4-parameter `WGPUQueueWorkDoneCallback` etc.), which upstream's `EM_VERSION: 4.0.11` pin cannot
compile — run 33120336421 failed exactly there — and 6.0.8 is the exact emcc the shipped
CommonGrounds templates were built and verified with (the local Homebrew keg measured 6.0.8,
2026-08-27). The pin was chosen over `#ifdef`-ing the driver for old headers: the fork is verified
on 6.0.x only, so compiling it under 4.x would produce an artifact nobody tests. The vanilla web
canary job deliberately **stays on upstream's 4.0.11** — it exists to prove the default web config
still builds as upstream builds it, and it is unverified under emcc 6. ⚠ CI is pinned to an exact
emsdk on purpose while the local Homebrew emcc floats (table above) — when they drift, local
observations stop transferring to CI; bump `EM_VERSION_WEBGPU` (both files, in lockstep) only
together with rebuilt-and-verified shipped templates. ⚠ The webgpu CI jobs also carry
`EMCC_CFLAGS: -Wno-unused-template` (workflow env + `import_env_vars=EMCC_CFLAGS` in their scons
flags): 6.0.8's clang warns on unused static function templates in **upstream** headers
(`modules/gltf/gltf_template_convert.h`) that upstream's own 4.0.11 clang never sees, and
dev_mode's werror turns that into a fork-CI-only failure. Policy (owner, 2026-08-27): **suppress,
never patch upstream module code** — that is pure rebase tax; and if a *second* upstream warning
class ever surfaces under emcc 6, flip the webgpu jobs to `werror=no` rather than grow the list
(fork-owned code cleanliness is already proven; upstream's warning set is calibrated to 4.0.11's
clang). ⚠ Suppression mechanics matter: scons `ccflags=`/`cxxflags=` append **before** the
warnings block, so a later `-Wall` re-enables the warning (measured, run 33122928238) — emcc
appends `EMCC_CFLAGS` after everything, which is the only injection point that wins (verified
locally on 6.0.8, 2026-08-27). Release-channel templates never set werror, so they need none of
this. The webgpu jobs additionally pass `use_closure_compiler=no` (overriding upstream's env
flag — scons last-value-wins): under emcc 6.0.8 closure's bundled externs now declare
`OVR_multiview2`, colliding with Godot's `platform/web/js/libs/library_godot_webgl2.externs.js`
(`JSC_VAR_MULTIPLY_DECLARED_ERROR`, run 33124255404). Nothing shipped uses closure
(prod-web-build §1 lists it as candidate-only) and the 4.0.11 canary keeps upstream's closure
coverage. ⚠ That externs collision must be solved for real (fix the externs file, or
`--jscomp_off`) before the game's closure-compiler A/B can run on emcc 6.

## Getting a build into CommonGrounds

`/Users/ethan/Projects/commongrounds` is the sole consumer — in-browser multiplayer, Mobile renderer, web
export, wants compute shaders. Read access is granted in `.claude/settings.json`.

**The handoff is: rebuild in place — CommonGrounds consumes hogdot's `bin/` directly** (derived
2026-08-20 from `scripts/run-web.sh` + `godot/export_presets.cfg`):

- **Editor:** `run-web.sh` requires `GODOT_BIN` to resolve under a hogdot `bin/` (default
  `../hogdot/bin/godot.macos.editor.arm64`; the `hogdot` fish function points there). A stock
  editor is rejected — it has no WebGPU backend and its exports churn importer keys (RL-040).
- **Templates:** the export presets hardcode relative paths into hogdot —
  `custom_template/{debug,release}="../../hogdot/bin/godot.web.template_{debug,release}.wasm32[.nothreads].zip"`
  (threaded presets use the suffixless names). Nothing is installed into
  `~/Library/Application Support/Godot/export_templates/` — the version-named install dir is not
  part of this flow, so a base-version bump needs no re-install step.
- **Freshness is checked on their side:** `run-web.sh` dies if a template zip is older than the
  newest hogdot commit touching engine code (`--allow-stale-template` overrides).
- Threads handoff details: `.claude/work/plans/THREADS.md`.

### Shader baking for web works as of 2026-08-11 (RL-042 step 1)

`shader_baker/enabled=true` in a Web preset now bakes SPIR-V containers into the pck at
`res://.godot/shader_cache/…/*.webgpu.cache`; the runtime loads them and skips glslang on first
use of every baked shader. The pieces: the WebGPU shader container compiles into every editor
build (`editor/shader/shader_baker/SCsub` when `webgpu=no` — beside its only consumer, moved out
of `drivers/SCsub` 2026-08-27 for GNU ld; RL-057), `ShaderBakerExportPluginPlatformWebGPU` is
registered unconditionally in
`editor_node.cpp`, and the web export plugin declares the option, pushes the `shader_baker`
feature, and warns on renderer mismatch. Details and verification:
`.claude/work/plans/features/feature-shader-baker.md`.

The command that bakes (a windowed CLI export — the window is the point):

```bash
cd webgpu_tests/test_project && ../../bin/godot.macos.editor.arm64 --path . \
    --rendering-method mobile --export-debug "WebGPU" export/index.html
```

⚠ **A `--headless` export can never bake shaders, on any platform.** Baking pulls the embedded
shaders out of a live `RendererSceneRenderRD`, and headless has none — hogdot warns when baking
was requested and cannot run (RL-041). Every fully-scripted export (CommonGrounds' `run-web.sh`)
must drop `--headless` on the export step to bake.

⚠ **The editor must run the target's rendering method** (`--rendering-method mobile` for
CommonGrounds/web) or the core shaders bake for the wrong renderer and miss at runtime.

⚠ **The bake compiles SPIR-V at the export target's version, not the editor driver's** — plumbed
through `compile_stages` (a Metal editor otherwise emits 1.6, which runtime Tint rejects). Keep
that in mind before "simplifying" the extra parameter away.

⚠ **The baked cache only hits when the editor and the export template are built from the same
commit** — `GODOT_VERSION_HASH` is part of every cache path (RL-055). Commit first, then build
both, then export. A skewed pair degrades silently to full runtime compilation.

**Step 2 (bake WGSL) landed 2026-08-11 (`49eb3381e3`)** and removes SPIR-V preprocessing + Tint
from the runtime too (~7.6 s of a 16.95 s measured cold start; glslang was ~4.4 s). It needs
`bin/tint_convert_cli` **beside the editor binary and built from the same tree** — the baker
runs `tint_convert_cli --pipeline-id` and refuses WGSL baking (warning, SPIR-V-only bake) when
the stamp differs from the editor's build-time copy. Rebuild it with
`drivers/webgpu/tint_cli/build.sh` after touching anything in
`drivers/webgpu/tint_cli/pipeline_id_inputs.txt`. Only `createShaderModule` +
`createRenderPipeline` remain at runtime for baked shaders; runtime-generated materials
(procedural `ShaderMaterial`s) still pay the full path — only shaders visible at export time
can bake. Verification and numbers: `feature-shader-baker.md`.

## Linux editor (linuxbsd) — first built 2026-08-27

The first linuxbsd editor build ever attempted (CommonGrounds CI spike 6.A.1) succeeded on
Ubuntu 24.04 arm64 — the OrbStack VM `cg-hogdot-build`, gcc 13.3, scons 4.5.2:
`scons platform=linuxbsd target=editor` with the usual ccache trio, **~8 min cold at `-j8` on
9 M5 cores**, stamping `4.7.2.stable.custom_build`.

- ⚠ **`webgpu=yes` stays a hard error on linuxbsd by design** — the driver is web-only. The
  editor still bakes for web through the always-compiled
  `ShaderBakerExportPluginPlatformWebGPU` plus the WebGPU shader container (section above).
- ⚠ **The first link died with `undefined reference to RenderingShaderContainerWebGPU::…`**
  (RL-057): the container was compiled into `libdrivers.a` while its only consumer sits in
  `libeditor.a`, and GNU ld scans static archives in a single pass, so the member was silently
  skipped — Apple ld resolves it, which is why macOS editors always linked. Fixed 2026-08-27 by
  compiling the container into the editor library beside its consumer
  (`editor/shader/shader_baker/SCsub`, `webgpu=no` builds).
- ⚠ **This Mac cannot even configure linuxbsd** — `platform/linuxbsd` fails `can_build()` on a
  macOS host, so SCons does not offer the platform (measured 2026-08-27). The configure-only
  smoke test (`scons platform=linuxbsd target=editor --help`) must run in the VM.
- **Ubuntu 24.04 deps:** `build-essential scons pkg-config libx11-dev libxcursor-dev
  libxinerama-dev libgl1-mesa-dev libglu1-mesa-dev libasound2-dev libpulse-dev libudev-dev
  libxi-dev libxrandr-dev libwayland-dev`. Bake environment: `xvfb` + `mesa-vulkan-drivers`
  (lavapipe presents a Vulkan 1.4 `llvmpipe` device under Xvfb, satisfying the windowed-export
  requirement for baking on a headless host). `tint_convert_cli`: `shasum`
  (`libdigest-sha-perl`) + `g++`.

## Fork CI (trimmed 2026-08-27 — deliberate, owner-approved)

**CI runs only what the fork ships**: `runner.yml` calls static-checks, `linux_builds.yml` (one
plain `target=editor` job — the compile gate for the release channel's baker editor) and
`web_builds.yml` (the two `webgpu=yes` wasm32 jobs + one vanilla wasm32 nothreads canary on
upstream's emsdk 4.0.11). The android/ios/macos/windows workflows and the rest of upstream's
Linux/web matrices are **not called** — those platforms ship on official Godot (the game's S8
engine split), and the ~20 concurrent-job account cap means dead jobs queue against the release
workflow and the game repo's Actions. `webgpu_tests.yml` is untouched (self-triggered on
`drivers/webgpu/**` PRs). `runner.yml` triggers on `branches: ['**']` only, so `cg-v*` tag pushes
never start the matrix.

⚠ **Rebase-forward: these workflow edits are a recorded mechanical step** to re-apply on every
future upstream merge — upstream will reintroduce the platform jobs and matrix entries. The
re-apply list: (1) `runner.yml` — keep only static-checks/linux/web call jobs, `branches`-only
push trigger; (2) `web_builds.yml` — drop wasm64 + extras, keep the vanilla wasm32 canary, keep
the two webgpu jobs with `em-version-override: webgpu`, the `EM_VERSION_WEBGPU: 6.0.8` +
`EMCC_CFLAGS: -Wno-unused-template` env, and per-job `import_env_vars=EMCC_CFLAGS
use_closure_compiler=no` (rationale for each: the Emscripten decision record above);
(3) `linux_builds.yml` — one plain editor matrix entry; (4) re-SHA-pin any new third-party
`uses:` (repo setting `sha_pinning_required` rejects tag refs, and `allowed_actions: selected`
blocks unlisted owners — patterns live in the repo's Actions settings, set 2026-08-27).

- **Every third-party action is SHA-pinned** (`@<40-hex> # vN`), across workflows *and* the
  `.github/actions/*` composites. Local `./.github/actions/*` and same-repo reusable workflows are
  exempt from both repo settings.
- **No secrets in this repo's Actions, ever** (decision of record) — the release channel uses only
  the ambient `GITHUB_TOKEN`. The game repo is private; anything needing its content is *copied
  into* hogdot (see the build profile below), never checked out from it.
- **Repo default workflow permissions are `read`** (measured 2026-08-28 via
  `gh api repos/hogdanish/hogdot/actions/permissions/workflow`), and the repo is public. That is
  why only `cg_release.yml` needed the least-privilege fix below: every other workflow's persisted
  checkout credential is a read token on a public tree, and adding `persist-credentials: false` to
  upstream's workflow files would buy nothing while costing a conflict on every rebase-forward.
  ⚠ **If that default is ever flipped to write, or the repo is made private, revisit that** —
  the reasoning, not the conclusion, is what is recorded here.
- ⚠ A README.md missing its final newline blocked every fork CI run ever (see lint section).

## The cg-release channel (`cg_release.yml`, first cut 2026-08-27)

**The release path is `workflow_dispatch` on `main` with a `tag` input** (scheme:
`cg-v<godot-base>-r<N>`; driven by the game repo's `cg engine release`): the run validates the
tag fast-fail (well-formed, not already existing), builds everything game CI consumes from the
dispatched `GITHUB_SHA`, creates+pushes the tag only after every build succeeded (a failed run
leaves no tag; a `GITHUB_TOKEN`-pushed tag cannot retrigger the workflow), and publishes the
GitHub Release. Standalone workflow — not gated on static-checks, own concurrency group
(`cg-release|<tag>`, `cancel-in-progress: false`).

⚠ **Dispatch-from-main is what makes releases cacheable (fixed 2026-08-28).** GitHub cache
isolation scopes a run's saved caches to the run's own ref plus the default branch — so the
original tag-push design saved every `cg-release-*` scons cache under `refs/tags/<tag>`, where
no later tag could ever restore it: r2 recompiled everything from scratch, and main's
`linux-editor`/`web-webgpu-template*` caches were no help either (different cache names AND
different build signatures — `dev_mode`, no `production`, no `build_profile`). A dispatch run
executes on `refs/heads/main`, so its saves land at `cg-release-*|main|<sha>` — exactly the
default-branch fallback every later run's restore step reads. **Pushing a `cg-v*` tag by hand
still works as the break-glass path, but it is cold by construction and skips the cache-save
steps** (a tag-scoped save is unreachable dead weight against the 10 GiB cache quota).

**Assets** (names state both variant dimensions explicitly; the body maps them back to the
`bin/` filenames the game's export presets expect):

| Asset | Contents |
| --- | --- |
| `editor-linux-x86_64.tar.gz` | `godot.linuxbsd.editor.x86_64` + `tint_convert_cli` — the baker pair, same commit (RL-055 + the tint pipeline-id stamp), must stay beside each other. |
| `editor-macos-arm64.tar.gz` | `godot.macos.editor.arm64` + `tint_convert_cli` (since r2, 6.A.4) — the Mac dev editor as a pinned asset instead of an mtime in `bin/`. Built on `macos-15` with the Vulkan SDK step REQUIRED (the editor links `-lMoltenVK`; matches the local recipe above), via the pinned `hogdot/install-vulkan-sdk-macos.sh`. arm64 only. |
| `web-template_{release,debug}.{threads,nothreads}.wasm32.zip` | The four production templates: `webgpu=yes vulkan=no opengl3=no initial_memory=256 build_profile=hogdot/build_profile.web.gdbuild`, `production=yes` on release only (the prod-web-build recipe: debug skips exactly that flag). |
| `checksums.txt` | sha256 per asset; also in the release body. |
| `build-manifest.txt` | Runner image + toolchain per asset (see "Reproducibility" below); also in the release body, folded into a `<details>`. |

The release body carries the fork commit, the editor `--version` string (game CI's
`HOGDOT_BUILD`; format `4.7.2.stable.custom_build.<sha9>` — CI must NOT set `BUILD_NAME`, which
upstream's godot-build composite sets to `gh`), the emsdk pin, and the build profile's sha256.

⚠ **The game downloads assets by name** (`web-export.yml`: an explicit list, each verified against
an `HOGDOT_SHA256_*` pin in `engine.env`), so adding an asset to a release is safe and removing or
renaming one is not.

**`hogdot/build_profile.web.gdbuild` is a tracked COPY of the game's
`godot/build_profile.web.gdbuild`** (copied-profile-with-drift-check, decided 2026-08-27 — a
cross-repo checkout was rejected: the game repo is private and hogdot holds zero secrets). Its
sha256 in the release body is the drift check: game CI compares it against its own copy, and a
mismatch means "profile changed ⇒ cut a new engine release". ⚠ When the game's profile changes,
re-copy it here and tag a new release — the copy is otherwise never edited by hand.

Iterating on a failed release: each fix is a new push to main, then re-dispatch with the same
tag input — a failed dispatch run created no tag, so there is nothing to clean up. Once a tag
exists (the run succeeded), it is consumed by the game's `engine.env` digest pins: cut the next
`-rN` instead of touching it.

### Least privilege and the supply chain (hardened 2026-08-28)

This channel is the fork's only workflow with write access and the only one whose output is
consumed as a trusted binary, so it is the only one where either mistake is expensive.

- **`permissions: contents: read` at workflow level; `contents: write` on the `release` job
  alone.** It used to be workflow-level write, which handed a repo-mutating credential to
  preflight and all six compilation jobs — jobs that pull apt packages, an emsdk, a Vulkan SDK and
  a pip SCons, then run a build system that executes arbitrary in-tree Python for two hours. The
  `release` job compiles nothing (`download-artifact` + `gh`), so write lives on the smallest
  possible surface.
- **`persist-credentials: false` on every checkout except `release`'s.** `actions/checkout`
  otherwise leaves the token in `.git/config` as an extraheader for the life of the job. ⚠ The
  `release` job's checkout keeps it *and says so explicitly* — its tag step is a real
  `git push origin`, which authenticates through exactly that header. `gh release create` does
  not need it (`GH_TOKEN` from the environment); the tag push does. Do not "tidy" it away.
- ⚠ **The macOS Vulkan SDK is pinned and digest-verified, by
  `hogdot/install-vulkan-sdk-macos.sh`, NOT upstream's
  `misc/scripts/install_vulkan_sdk_macos.sh`.** Upstream's fetches LunarG's `latest` and executes
  the installer with no pin, no digest and no signature — ~360 MiB of remote code running on the
  runner that builds a shipped asset, and a silent reproducibility hole ("latest" is a different
  SDK every few weeks, recorded nowhere). The replacement verifies sha256 *before* it unzips
  anything and fails closed. Currently **1.4.357.1** (LunarG 2026-08-17, `cf23e604…c769a5`,
  376,108,497 bytes) — which was `latest` when it was pinned, so pinning changed nothing about
  what gets built. Upstream's script is deliberately left untouched: it is mainline Godot's file
  and editing it would conflict on every rebase-forward. **Bumping the pin moves two constants in
  that script and they must move together** — the header carries the exact `curl | shasum` recipe.
  A version without its matching digest is worse than no pin, because it looks verified.

### Reproducibility — `build-manifest.txt`

`ubuntu-24.04` and `macos-15` are rolling labels, not images, and everything inside them floats.
Each build job therefore drops a `manifest-NN-*.txt` fragment (runner `ImageOS`/`ImageVersion`,
compiler, Python, SCons, plus emcc/emsdk on web and the Vulkan SDK on macOS); the `release` job
concatenates them into the `build-manifest.txt` asset with the fork commit, build-profile sha256
and the workflow-run URL on top. A missing fragment fails the step on purpose — a manifest with a
hole in it is worse than none.

**Python is pinned to `3.13` at this channel's `godot-deps` call sites** (`env.PYTHON_VERSION`),
not in the composite: the composite's `3.x` default is upstream's file, and a floating Python is
the right behavior for a pass/fail CI gate — it is only wrong for a shipped artifact. SCons is
already pinned (`4.10.1`) inside the composite.

### Artifact and cache storage (HOG-03, 2026-08-28)

- **`retention-days: 1` on every `upload-artifact` in this workflow.** The `cg-release-*`
  artifacts exist only to hand bytes to the `release` job in the same run; the permanent copy is
  the Release asset, which is what the game downloads. At the 90-day default they were an exact
  duplicate of the release — measured 2026-08-28, 12 unexpired `cg-release-*` artifacts holding
  ~320 MB. (⚠ The larger consumer is fork-CI matrix output: 3.13 GB of unexpired artifacts total,
  the rest of it from `./.github/actions/upload-artifact`, which upstream sets to 60 days.)
- ⚠ **13 tag-scoped `cg-release-*` scons caches (~1.01 GB) are permanently unreachable** and
  must be swept by hand — r1 and r2 ran as tag pushes, so their saves landed on
  `refs/tags/cg-v4.7.2-r{1,2}` where no run can ever restore them. The dispatch-from-main design
  plus the `if: github.event_name == 'workflow_dispatch'` guard on the save steps means no new
  ones are created; this is a one-time cleanup:

  ```fish
  # dry run — list what would go
  gh api --paginate '/repos/hogdanish/hogdot/actions/caches?per_page=100' \
    --jq '.actions_caches[] | select(.ref | test("refs/tags/cg-v")) | [.id, .ref, .key] | @tsv'
  # then delete
  gh api --paginate '/repos/hogdanish/hogdot/actions/caches?per_page=100' \
    --jq '.actions_caches[] | select(.ref | test("refs/tags/cg-v")) | .id' |
    while read -l id; gh api -X DELETE "/repos/hogdanish/hogdot/actions/caches/$id"; end
  ```

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
