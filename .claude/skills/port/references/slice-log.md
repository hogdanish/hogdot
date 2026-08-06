# Port slice log — living, append-only

One entry per slice as it lands. **Append in the same change as the port commit**, never as follow-up
work. This is the only place a future rebase-forward learns what already hurt and why.

⚠ **Never delete or rewrite an entry.** If a later slice invalidates an earlier finding, add a new entry
that says so and link it. A wrong-but-recorded finding is recoverable; a deleted one is not.

## What an entry must contain

- **Slice / date / commit** — the `Webgpu-Port:` trailer name, the date, and the resulting SHA(s).
- **Adapted** — every hunk that could not be applied as written. What the fork did, what 4.7.1 changed,
  why the version that landed differs. This is the expensive-to-reconstruct part.
- **Dropped** — every hunk deliberately not carried, with the reason (unrelated refactor · 4.7.1 already
  does it · fork-only asset). ⚠ Required by `.claude/rules/port-provenance.md`; an unrecorded drop is
  indistinguishable from an oversight.
- **Gotchas** — anything that cost a debugging cycle. Verbatim, with the ⚠ marker.
- **Verification** — which tier the slice actually reached: applied / compiles / links / runs / renders
  (`.claude/rules/verification.md`). Say the real one, not the hoped-for one.

## Template

```markdown
### <slice-name> — YYYY-MM-DD — <short SHA(s)>

**Source:** `<fork SHAs from git log 4.6.2-stable..webgpu/webgpu-4.6.2 -- <path>>`
**Verification:** applied | compiles | links | runs | renders

**Adapted**
- `path/to/file.cpp` — fork did X; 4.7.1 changed Y; landed as Z because …

**Dropped**
- `path/to/file.py` — <hunk>; reason: unrelated refactor / already upstream / not needed by hogdot.

**Gotchas**
- ⚠ …
```

---

## Entries

### phase-1 imports — 2026-08-06 — `b8ad8d2` `038c142` `d3cc2af` `813189e` `f360a6c` `e23bbe1` `7d5f060`

All additive content, imported as seven commits. Nothing here is adapted — imports are `git checkout`
operations, so everything landed verbatim.

**Source:** `f8b3cd0` (all three vendored trees) · `f329e39 f8b3cd0 137a252 04713bd 724b19f 3e0c67d`
(drivers/webgpu) · `f329e39 9045dea 84e39ea f8b3cd0 d934796 11070d2` (webgpu_tests) ·
`191d7d5 7f501e8` (html shell) · `f329e39 f8b3cd0 04713bd fd5f8c8 d1da774 5722105 4d1c03c 3e29284`
(clean mods)
**Verification:** compiles — vanilla macOS editor built before the imports (2,890 objects) and again
after; see the build baselines in the `build-export` skill.

**Dropped**
- `webgpu_notes/` (50 files) and `webgpu_site/` (5 files) — standing decision in `ROADMAP.md`; already
  vendored as `.claude/skills/godotwebgpu/references/`. Carrying them in-tree would duplicate 1.2 MB
  of prose into the engine.
- `.github/copilot-instructions.md` — the fork's AI-assistant instructions. hogdot has its own
  `.claude/` framework; carrying this would install a second, conflicting set of instructions.
- `thirdparty/spirv-headers/include/spirv/unified1/spirv.hpp11` — the sole collision. Mainline's copy
  kept; upstream code already compiles against it and its tree is the newer of the two. ⚠ Revisit in
  Phase 2 only if Tint fails to compile against it; the fallback is the fork's copy.

**Deferred (not dropped — these still have to land)**
- `modules/glslang/config.py` → **Phase 2**, with the SConstruct `webgpu` option. See RL-003.
- `servers/rendering/renderer_rd/shaders/canvas_uniforms_inc.glsl` → **slice 3**, with
  `renderer_canvas_render_rd.cpp`.
- `GODOT_README.md` → **slice 8 (meta)**. Additive, but it only makes sense together with the
  `README.md` conflict: the fork moved Godot's README aside to install its own.

**Gotchas**
- ⚠ **"Clean" means mainline did not touch the file — it does NOT mean the hunk is independently
  applicable.** `port-surface.sh` classifies by upstream churn and knows nothing about semantic
  coupling. Two of the 13 clean mods are coupled to *conflict* files in later slices and break the
  build or the renderer if landed alone. Check every clean mod for a counterpart before assuming it
  is free:
  - `canvas_uniforms_inc.glsl` shifts SET3 texture bindings from `0..3` to `1..4` to reserve binding
    0 for the WebGPU push-constant ring buffer. Mainline's `renderer_canvas_render_rd.cpp` still
    binds `0..3`, so landing the shader alone fails `uniform_set_create` and kills all 2D rendering
    on **every** RD backend, editor UI included.
  - `modules/glslang/config.py` adds `env["webgpu"]` to `can_build()`. It is invisible on macOS
    purely because Python short-circuits `or` and `env["vulkan"]` is True; on the web platform
    vulkan/d3d12/metal are all False, so it evaluates and raises `KeyError`. This would have broken
    the vanilla web baseline — the very build meant to prove the toolchain innocent.
  - `skeleton.glsl` looks coupled and is **not**: it renames the `pad1` push-constant field to
    `bone_offset` and adds it to the bone index, but mainline already sets `pad1 = 0`, so it reads
    zero and behavior is unchanged until `mesh_storage.cpp` lands in slice 2. Landed in Phase 1.
- ⚠ **Four additive paths are not in the phase-1 brief's import list** and needed their own calls:
  `GODOT_README.md`, `misc/dist/html/webgpu-full-size.html`, `.github/workflows/webgpu_tests.yml`,
  `.github/copilot-instructions.md`. Re-derive the full additive set from `port-surface.sh` rather
  than trusting the brief's enumeration.
- ⚠ **BSD `xargs` has no `-a`.** Use `xargs -0 … < file` with `git diff --name-only -z` when checking
  out file lists of this size.
- ⚠ **`port-surface.sh` does not measure progress and never will.** It diffs
  `FORK_POINT`↔`WEBGPU_REF` against `FORK_POINT`↔`UPSTREAM_BASE` — three *tags*, no `HEAD` anywhere.
  The counts are identical before and after an import, by design: it describes the fork delta, not
  how much of it has landed. To check what is still missing, test the working tree directly:
  ```bash
  git diff --no-renames --name-only --diff-filter=A 4.6.2-stable webgpu/webgpu-4.6.2 \
    | while read -r f; do [ -e "$f" ] || echo "$f"; done
  ```
  After Phase 1 that lists exactly 61 paths: 54 `webgpu_notes/`, 5 `webgpu_site/`,
  `.github/copilot-instructions.md` (all dropped) and `GODOT_README.md` (deferred to slice 8).
  1,447 − 61 = **1,386 additive files imported**.
- ⚠ **`drivers/webgpu/` is NOT clang-format clean and must stay that way until Phase 5.** The
  pre-commit config's global `.*thirdparty/.*` exclude covers the vendored trees, but not
  `drivers/webgpu/` or `webgpu_tests/`. Running the formatter on it rewrites ~1,667/−1,009 lines,
  2,421 of them in `rendering_device_driver_webgpu.cpp`. Doing that before the driver is adapted to
  the 4.7.1 API would make `git diff` against `webgpu/webgpu-4.6.2` useless, and that diff is how
  every adaptation gets reviewed and justified. Format once, mechanically, after Phase 4. Lint with
  `--files` while porting, not `--all-files`.
- ⚠ **SCons passes NO environment to the compiler.** Godot rebuilds `env["ENV"]` from scratch and
  copies only what its `import_env_vars` option names. Any `FOO=bar scons …` is silently ignored by
  every tool the build spawns. This is why ccache appeared broken for most of Phase 1 (it ran, but
  without `HOME`, so it used `~/Library/Caches/ccache` instead of the configured 30G cache) and it
  applies equally to `EM_CACHE` on web builds. Whenever a build-spawned tool ignores an environment
  variable, check `import_env_vars` before anything else. Full recipe in the `build-export` skill.
- ⚠ **A green build says nothing about the shader edits.** Godot embeds `.glsl` as source in
  `*.glsl.gen.h` and compiles it with glslang at **runtime**. The 6 shader files landed in
  `7d5f060` reached *compiles* for free and are genuinely unverified until something draws with
  them — Phase 2's boot gate is the first real test. The `verification` rule now says this.

### driver-fixup — 2026-08-06 — `1c9e8e4` (+ `e47c69a` CODEOWNERS prerequisite)

**Source:** adapts the `813189e` driver import to 4.7.1 rather than carrying a fork hunk; checklist
from `.claude/work/plans/research/api-drift.md`.
**Verification:** **compiles + links (web).** `scons platform=web target=template_debug webgpu=yes
opengl3=no threads=no` builds all 5 `drivers/webgpu/` objects and all 5 RD-core objects and produces
`bin/godot.web.template_debug.wasm32.nothreads.zip` (9.7 MB) — a full template link, which the Phase 2
gate treats as a bonus tier rather than a requirement. emdawnwebgpu is genuinely linked: the shipped
`wrapped.js` contains `navigator.gpu` / `requestAdapter`.
⚠ **Nothing here has been run.** No browser has loaded this template; first boot is Phase 4's gate.
Native regression re-checked after this commit: macOS editor rebuilds clean (0 errors, 0 warnings)
and boots headless — see the flakiness note below before trusting a single boot run.

**Adapted** (all of this is hogdot-authored adaptation, not fork code)
- `rendering_context_driver_webgpu.{h,cpp}` — `DisplayServer::VSyncMode`/`VSYNC_ENABLED` →
  `DisplayServerEnums::…` (3 sites). 4.7.1 split the enums into
  `servers/display/display_server_enums.h`; the base header already includes it, so no new include.
- `rendering_context_driver_webgpu.{h,cpp}` — the **9 new HDR-output pure virtuals**. Stubbed:
  setters discard, getters return fixed SDR values (200.0f reference / 1000.0f max / 100.0f linear
  scale, matching `RenderingContextDriverVulkan::Surface`'s defaults) and
  `surface_get_hdr_output_max_value` returns **1.0f**.
- `rendering_device_driver_webgpu.{h,cpp}` — `swap_chain_get_color_space` →
  `COLOR_SPACE_REC709_NONLINEAR_SRGB`, `swap_chain_get_hdr_output_supported` → `false`.
- `rendering_device_driver_webgpu.{h,cpp}` — `command_pipeline_barrier` gains the 7th parameter. Still
  a no-op.
- `rendering_device_driver_webgpu.{h,cpp}` — the **14 raytracing pure virtuals**, all stubs returning
  invalid IDs / 0 / false, mirroring the driver's existing `buffer_get_device_address` treatment.
- `rendering_device_driver_webgpu.cpp` — **two toolchain fixes, not API drift** (see gotchas):
  `#include <cstdio>` for `snprintf`, and `_fence_work_done_callback` gaining Dawn's new
  `WGPUStringView p_message` parameter.
- `rendering_device_driver_webgpu.cpp` (`set_object_name`) — a `default:` case. 4.7.1's two new
  `ObjectType` enumerators hit an exhaustive switch with no default and warn under `-Wswitch`.
  ⚠ `api-drift.md` had claimed this needed no change because the fork "stubs `set_object_name` as a
  no-op" — **it does not**; it propagates labels to Dawn through a real switch. That research file is
  now corrected in place.
- **8 include paths normalized by `validate-includes`** (`"webgpu_objects.h"` →
  `"drivers/webgpu/webgpu_objects.h"`, and 7 like it). Applied by Godot's own lint hook, not by hand.
  See the gotcha below for why these were kept when clang-format's are not.

**Gotchas**
- ⚠ **Four of `api-drift.md`'s open checklist items needed no work at all**, and each was cheap to
  settle by grep. All four are now marked VERIFIED in that file. Do this *before* writing code:
  `api_trait_get` already ends in `default: return RenderingDeviceDriver::api_trait_get(...)`;
  `has_feature` already ends in `default: return false`; both `switch (uniform.type)` blocks already
  have a `default:` (and `-Werror` is off by default anyway, `SConstruct:1032`); and
  `rg 'workarounds' drivers/webgpu/` returns **nothing**, so the removed `Workarounds` struct was
  never referenced.
- ⚠ **Emscripten 6.0.5 drift is real and the roadmap's warning earned its place.** Dawn's
  `WGPUQueueWorkDoneCallback` gained a `WGPUStringView message` parameter between the 5.0.0 the fork
  shipped on and 6.0.5 — the fork's 3-arg callback no longer matches. **Adapting was right; falling
  back to the pinned emsdk 5.0.0 would have been wrong.** hogdot is a long-term fork and must track a
  current toolchain, the fix is 1 line, and the fork itself already chased one round of this
  (`7f501e8 webgpu: fix Emscripten 5.x Dawn API changes`). Note the shape: the *other* Dawn callbacks
  in this file (e.g. `_timestamp_readback_callback`) **already** take `WGPUStringView` — Dawn was
  making the family consistent, so that is the pattern to copy when the next one drifts.
- ⚠ **`snprintf` undeclared is a transitive-include regression, not a port bug.** The fork relied on
  something else pulling in `<cstdio>`; on this toolchain nothing does. Expect more of this class from
  a 4-year-younger libc++, and fix it with the include rather than reaching for the emsdk fallback.
- ⚠ **`webgpu=yes` runs two host-side build steps before one driver object compiles** — a full native
  build of `bin/tint_convert_cli` (~570 objects) via `tint_cli/build.sh`, then `wgsl_precompile.py`
  shelling out to `glslangValidator` over 70 shader files. Neither respects SCons flags. Both are
  written up in the `build-export` skill; the second one needs a Homebrew `glslang` that was not
  installed until this slice.
- ⚠ **The headless editor boot crashed once in 7 runs, at teardown, and did not reproduce.** Observed
  2026-08-06 on `1c9e8e4`: signal 11 *after* `loading_editor_layout` reported DONE, preceded by
  `ERROR: Parameter "singleton" is null. at: is_cmdline_mode (editor/editor_node.cpp:6618)` and
  `WARNING: A Thread object is being destroyed without its completion having been realized`. Six
  subsequent runs — three on fresh projects, three re-opening the *same* project that crashed — were
  all clean. **Do not attribute this to the port without new evidence:** it is an EditorNode shutdown
  race, and headless runs the **dummy** rendering driver, so no RD-core or WebGPU code executes at
  all. Recorded because it happened on hogdot's binary and an unrecorded crash is worse than a noisy
  one. ⚠ **Run the boot check more than once** — a single green run would have hidden this, and a
  single red one would have caused a false regression hunt.
- ⚠ **`validate-includes` is safe on `drivers/webgpu/`; `clang-format` still is not.** The phase-1
  gotcha ("`drivers/webgpu/` is NOT clang-format clean and must stay that way until Phase 5") is about
  *reviewability*: clang-format rewrites ~2,676 lines and destroys the diff against
  `webgpu/webgpu-4.6.2` that every adaptation is justified from. `validate-includes` changed **8
  lines**, all of them include-path normalizations required by Godot's own convention, and the diff
  stays perfectly readable — so these were kept rather than reverted. ⚠ **Run
  `SKIP=clang-format pre-commit run --files …` on these paths**, not a bare `--files`, which will
  silently reformat everything you pass it.
- ⚠ **The rest of `drivers/webgpu/` is still un-normalized.** Only the four files this slice touched
  got the include fix, so the tree is deliberately half-done. Finish it in the same mechanical pass as
  clang-format after Phase 4 — don't do it piecemeal.
- ⚠ **A byte-identical rebuild is not a skipped rebuild.** After the include rewrite, SCons recompiled
  both `.cpp` files in 3.4 s and then did **not** relink. That is correct: ccache produced
  byte-identical objects, so SCons's content signature saw no downstream change. Don't read a
  suspiciously fast "done building targets" as a build that failed to notice your edit — check the
  `Compiling …` lines in the log.
- ⚠ **The precompile step's Tint failures are non-fatal and the build stays green.** This run logged
  11 GLSL failures and 13 Tint failures out of 193 modules and still emitted 141 entries. `error:`
  lines in a `webgpu=yes` log are therefore **not** proof of a broken build — filter for
  `<file>.cpp:<line>: error:` before concluding anything. The dropped variants (subpass `textureLoad`
  on `input_attachment`, several `OpFunctionCall` type-mismatch validation failures) are real gaps to
  chase in Phase 5, not now.

### thirdparty-collision (supersedes the phase-1 collision decision) — 2026-08-06 — `ef55f41`

**Source:** `f8b3cd0`
**Verification:** compiles — the error below is gone and the vendored SPIRV-Tools objects build.

⚠ **This entry corrects the `phase-1 imports` entry above.** That entry dropped
`thirdparty/spirv-headers/include/spirv/unified1/spirv.hpp11` on the reasoning that mainline's copy
was kept because "upstream code already compiles against it and its tree is the newer of the two."
**The second half was wrong.** The first `scons platform=web webgpu=yes` build failed on it:

```
thirdparty/spirv-tools/source/opt/reflect.h:48:29: error: no member named 'OpMemberDecorateIdEXT' in 'spv::Op'
thirdparty/spirv-tools/source/opcode.cpp:126:19: error: no member named 'OpSpecConstantDataKHR' in 'spv::Op'
thirdparty/spirv-tools/source/opcode.cpp:157:19: error: no member named 'OpConstantSizeOfEXT' in 'spv::Op'
```

The **fork's** copy is the newer drop (5,681 lines vs 5,586). The Phase 1 entry's prediction that
this fallback might be needed was right; its guess about which copy was newer was not.

**Adapted**
- Nothing — a straight `git show webgpu/webgpu-4.6.2:<path> > <path>`.

**Gotchas**
- ⚠ **Prove "newer" before choosing a collision winner; line count and tree recency are not
  evidence.** The cheap, decisive check for a generated header is a set-difference over its
  identifiers:
  ```bash
  rg -o '^\s+([A-Za-z][A-Za-z0-9_]*)\s*=' -r '$1' <file> | sort -u
  comm -23 main_ids.txt fork_ids.txt   # anything here is a REMOVAL — the actual risk
  ```
  It returned empty (43 additions, 0 removals), which is what made the swap safe for mainline's
  glslang — the other consumer of this header (`thirdparty/README.md:429`). Do this *before*
  spending a build.
- ⚠ **`git diff` deletions in a generated SPIR-V header are usually not removals.** This swap shows
  `-10` lines, all of them `case Op::…:` labels moving position inside the generated
  `HasResultAndType`/`*ToString` switches as new opcodes are inserted above them. Read the deleted
  lines rather than trusting the `+/-` counts.
- ⚠ **A collision file can compile fine on one platform and not another.** Mainline's copy built the
  macOS editor and the vanilla web template without complaint through all of Phase 1 — SPIRV-Tools
  is only ever compiled when `webgpu=yes`, so the collision could not surface until the first
  WebGPU-enabled build. Expect the same shape from any other vendored-tree decision.

### build-wiring — 2026-08-06 — `9a6dde4`

**Source:** `69a9b2f dd41f4c`
**Verification:** configures — `scons platform=web target=template_debug webgpu=yes opengl3=no
threads=no --help` reads every SConscript clean and reports `module_glslang_enabled: True`; macOS
configure unaffected; `pre-commit run --files` clean on all four files. Nothing compiled yet.

A minimal subset of slices 5–6 pulled forward (see the sequencing refinement in the `port` skill) so
the compiler can referee the driver adaptation instead of errors surfacing two phases late.

**Adapted**
- Nothing. All four hunks applied at unchanged anchors.

**Dropped**
- `platform/web/detect.py` — the `use_assertions` rework (fork `ae510cf`): `BoolVariable` → 4-state
  `auto|no|yes|extra`, plus moving `--profiling-funcs` from `debug_features` to `debug_symbols`.
  Mainline implemented the same feature itself in `ba3401f81f`; 4.7.1's `detect.py:44–156` is
  **byte-identical** to the fork's version of that block. Nothing left to carry.

**Gotchas**
- ⚠ `detect.py`'s fork delta is now **fully resolved**, not partially. Besides the two WebGPU hunks
  the brief named (`supported: ["webgpu"]` and the `env["webgpu"]` block) there is a third,
  non-WebGPU hunk — `-sABORTING_MALLOC=0` (fork `dd41f4c`). It was carried here rather than left for
  Phase 4: Emscripten already implies it under `ALLOW_MEMORY_GROWTH=1`, so it is documentation, and
  taking it avoids stranding one line of an otherwise-finished file. **Phase 4 has no detect.py work
  left.**
- ⚠ **`scons … --help` is a cheap configure-only gate.** Godot's SConstruct runs platform detection
  and every `config.py` before printing help, so it proves an option is declared, a module's
  `can_build()` evaluates, and no SConscript raises — in seconds, with nothing compiled. Use it
  before committing build-system changes rather than starting a real build to find a `KeyError`.
- ⚠ `module_glslang_enabled: True` in that output is the **option's value**, not the outcome of
  `can_build()`. It does not by itself prove the glslang fix worked; the proof is that the configure
  completes at all, since the un-fixed `config.py` raises `KeyError: 'webgpu'` on web.

### rd-core — 2026-08-06 — `c6e453e` (+ `3412db9` lint prerequisite)

**Source:** `574b868 0961c8c 5722105 538f7a8 a0572ce 8887b77 d03b18d babf4f3 00f2cd3 967feb2 4b3a31b fd5f8c8 bdfa1de 4d9d3b6`
**Verification:** **compiles + links + boots (native, dummy renderer).** `scons platform=macos
target=editor arch=arm64` — 0 errors, 0 warnings, 4m02s, 133 MB binary.
`-e --path <trivial project> --headless --quit-after 5` exits 0 after a full filesystem scan and
editor-layout load. `pre-commit run --files` clean on all five files.
⚠ **Headless boots the dummy rendering driver — this run exercises no RenderingDevice code at all.**
Everything in this slice is therefore *compiled*, not *executed*. Say so; do not let a green
headless boot stand in for a native RD regression check. The first real exercise is Phase 3's
windowed Mobile-renderer gate.

**Adapted**
- `servers/rendering/rendering_device.cpp` (`_texture_initialize_layered`) — the fork's new function
  calls the **6-arg** `command_pipeline_barrier`. 4.7.1 gave that virtual a trailing
  `VectorView<AccelerationStructureBarrier>` for raytracing; landed as the 7-arg form with an empty
  `{}` view, matching every mainline call site. This is the single real signature hazard
  `research/upstream-churn.md` predicted for this slice, and the only one that materialised.
- `servers/rendering/rendering_device_driver.h` (`ApiTrait`) — the fork inserts its 8 new traits
  directly after `API_TRAIT_TEXTURE_OUTPUTS_REQUIRE_CLEARS`; 4.7.1 added 4 raytracing traits at
  exactly that point. Landed **appended after** mainline's four instead, so no mainline enumerator is
  renumbered. Safe: `ApiTrait` is never serialized and only ever used symbolically through
  `api_trait_get()`.
- `servers/rendering/rendering_device.cpp` (buffer-trait fast paths) — `research/upstream-churn.md`
  warned these would need re-targeting because mainline split `buffer_update` into a wrapper plus a
  private `_buffer_update(Buffer *, …)`. **It did not.** The split touches `buffer_update` only; all
  five `buffer_create`/`_buffer_initialize` pairs (storage/texture/vertex/index/uniform) are intact
  at their fork anchors and took the hunks verbatim. The five new public helpers went in after the
  new `buffer_update` wrapper, before `driver_callback_add`, exactly as the fork placed them.

**Dropped**
- `servers/rendering/rendering_device.cpp` (`texture_update`) — a body-less
  `if (gpu_pixel_size > 0) { /* comment */ }`. Zero semantics; leftover scaffolding. See ledger
  **RL-007**. The two working lines of that hunk landed unchanged.
- `servers/rendering/rendering_device.cpp` — two pure-whitespace hunks in `texture_create` (a blank
  line removed after `// Create.`, another before `return id;`). Diff noise with no content; carrying
  them would only widen the delta against mainline at the next rebase-forward. Same class as ledger
  RL-004.
- `servers/rendering/rendering_device.cpp` — the fork's `#include "core/os/os.h"`. Mainline 4.7.1
  already includes it (`rendering_device.cpp:39`); the hunk is a no-op, not an omission.

**Gotchas**
- ⚠ **The fork's `_end_frame` staging-unmap loop is a native-backend hazard, and its own comment is
  wrong about it.** It claims the loop "is a no-op on Vulkan/Metal"; it is not, and the map/unmap
  counts do not balance — staging blocks are mapped exactly once at creation and their `data_ptr` is
  cached for life. Carried faithfully; full analysis and evidence in ledger **RL-005**. This is the
  first thing to suspect if the native editor misbehaves after this slice.
- ⚠ **`port-surface.sh --conflicts` says "conflict", not "hard".** Four of this slice's five files
  (`rendering_device.h`, `rendering_device_graph.cpp/.h`, and most of `rendering_device.cpp`) applied
  at unchanged anchors despite mainline's very large churn, because mainline's growth here is
  raytracing plumbing that sits *beside* the fork's hunks rather than through them. Read the churn
  report's per-file verdict before budgeting time for a "39-conflict" file.
- ⚠ **`mainline already did it` is a real category in this slice too**, not just in `detect.py`.
  Check every fork hunk against 4.7.1 before writing it: the `core/os/os.h` include above was already
  there, and the 7-arg barrier form was already at every mainline call site.

### storage-rd — 2026-08-06 — `31a5484`

**Source:** `137a252 992787e fd5f8c8 00f2cd3 374b36a 8711742 16ffdd7 1493bba c244ae9 025ebf3`
**Verification:** **compiles + links (native).** `scons platform=macos target=editor arch=arm64` —
0 errors, 0 compiler warnings, 5m03s. (The 2 "warnings" in the log are SCons's pre-existing
accesskit/ANGLE optional-dependency notices, not compiler output.) `pre-commit run --files` clean on
all five files. Reached *runs* later, as part of the phase gate.

**Adapted**
- `light_storage.cpp` (`light_omni_get_shadow_mode`) — the fork's inserted
  `return RS::LIGHT_OMNI_SHADOW_DUAL_PARABOLOID;` requalified to `RSE::`. ⚠ **This hunk applies
  textually clean and does not compile** — `git apply --3way` reported success on the file. The
  `RS::`→`RSE::` rename that 4.7.1's RenderingServerEnums split introduced changed the *function's
  return type* around the fork's inserted line, not the line itself. `research/upstream-churn.md`
  predicted exactly this and was right.
- `mesh_storage.cpp` (`update_mesh_instances`) — the only real 3-way conflict in the slice, and pure
  rename noise: mainline renamed `RS::BLEND_SHAPE_MODE_NORMALIZED` on the line above the fork's
  `pad1`→`bone_offset` repurposing. Took mainline's spelling with the fork's assignment.
- `light_storage.h` — mainline inserted six area-light virtuals between `light_omni_get_shadow_mode()`
  and `light_get_type()`, which is where the fork adds `is_force_omni_dual_paraboloid()`. Placed the
  accessor *after* mainline's block rather than inside it, so mainline's virtuals stay one contiguous
  run and the next rebase-forward sees a smaller diff.
- `texture_storage.cpp` — nothing. All five hunks applied at unchanged anchors despite mainline's
  +824/−80, exactly as the churn report predicted.

**Gotchas**
- ⚠ **`git apply --3way` per-file is the right tool for this port, but "applied cleanly" is not
  "correct".** It resolves *text*; the `RS::`→`RSE::` rename is a semantic change whose collisions
  are invisible to it. **After every apply, sweep the added lines for both renames** before building:
  ```bash
  git diff HEAD -- <paths> | grep '^+' | grep -E '\bRS::|\bDisplayServer::'
  ```
  That one command found the `light_storage.cpp` must-fix and would have found the `mesh_storage.cpp`
  one had the 3-way not already flagged it.
- ⚠ **Both new behaviors are gated on RD capability queries that the base driver did not answer.**
  `use_skeleton_atlas` and `force_omni_dual_paraboloid` read `API_TRAIT_SKELETON_BUFFER_DIRECT_WRITE`
  / `API_TRAIT_FORCE_OMNI_DUAL_PARABOLOID`, which return 0 on Vulkan/Metal so the native paths are
  untouched — but reaching that 0 went through `ERR_FAIL_V` and printed. See ledger **RL-016**, fixed
  in `4dc5bbb`.
- ⚠ **The skeleton atlas has two latent defects, both carried faithfully** — ledger **RL-011** (bump
  allocator never reclaims a slot, so create/destroy cycles grow GPU memory without bound) and
  **RL-012** (growing the atlas reallocates the GPU buffer but only re-uploads *this frame's* dirty
  range, so static posed skeletons read garbage after some other skeleton triggers a grow). Both are
  WebGPU-only. Fix in Phase 5 where a browser run can demonstrate before/after.

### forward-mobile — 2026-08-06 — `f503e72`

**Source:** `ada05c7 bdfa1de fd5f8c8 e55806a 511d5fe 4b5116c e9505ca a1be3e2 d0deb8a 025ebf3`
**Verification:** **compiles + links (native)**, then **runs** at the phase gate. Only one 3-way
conflict in the whole slice, in `render_forward_mobile.cpp`, and it was rename noise.

**Adapted**
- `render_forward_mobile.cpp` (`_render_scene`) — the fork's `using_subpass_post_process = false`
  block sits directly above two lines mainline renamed to `RSE::ViewportMSAA`. Took mainline's
  spelling.
- `renderer_compositor_rd.cpp` (`blit_render_targets_to_screen`) — 4.7.1 rewrote blit to cache
  pipelines per framebuffer format and added four HDR fields, so the fork's hunk cannot apply. The
  single behavioral change — `draw_list_begin_for_screen(p_screen, Color(0, 0, 0, 1))`, which Dawn
  needs or the browser canvas composites translucent — was re-inserted by hand. ⚠ The churn report
  said the target line still called the color-less overload in 4.7.1, and it does: the overload takes
  a defaulted `const Color &p_clear_color` (`rendering_device.h:1549`), so this is a one-argument
  edit, not a signature change.
- `render_forward_mobile.h` / `.cpp` — **area lights excluded from the shadow-pass merge.** Added
  `SceneState::ShadowPass::mergeable` (default true), cleared for area-light passes in
  `_render_shadow_pass`, and required by both conditions of the merge loop in `_render_shadow_end`.
  Rationale and the Phase 5 follow-up are ledger **RL-010**. ⚠ Set the flag *after*
  `_render_shadow_append` returns, over the range of passes it pushed — that function already takes
  **18 parameters** and a 19th to carry one bool is not worth it.

**Dropped**
- `servers/rendering/renderer_viewport.cpp` — the fork's entire delta here is an inert `{ }` block
  left from a stripped diagnostic, and mainline moved its anchor (`&& vp->view_count > 0`). Zero
  functional content. Predicted LIKELY-DROP by the churn report; confirmed by reading it.
- `renderer_compositor_rd.cpp` — the fork also deletes the `// Window is minimized and does not have
  valid swapchain…` comment. Unrelated to WebGPU and the comment is accurate; mainline's kept.

**Gotchas**
- ⚠ **`instances.data[draw_call.instance_index]` is a cross-slice invariant, not a shader detail.**
  The fork's instance batching in this file is only correct because `scene_forward_mobile.glsl` reads
  `batch_instance_index` everywhere. Any mainline addition that reads `draw_call.instance_index`
  directly silently breaks batched draws — which is exactly what happened with area lights
  (ledger **RL-014**, fixed in the shaders slice). **When porting the batching code, grep the shader
  for `draw_call.instance_index` in the same sitting.**
- ⚠ **The batch predicate does not compare every field the shader reads.** It checks omni, spot,
  reflection-probe and decal counts but not `area_light_count`. That is what turns RL-014 from a
  missed optimization into a mis-render. Assume the same class of gap for any future per-instance
  array mainline adds.
- ⚠ **`canvas_uniforms_inc.glsl` landed in this commit, not Phase 1.** It is classified "clean" by
  `port-surface.sh` but is a matched pair with `renderer_canvas_render_rd.cpp`: the shader moves SET3
  texture bindings `0..3`→`1..4` to reserve binding 0 for the WebGPU push-constant ring buffer, and
  the `.cpp` moves the matching `RD::Uniform` indices. Either alone fails `uniform_set_create` and
  kills all 2D rendering on every RD backend, editor UI included. The Phase 1 deferral was correct
  and is now discharged.

### shaders — 2026-08-06 — `115dd64`

**Source:** `f329e39 fd5f8c8 d1da774 b2327be 697a9e7 e9505ca`
**Verification:** **applied only.** ⚠ Godot embeds `.glsl` as source into `*.glsl.gen.h` and compiles
it with glslang at *runtime*, so the native build that followed proves nothing about any line here.
`pre-commit run --files` is clean; that is a formatting claim, not a correctness one. First real test
is Phase 4's browser run.

**Adapted**
- `sdfgi_direct_light.glsl` — the slice's only 3-way conflict: mainline added
  `vec3 texture_color = vec3(1.0);` immediately below the sentinel the fork lowers from `1e20` to
  `1e6`. Both kept.
- `scene_forward_mobile.glsl` — **retrofitted mainline's new area-light loop to
  `batch_instance_index`** (ledger **RL-014**). This is the one place the slice deviates from the
  fork *and* from the phase brief, which said to leave it bypassing; `phase-3-renderer.md` has been
  corrected in the same change. It is a correctness fix, not an optimization: the batch predicate
  never compares `area_light_count`, so instances with different area lights can share a batch and
  would all read instance 0's bitfield. A no-op off WebGPU, where `gl_InstanceIndex` is 0.
- `blit.glsl` — the fork's hunk leaves a trailing blank line before the closing brace;
  `clang-format-glsl` removed it. The rest is the fork's verbatim.

**Gotchas**
- ⚠ **Two churn-report verdicts were wrong, both in the optimistic direction for us.**
  `scene_forward_clustered.glsl` was UNVERIFIED-suspected-RETHINK and applied clean;
  `scene_forward_mobile.glsl` was RETHINK on the grounds that a `modf`→`floor` hunk sat inside
  mainline's rewritten clearcoat block — mainline converted those lines to *half precision* but left
  the `modf` call and its surroundings intact, so the hunk applied. `research/upstream-churn.md` is
  corrected in place for both. **Read the mainline diff before budgeting time for a RETHINK verdict.**
- ⚠ **`port-surface.sh` cannot see a hazard mainline introduces in a file the fork never touched.**
  It classifies by *fork* delta. 4.7.1 added three `isnan`/`isinf` calls to
  `environment/volumetric_fog_process.glsl` — both intrinsics are unavailable in WGSL, and are
  precisely what the fork rewrote elsewhere. Zero occurrences in `4.6.2-stable` and zero in the
  fork's copy, so nothing flagged it. Ledger **RL-015**. **Standing check after every
  rebase-forward:**
  ```bash
  rg 'modf\(|isnan\(|isinf\(' servers/rendering/renderer_rd/shaders/
  ```
  That is how it was found, and it costs a second.

### phase-3 gate (native half) — 2026-08-06 — `4dc5bbb`

**Verification:** **runs (native, Metal, Forward Mobile).**
`bin/godot.macos.editor.arm64 --path webgpu_tests/test_project --rendering-method mobile
--quit-after 180` exits 0. Banner: `Metal 4.0 - Forward Mobile - Using Device #0: Apple - Apple M5`.
This is the first run in the whole port that executes RenderingDevice code — Phase 2's gate was
headless, which uses the **dummy** driver.

**How "no new errors versus vanilla" was actually established.** Reading the log is not enough; the
project emits 15 distinct diagnostics of its own. A real baseline was built:
```bash
git worktree add <tmp>/vanilla 4.7.1-stable && (cd <tmp>/vanilla && scons platform=macos target=editor arch=arm64 …)
diff <(grep -E '^(ERROR|WARNING)|^   at:' vanilla.log | sort) <(grep … hogdot.log | sort)
```
The two sets are **identical**, the sole difference being `finalize`'s line number
(`rendering_device.cpp:8900` vanilla vs `:9269` hogdot) — the port's own added lines shifting the
file. ⚠ **The 14 leaked `Texture` RIDs, the unfreed `ParticlesShaderRD` and the leaked
`MaterialStorage::Shader` at exit are all pre-existing 4.7.1 behavior with this project, not port
damage.** Without the baseline they read exactly like a regression, and chasing them would have
burned a session. The baseline binary is preserved at
`<scratchpad>/godot-vanilla-4.7.1.arm64` (the worktree was removed so no dangling git state remains;
the binary is self-contained and needs neither the worktree nor the source).

⚠ **`--rendering-method mobile` is required** — `webgpu_tests/test_project/project.godot` sets
`renderer/rendering_method="forward_plus"`, so a bare run does **not** exercise forward-mobile and
would have silently missed this slice entirely. The 11 "only available when using the Forward+
renderer" warnings are the expected consequence of running a Forward+-authored project on mobile,
and appear identically in vanilla.

**RL-005 did not fire.** The `_end_frame` staging-unmap loop carried in `c6e453e` was flagged as a
native-backend hazard and STATUS.md said to "expect it to break". It did not: 180 frames on Metal,
clean. That is evidence the loop is harmless on this backend, **not** proof the RL-005 analysis was
wrong — the map/unmap accounting concern it raised still stands and is still worth resolving. Leaving
RL-005 open.

**Gotchas**
- ⚠ **A trailing `grep -c` makes a green build report as failed.** `scons … > log 2>&1; echo EXIT=$?;
  grep -c "error:" log` exits **1** when the count is zero, and that becomes the command's status —
  the harness reported a successful 5-minute build as "failed with exit code 1". Put the `grep` in a
  separate call, or append `|| true`.
- ⚠ **Editing source while a background build runs produces an ambiguous result.** Files edited
  mid-build may or may not have been scanned yet. The fix is cheap — run a second incremental build
  and check its `Compiling …` lines actually name the files you changed — but the first build's
  green cannot be trusted for those files.

### phase-3 gate (web half) — 2026-08-06

**Verification:** **compiles + links (web).** `scons platform=web target=template_debug webgpu=yes
opengl3=no threads=no num_jobs=4` under `nice -n 10` — **0 compile errors**, 9m27s, producing
`bin/godot.web.template_debug.wasm32.nothreads.zip` (9.68 MB). The link was the gate's optional tier
and it succeeded, so Phase 4 inherits a template that already builds end to end.

Every file this phase touched compiled for web, verified by name in the log rather than inferred from
a green exit: all 5 `drivers/webgpu/` objects, `texture_storage.cpp`, `mesh_storage.cpp`,
`light_storage.cpp`, `render_forward_mobile.cpp`, `renderer_canvas_render_rd.cpp`,
`renderer_compositor_rd.cpp`, `effects/tone_mapper.cpp`.

**Gotchas**
- ⚠ **Grep for `<file>:<line>:<col>: error:`, not bare `error:`, in a `webgpu=yes` log.** The
  `wgsl_precompile.py` step legitimately logs GLSL and Tint failures for variants it cannot translate
  and the build stays green by design (already recorded in the `driver-fixup` entry). A bare
  `grep -c 'error:'` over this log counts those and reports a healthy build as broken.
- The `num_jobs=4` + `nice -n 10` discipline held: the machine stayed usable for the whole 9m27s while
  a second (native, `-j10`) build and two editor runs happened alongside it.

---

## Phase 4 — web platform & first boot (2026-08-06)

### slice 5 — `platform-web` — `880c7fc`

**Verification:** compiles (web + macOS), links, and **the export-plugin hunk is proven at runtime**
(the exported `index.html` carries `renderingDriver":"webgpu"`).

Four files; `detect.py` and `drivers/SCsub` were already fully resolved in Phase 2 and needed nothing.

- ⚠ **`display_server_web.cpp/.h` was predicted to be the hardest remaining file and it was not.**
  The churn report was right that a textual patch fails — the fork's ctor block sits between two
  heavily `DisplayServerEnums::`-renamed regions — but the block itself is byte-identical to 4.6.2,
  so all five hunks re-attached by hand in one pass. The only mechanical work was requalifying
  `MAIN_WINDOW_ID` to `DisplayServerEnums::MAIN_WINDOW_ID`.
- ⚠ **Two Phase-3 carry-over warnings closed with zero work, and both were worth the 30 seconds to
  check.** (1) `drivers/webgpu/` contains **no** `DisplayServer::` references at all, so the
  "`DisplayServerEnums::` prefix needed" warning had no target. (2) `window_set_vsync_mode` did not
  drift in any way that matters: `RenderingContextDriver::window_*` are **non-virtual base helpers**
  that already take `DisplayServerEnums::VSyncMode`, and `RenderingContextDriverWebGPU` overrides only
  the `surface_*` virtuals. **Re-derive a carry-over warning before acting on it** — both of these
  were written from a diff, and the code disagreed.
- ⚠ **The fork wraps the GLES3 block in `{ }` without re-indenting the body.** clang-format rejects
  that. Indented here; `pre-commit run` is clean on all four files. Behaviourally identical.
- `export_plugin.cpp`: no logical conflict, but mainline split `can_export` and renamed
  `SplashStretchMode`, so both hunks were re-inserted by hand.

### slice 6 remainder — `build-remainder` — `5829f06`

**Verification: applied only.** GitHub Actions does not run locally and nothing simulated it.

Adapted, not reapplied: the fork's two matrix entries predate mainline's `arch=wasm32`/`wasm64` split,
so copying them verbatim would have left the WebGPU jobs defaulting their architecture while every
sibling pinned it. Both take `arch=wasm32`. Action-version bumps and the `tests=no` removal needed
nothing — they live in the shared `steps`/`env` blocks the fork never touched.

### slice 7 — `core-odds` — `57be40c`

**Verification:** compiles + links, **both platforms**, all four files verified by name in both logs.

All four anchors were byte-identical to 4.6.2 despite mainline churn as large as +638/−535
(`display_server.cpp`) and +227/−101 (`main.cpp`). The churn report's "CLEAN-ISH" verdicts were
accurate across the board.

- ⚠ **`compressed_texture.cpp` hand-parses the `.ctex` header, so it had to be checked against the
  writer rather than assumed.** It skips magic + 8 × `get_32()`; 4.7.1 still writes exactly version,
  width, height, data format, mipmap limit and three reserved words. Verified against this tree's own
  reader before carrying. Ledger RL-018/RL-019 record what is wrong with the hunk regardless.
- **Dropped: `scene/resources/2d/tile_set.cpp`** — the fork's entire delta is one added blank line.
  Zero functional content, not carried, file stays at mainline.
- **Still deliberately not carried: `renderer_viewport.cpp`** (inert `{ }` stub, dropped in `f503e72`).

### test-project adaptation — `b55db0b`

- ⚠ **`webgpu_tests/test_project` never set `rendering_method.web`, so a web export ran
  gl_compatibility and did not touch WebGPU at all.** The boot gate would have gone green and proven
  nothing. Set to `mobile`. This is the third time this class of trap has appeared (Phase 3's
  `--rendering-method mobile`, and it will recur on the Phase 5 demo ladder) — **check the effective
  renderer before believing any WebGPU result.**
- ⚠ **Do NOT install hogdot templates into `~/Library/Application Support/Godot/export_templates/
  4.7.1.stable/`.** That directory already holds Ethan's stock Godot 4.7.1 templates, and hogdot
  reports the same `VERSION_FULL_CONFIG` (the `.custom_build` suffix is `VERSION_BUILD` and takes no
  part in template lookup). Installing there silently repoints every other 4.7.1 project on this
  machine. Use `custom_template/{debug,release}` instead.
- ⚠ **`custom_template` paths are resolved relative to the PROJECT directory, not the repo root**,
  because `--path` chdirs first. `bin/…zip` fails with "Custom debug template not found";
  `../../bin/…zip` works, and stays committable where an absolute path would not.
- Noted, not fixed: a preset that fails validation segfaults the headless editor during teardown
  (`is_cmdline_mode`, "Parameter singleton is null") *after* correctly printing the export error.
  Mainline 4.7.1 behavior on a path this port does not touch.

### phase-4 gate — 2026-08-06 — **PARTIALLY MET, 2 of 3 clauses**

**Verification: runs (browser), aborts before the main loop.**

| Gate clause | Result |
| --- | --- |
| Boots in Chrome | ✅ `Godot Engine v4.7.1.stable.custom_build.5829f0669` |
| **Creates the WebGPU device** | ✅ `WebGPU 1.0 - Forward Mobile - Using Device #0: Unknown - WebGPU Device` |
| Reaches the running main loop | ❌ WASM `unreachable` trap; the shell shows "unreachable" over the boot splash |

The first two clauses are the ones this phase's porting work was responsible for, and both passed on
the first attempt — the display server, the context driver, the device handshake and the JS-side
`preinitializedWebGPUDevice` import all work end to end. The third fails for a single, fully
identified reason that is **not** in this phase's slices.

**Root cause — one failure, repeated ~150 times.** Every failing shader is a compute shader (stage 4)
and every message is the same:

```
Tint SPIR-V→WGSL failed: error: var: vars in the 'storage' address space must have
access 'read' or 'read-write'
  %dst_vertices:ptr<storage, DstVertexData, write> = var undef @binding_point(0, 2)
```

WGSL permits only `read` or `read_write` in the storage address space; `write` is not a legal access
mode. Tint is faithfully translating SPIR-V `NonReadable` (GLSL `writeonly`) into something WGSL
cannot express. Skeleton and particles compute shaders fail, every dependent
`compute_pipeline_create`/`uniform_set_create` then fails on a null shader, and the engine traps.

**What it is not, established rather than assumed:**
- **Not upstream drift.** `writeonly` counts in `skeleton.glsl`, `particles.glsl` and
  `particles_copy.glsl` are **identical** at 4.6.2 and 4.7.1. The fork compiled these exact shaders.
- **Not a missing port hunk.** `spirv_preprocess.cpp` handles `NonWritable` (read-only) in three
  places and has **no `NonReadable` handling anywhere** — in the fork either. There is no hunk to
  have dropped.

**What it points at — ledger RL-009, upgraded from perf to blocker.** `wgsl_precompiled.gen.h` exists
(1.1 MB, 141 entries) and **does contain particles entries**, yet these shaders still reached runtime
Tint — so the table lookup missed. The table is generated at build time by `wgsl_precompile.py`
shelling out to Homebrew `glslangValidator` **16.5.0**, while at runtime Godot compiles GLSL→SPIR-V
with its own **vendored glslang 16.1.0**. Different SPIR-V blob → different hash → miss → live Tint →
invalid WGSL → abort. The miss is proven by observation; the version skew as its cause is a strong
hypothesis and is the first thing Phase 5 should test (pin `wgsl_precompile.py` to the vendored
glslang and see whether the table starts hitting).

⚠ **This retires a claim in the `build-export` skill that was actively misleading** — it said the
glslang version difference "costs cache hits, never correctness". A dead table does not degrade
gracefully here: it turns a cache miss into a hard abort, because nothing else in the pipeline can
produce valid WGSL for a write-only storage buffer. Corrected in the same change as this entry.

**Gotchas**
- ⚠ **`caddy file-server` must be killed explicitly at session end** (`pkill -f "caddy file-server"`);
  a backgrounded one outlives the turn that started it.
- ⚠ **`read_console_messages` is nearly useless against this failure without a negative pattern.**
  Each Tint error embeds a full WGSL disassembly, so 615 messages are ~150 real events and any
  positive filter returns page after page of struct dumps. Probe the live page with `javascript_tool`
  instead — `document.body.innerText` gave the actual outcome ("unreachable") in one call.
