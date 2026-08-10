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

---

## Phase 5 — runtime debugging (2026-08-06)

### The native shader-translation harness (build this first, every session)

Phase 4 debugged shaders through a 40 s web build plus a browser round trip. That is unnecessary:
**`drivers/webgpu/tint_cli/build.sh` produces `bin/tint_convert_cli`, a native macOS binary that runs
the exact same preprocessing passes plus Tint.** Reproducing RL-020 with it took seconds. Everything
below assumes it exists.

```bash
JOBS=6 nice -n 10 ./drivers/webgpu/tint_cli/build.sh     # ~570 objects; minutes cold, seconds warm
```

⚠ **`build.sh` was a machine hazard until `e8d8611`** — its throttle used `wait -n` (bash >= 4.3) and
macOS ships bash 3.2, so it spawned ~1,200 concurrent compilers. See RL-021. `wgsl_precompile.py`
runs this script from inside every `webgpu=yes` SCons build, so phase 4 already paid that cost.

**Getting a whole corpus in one command.** `wgsl_precompile.py` assembles 193 SPIR-V modules from the
engine's 70 registered shader files and pipes them all through `tint_convert_cli`; run it standalone
against a scratch output and every translation failure is named on stderr:

```bash
python3 drivers/webgpu/wgsl_precompile.py . /tmp/scratch.gen.h 2>&1 | rg "Tint error for"
```

This is the regression check for any change to a preprocessing pass or to Tint: capture the failure
list before and after and `comm` them. It caught both of this phase's fixes as strict improvements
(11 → 10 → 9) and would have caught a regression instantly.

**Three scratch tools worth rebuilding** (kept out of the repo deliberately — they are debugging aids,
not engine code; recipes here so they can be recreated in one turn):
- `tint_bisect.cpp` — same pipeline as `tint_cli/main.cpp` but takes a **13-character 0/1 mask**
  selecting which preprocessing passes run, plus `TINT_BISECT_DUMP=<path>` to write the post-pass
  SPIR-V. This is how `flatten_binding_arrays` was identified as the pass whose output triggered
  RL-023. Compile with `-Idrivers/webgpu/tint_cli -Idrivers/webgpu` + the Tint includes and link
  against every `.o` under `tint_cli/.build` except `cli/main.o`.
- `spv_tool.cpp` — `spvValidateBinary` + `spvBinaryToText` over the SPIRV-Tools objects already in
  `.build`. Answers "did a pass produce invalid SPIR-V?" directly. ⚠ For RL-023 the answer was **no** —
  the module validated cleanly and Tint still crashed, which is what redirected the search into Tint.
- A patched copy of the failing Tint source, compiled into the same link with the stock object
  excluded. Printing `type->FriendlyName()` at the assert gave `spirv.image<...>` in one run and
  turned a guessing game into a five-minute diagnosis. ⚠ **Do this early.** Three fixture-based
  guesses beforehand all passed and proved nothing.

⚠ **`git stash` around a shader-pass change is the cheapest before/after** — stash, rebuild the CLI
(3 files), run the corpus, pop, rebuild. Two minutes for a real regression baseline.

### RL-020 — write-only storage buffers (fixed, `23f4c20`)

New pass `strip_writeonly_storage` drops `NonReadable` from StorageBuffer variables and from the
members of types StorageBuffer pointers point at. ⚠ **It must not touch storage images**: WGSL storage
textures *do* have a `write` access mode and it is their default, so a blanket strip breaks every
`writeonly image2D`. Both directions are covered by fixtures. Runs **before** `infer_readonly_storage`
so a buffer that is neither read nor written still ends up `read`.

⚠ **RL-009's glslang-skew hypothesis was never needed.** The ledger nominated "pin `wgsl_precompile.py`
to the vendored glslang" as the cheap first test; the durable repair (a preprocessing pass) turned out
to be just as cheap and fixes shaders absent from the table too. RL-009 returns to a perf-only concern.

⚠ **The precompiled table is not rebuilt when a preprocessing pass changes.** SCons does not list
`spirv_preprocess.cpp` as a dependency of `wgsl_precompiled.gen.h`, so after editing a pass the table
still holds WGSL produced by the *old* passes. Harmless here (the entries were already stale from the
hash skew), but it is a live correctness trap the moment the table starts hitting — see RL-009.

### RL-023 — Tint aborts on the main scene shader (fixed, `7c6029c`)

`TINT_ASSERT(tex_ty)` in `spirv/reader/lower/texture.cc`, translating
`scene_forward_mobile.glsl:color_pass:frag`. Full mechanism in the ledger. Two things to carry forward:

- ⚠ **It is 4.6.2→4.7.1 drift, and the check that proved it is one command:**
  `git cat-file -e 4.6.2-stable:<path>` and the same against `webgpu/webgpu-4.6.2`.
  `area_lights_inc.glsl` exists on neither. **Run that check before assuming a dropped hunk** — it is
  the fastest way to separate "the fork never had this" from "we lost something".
- Area lights are turning into the recurring 4.7.1 theme: RL-010 (shadow atlas), RL-023 (LTC helpers).
  Expect the next one there too.

Carried as `thirdparty/tint/patches/0007-*`, following the fork's existing six-patch convention.
⚠ **Patch the vendored source *and* regenerate the `.patch` file *and* add the README table row** —
`patches/README.md` is how the next Tint re-vendor knows what to reapply.

### The four blockers between "boots" and "renders" (fixed, `41ddc3b` `6539e48`)

`webgpu_tests/test_project` **renders in Chrome on WebGPU with zero GPU validation errors** as of
2026-08-06. Getting there took four fixes in one chain; RL-026…RL-028 hold the detail. What is worth
carrying forward is the *shape* of the chain, because the next one will look the same.

**Each fix unmasked the next.** Nothing rendered, and the engine reported no error of its own — every
symptom lived in Dawn's validation messages. The order was: sampler cap → storage-buffer cap →
depth-vs-filtering-sampler → uniform minimum binding size. Four rebuild-and-look cycles, ~40 s each.
⚠ **Do not read "one error class gone" as "fixed"** — read it as "the next one is now visible".

⚠ **Console flooding destroys the evidence.** Once pipelines are invalid, the driver logs two errors
per draw call and the DevTools ring buffer (10,000 entries) evicts the *creation* errors that name the
real cause within a second or two. Reproduce with a **bounded** run — the coverage scene without
`?hold` quits after 10 frames and yields ~200 messages — then dedupe. `?hold` is only for looking at
the picture.

⚠ **Two dead naga-era mechanisms, both consumer-only.** `//SSBO_USED:` (per-stage storage-buffer
visibility) and `*_depth_alias` (splitting mixed-usage depth textures) are parsed by the driver and
produced by nothing — on our tree *and* on `webgpu/webgpu-4.6.2`. `rg <marker> webgpu/webgpu-4.6.2`
is the check. When a driver feature looks like it should already handle your bug, verify something
still emits its input before assuming the port dropped a hunk.

**The recipe that found RL-028** generalizes to any "Tint emitted something absurd" bug, and cost one
build each:
1. Print the WGSL declaration and struct body for the binding Dawn named. That gave `@size(7505u)`.
2. Print the same struct's `OpMemberDecorate … Offset` values straight from `s.code_compressed_bytes`
   — the shader container, before preprocessing. Correct there ⇒ the corruption is ours.
3. Drop a one-line sanity scan after **every** pass in `_translate_spirv_to_wgsl` and print the first
   pass whose output fails it. Named `flatten_binding_arrays` on the first run.

⚠ **`print_line()` beats `WEBGPU_DIAG`/`EM_ASM` for temporary diagnostics** — it reaches the browser
console through the normal Godot path and takes a `String`, so no pointer marshaling.

⚠ **The driver produces WGSL in two places.** `shader_create_from_container()` and
`_create_module_with_spec_constants()`, the latter re-running Tint on spec-constant-patched SPIR-V and
repeating only *some* of the former's passes — its comment says "must match
shader_create_from_container", which is a convention, not a mechanism. Adding a pass to one produced a
*new* error rather than a fix: the layout was built from rewritten WGSL, the specialized module was
not. **Any new WGSL pass goes in a shared helper called from both.**

Also landed: the deferred mechanical clang-format pass (`1be3ba0`), as its own commit now that
adaptation is done. `drivers/webgpu/` and `webgpu_tests/` are clang-format clean; the Phase 1
exception no longer applies.

**Regression evidence for the whole chain:** preprocessing_tests 191/0/1 · driver_unit_tests 327/0 ·
shader_corpus 13/0 · wgsl_cache 20 + 130 · the 193-module corpus unchanged at 173 compiled / 11 glsl
failures (RL-025) / 9 tint failures · web, macOS editor and native `tint_convert_cli` all build clean.

---

## Phase 7 — hardening, first batch (2026-08-06)

Seven fix commits against the Phase-6 queue. No port hunks: from here on hogdot deliberately
diverges from the fork, and each of these is hogdot-authored. Every one cites its ledger ID.

| commit | ledger | what |
| --- | --- | --- |
| `dc917d5` | RL-029 | inter-stage varying ceiling: engine.js limit request + varying repack |
| `845c61e` | RL-030, RL-033, RL-034 | the SPIR-V word tables in `spirv_preprocess.cpp` |
| `e886ff7` | RL-031 | clamp-to-edge in the depth texel-fetch rewrite |
| `2f3d721` | RL-015 | `isnan`/`isinf` in volumetric fog |
| `d69db15` | RL-001 | the 3e10 infinity threshold in `copy.glsl` |
| `37e82a2` | RL-011, RL-012 | skeleton atlas free list + grow re-upload |
| `7830eb6` | RL-029 gate | `varying_stress.gdshader`, 4 user varyings |

### The lesson worth carrying: a limit you do not request is a limit you do not have

RL-029 looked like a pure engine-side problem — "the renderer reserves 15 of 16 locations". Half of
it was, and half was that `platform/web/js/engine/engine.js` never asked for the locations the
adapter was offering. Measured in Chrome on apple/metal-3: **adapter `maxInterStageShaderVariables`
28, default device 16.** The nine limits in `limitsToMax` were raised at some point because something
broke; every limit *not* in that list is silently sitting at the WebGPU default.

⚠ **`limitsToMax` is a standing audit target.** When a WebGPU limit error appears, check that list
before touching the engine — the adapter may already offer what you need. `webgpureport.org` plus a
two-line `requestAdapter`/`requestDevice` comparison in the console answers it in one round trip, and
the two numbers are routinely different.

### Deriving a table instead of hand-maintaining one

RL-030's fix was specified as "add the 18 missing opcode families". Generating the table from the
vendored SPIRV-Tools grammar (`thirdparty/spirv-tools/generated/core_tables_body.inc`) instead cost
about the same and produced 105 opcodes — and the extra 87 included two shapes a hand-list would not
have reached for: `OpDecorateId`/`OpExecutionModeId` need the **opposite** rule to `OpDecorate`
(their trailing operands are `<id>`s), and `OpGroupMemberDecorate` alternates id/literal pairs.

⚠ **It also found RL-033**, an off-by-one in the `OpSwitch` predicate that the phase-6 audit had
explicitly examined and passed. The audit checked it by reading; the grammar disagreed. When a
machine-readable spec for something is already vendored, check against *it*, and prefer generating
over transcribing.

### Verification reached this batch

Both builds clean: macOS editor after every C++ commit, and
`scons platform=web target=template_debug webgpu=yes opengl3=no threads=no num_jobs=4` in 6:39, zero
errors. Coverage scene exported and run in Chrome. **Zero GPU validation errors across the whole
169-message bounded run** — no `[Invalid RenderPipeline]`, no Dawn message of any kind. Suites at
baseline: `driver_unit_tests` 327/0, `preprocessing_tests` 191/0/1.

⚠ **Per-fix, the tiers differ, and two are lower than the queue asked for:**

| ledger | tier reached | evidence, and what is still missing |
| --- | --- | --- |
| RL-029 | **renders** | `[OK] Varying stress: … 4 user varyings x2`, no "Too many varyings", both toruses draw and their varyings visibly drive the shading (facing-driven orange→blue mix, wave-driven emission). This is the gate the queue demanded. |
| RL-030 / 033 / 034 | **runs, no regression** | Whole shader corpus translates, suites at baseline, zero validation errors. ⚠ **Not proof the new table entries fire** — RL-030 was never firing in the first place (the audit measured zero margin, not a live fault), so "unchanged" is exactly the expected result and cannot distinguish a correct table from an inert one. |
| RL-031 | **renders** | Shadows present under every casting object; no validation errors. ⚠ **Not compared to a native reference**, so the penumbra behavior the clamp restores is still unjudged — the same blind spot phase 6 recorded. |
| RL-001 | **renders** | `copy.glsl` is on the glow path, which Mobile does run. A threshold move from 3e10 to 3e38 is invisible below 3e10, so this is "no regression", not a demonstration. |
| RL-011 / RL-012 | **runs** | The atlas path is exercised (the scene has a skinned skeleton). ⚠ **Neither defect is demonstrated**: no spawn/despawn cycle, and no static-pose skeleton surviving another skeleton's grow. |
| RL-015 | **applied only** | ⚠ **The coverage scene cannot exercise it.** Mobile logs `Volumetric fog is only available when using the Forward+ renderer` and disables it outright, so `volumetric_fog_process.glsl` never compiles on the one configuration hogdot ships. The fix is correct by inspection and matches the fork's own established substitutions, but nothing has run it. It becomes testable only when Forward+ on web works (RL-029's `HelperInvocation` blocker) or via a direct shader-compile harness. |

⚠ **The general trap this exposes: a coverage scene run on Mobile silently skips every Forward+-only
feature**, and the skip is a `WARNING`, not a failure. SSAO, SSIL, SSR, volumetric fog, SDFGI,
auto-exposure, TAA, FSR2 and subsurface scattering are all requested by `shader_coverage.gd` and all
declined. Any fix to those shaders is unverifiable here — do not let a green run on this scene imply
otherwise.

---

## Provenance corrections (forward-only, append-only)

History is never rewritten here (`conventions.md` § git mechanics), so a wrong `Webgpu-Source:`
trailer is repaired by recording the right SHAs here instead. **Trust this section over the trailer**
when the two disagree. Found by the phase-6 audit's A4 spot-check as RL-032; re-derived with
`git log --oneline 4.6.2-stable..webgpu/webgpu-4.6.2 -- <path>`.

**`5829f06` — `port(ci): add the WebGPU web template jobs`.**
Cites `69a9b2f`, which touches `SConstruct`, `drivers/SCsub` and `drivers/webgpu/` — none of the
files the commit changes. The correct source for `.github/workflows/web_builds.yml` is the fork's
sole commit touching it:

```
Webgpu-Source: 2507016
```

**`7d5f060` — `port(clean): apply 11 of the 13 conflict-free fork modifications`.**
Cites `f329e39`, which vendored the naga-converter machinery and touches none of the eleven files.
The commit spans eleven paths with distinct sources, so the honest trailer is the union:

```
Webgpu-Source: 45cee3f 7655f1d d16f25b 7f501e8 f8b3cd0 04713bd 5ca1e92 5722105
               dd378ba 4d1c03c 4bbc72a 3e29284 b2327be d1da774 e9505ca fd5f8c8
```

Per path, for anyone tracing a single line:

| path | fork commits |
| --- | --- |
| `.gitattributes` | `45cee3f` |
| `misc/dist/html/full-size.html` | `7655f1d` `d16f25b` |
| `platform/web/js/engine/config.js` | `d16f25b` `7f501e8` |
| `platform/web/js/engine/engine.js` | `f8b3cd0` `04713bd` `5ca1e92` `5722105` `dd378ba` `4d1c03c` `4bbc72a` `3e29284` `7655f1d` `d16f25b` |
| `shaders/canvas.glsl` | `b2327be` |
| `shaders/canvas_sdf.glsl` | `d1da774` |
| `shaders/effects/copy.glsl` | `d1da774` `e9505ca` |
| `shaders/effects/resolve.glsl` | `d1da774` |
| `shaders/effects/smaa_edge_detection.glsl` | `e9505ca` |
| `shaders/effects/smaa_weight_calculation.glsl` | `e9505ca` |
| `shaders/skeleton.glsl` | `fd5f8c8` |

⚠ **The lesson: a bulk `port(clean)` commit spanning many unrelated files cannot carry one honest
`Webgpu-Source:`.** Both errors are that shape. At the next rebase-forward, either split such a
commit per source-cluster or write the per-path table into the commit body from the start.

---

## slice 8 — meta (the last port slice) — 2026-08-06 — `42427d3`

**Source:** `26b0cee` `ed50eb6` `b97e30f` `728f8f3` `f8b3cd0` (README.md) · `f8b3cd0`
(thirdparty/README.md) · `054cc0c` `d6325c3` (.gitignore)
**Verification:** n/a — documentation and ignore rules, no code.

Closes the eight-slice port. `README.md`, `thirdparty/README.md`, `.gitignore`.

**Adapted, not carried**
- **`README.md`** — the fork's +247/-53 rewrite replaces Godot's README with GodotWebGPU marketing and
  moves the original to `GODOT_README.md`. hogdot **prepends a section instead** and leaves Godot's
  text in place, so the file stays a near-zero-conflict rebase target. `GODOT_README.md` is therefore
  **not created** — nothing for it to hold. (Planned as a drop in the phase-1 entry; this is where it
  lands.)
- **`thirdparty/README.md`** — the fork's `spirv-headers` edit rewrites the version line to its own
  newer drop. hogdot keeps mainline's version line (mainline's tree is what we ship) and instead
  documents the two real deltas: the extra `include/spirv/unified1` headers, and that `spirv.hpp11`
  alone comes from the newer drop. That is the honest description of the tree after the
  `thirdparty-collision` reversal (`ef55f41`); copying the fork's line verbatim would have described
  a tree hogdot does not have.

**Dropped**
- **`.gitignore` → `*.uid`** — Godot generates `.uid` files as *tracked* project content; mainline
  tracks 8 under `platform/android/`. A repo-wide ignore would silently stop hogdot tracking files
  upstream does, and read as drift at every rebase-forward. `.chat-history/` and `tmp/` are carried.

**Gotchas**

⚠ **`./hogdot/port-surface.sh` does NOT measure progress, and never reports "zero unported
conflicts".** It derives the fork's delta against `HOGDOT_UPSTREAM_BASE` — a property of the two trees
that is invariant to how much has been landed — so it prints **39 conflicts forever**, before and
after slice 8. The phase-7 brief's clause "after this, `port-surface.sh --all` should report zero
unported conflicts" is wrong on its own terms, and the first draft of the slice-8 commit message
repeated the error.

The check that *does* work is per-file, and it is cheap:

```bash
./hogdot/port-surface.sh --conflicts | awk '...' > conflicts.txt
while read -r f; do
    git diff --quiet 4.7.1-stable HEAD -- "$f" && echo "UNCARRIED: $f"
done < conflicts.txt
```

Run 2026-08-06 after slice 8: **37 of 39 carry fork content; the 2 that do not are recorded
deliberate drops** — `scene/resources/2d/tile_set.cpp` (fork delta is one blank line) and
`servers/rendering/renderer_viewport.cpp` (fork delta is an inert `{ }` diagnostic stub, dropped in
`f503e72`). That is what "the port surface is fully dispositioned" means here, and it is evidence
rather than a number from a script.

⚠ **Provenance trailers must be *derived*, never recalled.** The first version of `42427d3` carried
`Webgpu-Source: 2d13d18 ea9f8be` — two SHAs that correspond to nothing, written from memory instead of
from `git log --oneline 4.6.2-stable..webgpu/webgpu-4.6.2 -- <path>`. Caught before anything built on
it and corrected by amending the tip (unpushed, nothing referencing it), so it is **not** in
§ *Provenance corrections* — that section is for landed, uncorrectable trailers, and diluting it with
same-minute slips makes it less useful. The rule stands: run the log command, paste the output.

---

## Phase 7 — hardening, second batch (2026-08-06)

Queue items 7, 8, 9, 11 plus gate clauses (b), (c), (f). Commits: `28a9960` `a2d81ab` `f90fccd`
`b659667` `94eadae` `24cb88d` `42427d3` `da731d2`.

### The measurement that ended the precompiled-WGSL question (item 7)

The audit deferred delete-vs-repair on RL-009 pending a measurement nobody had taken. Taking it cost
one instrumented build and one browser run: a temporary `print_line` at the lookup site reported
**`table_count=141`, 600+ lookups, `hits=0`.** Not a low hit rate — *zero*. The mechanism had been
inert for the entire port.

⚠ **Two pieces of "evidence" for that conclusion were already on the record and both were wrong.**
Worth naming because both are the kind of reasoning that feels conclusive:

1. *"The glslang generator version proves the SPIR-V differs."* It does not. Both external 16.5.0 and
   vendored 16.1.0 return `GetSpirvGeneratorVersion() == 11`
   (`thirdparty/glslang/SPIRV/GlslangToSpv.cpp:11454`), so the SPIR-V header's generator word is
   **identical** and cannot distinguish them. Checked directly by compiling a trivial shader and
   reading word 2.
2. *"`warning: variable '_spv_to_wgsl_precompiled_hits' set but not used` corroborates zero hits."*
   It does not. The counter's only *read* sits inside `WEBGPU_DIAG`, which compiles to `((void)0)`
   because `WEBGPU_VERBOSE` is commented out at `rendering_device_driver_webgpu.cpp:53`. The warning
   appears whether the table hits or not.

**The lesson: a plausible mechanism is not a measurement, and neither is a compiler warning you have
not traced to its cause.** The instrumented build was ~45 s of ccache-warm rebuild.

### Dead code that was load-bearing-looking but empty (item 9)

`//SSBO_USED:` and `*_depth_alias` were both naga-era: naga emitted the markers, Tint never did, and
the consumer sides survived the migration. Both maps were always empty, so every loop over them was a
no-op and removal was provably behaviour-neutral.

⚠ **The check that makes such a removal safe is "who *produces* this?", not "who consumes it?".** One
`rg` across `spirv_preprocess.cpp`, `tint_cli/main.cpp` and `thirdparty/tint/` for the marker string
answered it in seconds; reading the consumers would only ever have shown they were plausible.

### `buffer_flush` looked like the right hook for RL-005 and was not

The obvious fix for the unconditional `buffer_unmap` loop in `_end_frame` was to route it through
`RenderingDeviceDriver::buffer_flush`, already a defaulted no-op on every native driver. ⚠ **That
would have caused a large performance regression on WebGPU.** WebGPU's `buffer_unmap` checks
`map_dirty`; its `buffer_flush` deliberately does not, because `buffer_persistent_map_advance` sets
the dirty *range* without setting `map_dirty` and `_buffer_update`'s persistent fast path depends on
the unconditional flush. Sharing the entry point would have flushed all ~69 × 256 KB staging blocks
every frame. A new `API_TRAIT_BUFFER_MAP_IS_CPU_SHADOW` keeps the two semantics apart.

⚠ **And it had to be verified windowed.** Headless runs the dummy driver and never calls
`api_trait_get` on a real one — RL-016's trap exactly. `bin/godot.macos.editor.arm64 --path
webgpu_tests/test_project --rendering-driver metal --rendering-method mobile` reports
`PASS — All shader paths exercised without errors`.

### The paired-condition trap in the buffer fast path (RL-006)

Five call sites in `rendering_device.cpp` each test the same predicate **twice** — once to choose
`buffer_create_with_data()`, once negated to decide whether to run `_buffer_initialize()`. ⚠ Editing
only the first (the natural minimal edit) leaves a buffer created *without* data and *without*
initialization — silently uninitialized, no error anywhere. The predicate now lives in
`_can_create_buffer_with_data()` and both branches read one stored local.

### `pre-commit run --all-files`, run over the whole tree for the first time

Phase 1 only ever ran it per-file. Five iterations to green; each hook that fixes files fails its own
run, so a clean result needs a re-run after the last fix.

Findings beyond formatting:
- **A real bug in `misc/dist/html/webgpu-full-size.html`** — `engine` referenced in the
  missing-features branch where it is not in scope (upstream declares it at module scope; this file
  builds it inside the `initWebGPU()` callback). A feature-poor browser would have hit
  `ReferenceError` instead of installing the service worker. eslint found what no run had.
- ⚠ **The `// eslint-disable-next-line <rule> -- <reason>` suffix form is NOT supported here** —
  `eslint --fix` silently *deletes* the whole directive, taking the first line of the adjacent comment
  with it. Put the reason on preceding lines and keep the directive bare.
- ⚠ **`chmod +x` does not satisfy `check-shebang-scripts-are-executable`** — it reads the git index
  mode. Use `git add --chmod=+x`.
- ⚠ **`header_guards.py` requires `#pragma once` immediately after the license block**, before any
  descriptive comment. Three `tint_cli` shim headers had it below their comments and reported
  `REQUIRES MANUAL CHANGES`.
- ⚠ **The `file-format` hook deleted a carried port hunk** — the fork's lone blank line in
  `canvas.glsl` (RL-004). Whitespace-only fork deltas cannot survive Godot's own gate; do not spend
  effort carrying them at the next rebase-forward.

### Verification reached this batch

| Item | Tier | Evidence |
| --- | --- | --- |
| 7 — precompiled-WGSL deletion | **renders** | draw metrics identical before/after (`draws/f=107 SetBG/f=161 PC/f=86 RP/f=50`), 0 GPU validation errors |
| 8 — RL-003 | compiles | both targets |
| 8 — RL-005/006/008 | **runs (native, windowed)** | metal/mobile `PASS`; headless would not have exercised it |
| 8 — RL-018/019 | compiles | web path is `#ifdef WEB_ENABLED`; the *web* branch is not separately demonstrated |
| 9 — dead mechanisms + WGSL unification | **renders** | same metrics, same 62 console messages, 0 validation errors |
| 11 — slice 8 | n/a | docs/ignore only |
| 11 — `pre-commit --all-files` | **clean, exit 0** | first time ever over the whole tree |
| gauntlet — `driver_unit_tests` | 327/0/0 | |
| gauntlet — `preprocessing_tests` | 191/0/1 | |
| gauntlet — `shader_corpus` | 13/0 | needs `glslangValidator` + `bin/tint_convert_cli` |

### phase-10 tranche A — 2026-08-10 — `b4622c34d7..0669f6800c`

**What landed.** RL-046 batch-predicate fix (`b4622c34d7`); RL-045 stage-bounds rejection
(`ef0f495876`); `InstanceData` std430 corpus fixture (`903c628c29`, OFFSETS-NATURAL, 14/14
fixtures pass); discardable MSAA ghost-trail gate (`717cc4923b`); light-culling stress gate
(`d80226d8ec`, reshaped in `0669f6800c`); `?scene=` gate selector in `shader_coverage.gd`
(`f42a0ee6da`). Ledger: RL-045/RL-046 dispositions, RL-047 note, delta-row-40 verdict.

**Tiers reached.** RL-046: **renders** — Chrome, negative control both directions (fix reverted
→ the MULTIPLE-bucket box dims silently; fix restored → matches the native movie-mode baseline).
RL-045: compiles (both `webgpu=yes` templates; the macOS editor never builds `drivers/webgpu/`).
Discardable gate: renders + visual judgment — MSAA 4X live, three captures across the traversal,
no ghost trail, zero validation errors. Native regression: windowed Mobile coverage gate PASS.

**Gotchas for the next session:**
- `shader_coverage.gd` called `camera.look_at()` before `add_child()` — the error was one of the
  phase-3 gate's 15 baseline diagnostics. Fixed in `f42a0ee6da`: **the native baseline is now 14
  diagnostics.**
- Every area light sets `uses_softshadow` (`renderer_scene_cull.cpp:1795`). Area-lit vs
  area-unlit neighbors already split on the soft clause; only bucket differences among lit
  instances need RL-046's clause.
- `VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME` on forward-mobile is `instances->size()`
  (`render_forward_mobile.cpp:965`). Nothing script-visible observes batching.
- Within a depth bucket the opaque render list runs in **reverse creation order** (probe-verified).
  The light-culling gate stages its merge representative on this; re-check after any upstream
  sort change.
- `flatten_binding_arrays` discards indices into arrays-of-handles (element-0 collapse) — RL-047,
  fork-documented as "no multi-lightmap on web". The corpus fixture makes the pass fire; do not
  read a fixture's sampler array as decoration.
- The `runtimeKeepalivePop` shutdown abort reproduces on the **nothreads** template too (any
  bounded gate quit); previously logged as a threads observation. Still cosmetic, still open.
- Movie-mode capture (`--write-movie frame.png`) is a clean native baseline path: real Metal
  rendering, PNG frames, no window interaction needed.

## Phase 10, tranche B + C — 2026-08-10 (session 2)

**Landed.** RL-048 scissor fix (`fed7b78011`); shadow-merge instrumentation + RL-010's named
switch (`4a4fd9d60a`); three gate scenes — area-light shadows, clearcoat × area light, drawable
blits (`b3d80155da`); HDR display output on web (`39744ca009`) and its gate (`e338af8742`);
port-commit hook exemption for feature trailers (`cf716687c2`); docs (`fdc14c726f`). First push to
`origin/main` in the project's history, at Ethan's explicit instruction.

**Tiers reached.** RL-048: **renders**, both directions — Chrome showed zero of four positional
shadows before and all four after, against a native `--rendering-method mobile` reference. Items 6
and 7: **renders**, matching native. HDR: **runs** — the canvas reads back as
`rgba16float / srgb / toneMapping extended` and the gate reports `enabled=true
max_linear_value=2.000 pass=true`; `?sdr` gives `bgra8unorm / standard` on the same build. ⚠ The
by-eye brightness check on the XDR panel and all Safari verification are **not** done.

**Gotchas for the next session:**
- ⚠ **A gate scene that cannot fail is not a gate.** RL-048 survived seven phases because no gate
  ever lit a shadow-casting positional light, and it was diagnosed in one run only because the new
  scene carries a spot and a directional control whose success is independently known. Third
  incident of this class (RL-037, RL-046, RL-048). Give every new gate a control.
- ⚠ **A native `GODOT_DUMP_SPIRV` dump can never feed `bin/tint_convert_cli`.** Metal's shader
  container compiles at SPIR-V 1.6; `RenderingShaderContainerWebGPU` reports 1.3 because that is
  what Tint's reader targets. All 32 dumped modules fail identically. The offline check designed
  into `feature-clearcoat.md` is structurally impossible; the browser run is stricter anyway.
- ⚠ **`?debug=atlas` reads black on web whether or not shadows work.** It says something about the
  debug overlay's own depth sampling, not about the atlas. Do not use it as evidence.
- **`Shadow Render: N passes in M draw lists (K merged)`** under `--verbose` is the only observer
  of the fork's shadow-pass merge — `VIEWPORT_RENDER_INFO_TYPE_SHADOW`'s draw-call slot is an
  instance count (`render_forward_mobile.cpp:1629`), the sibling of the trap tranche A logged for
  the VISIBLE slot.
- **`WGPUSurfaceColorManagement` chains into the surface CONFIGURATION, not the descriptor.**
  `wgpuInstanceCreateSurface` asserts its chain is exactly the canvas selector and aborts
  otherwise; `wgpuSurfaceConfigure` is what forwards tone mapping. Read emdawnwebgpu's
  `library_webgpu.js` before trusting a header's chaining comment again.
- **HDR needs engine-side setup a driver cannot supply:** AGX or LINEAR tonemapper (ACES and
  FILMIC produce SDR-range output and clamp first), `use_hdr_2d` per viewport, no glow SOFTLIGHT,
  no colour adjustment. `request_hdr_output` is read only at startup.
- ⚠ **A template can be content-current and still fail CommonGrounds' staleness check**, which
  compares mtimes: a binary built minutes before the commit that contains its source reads as
  stale. Regenerate it rather than touching the file, so the check keeps its meaning.
- The Bash tool runs **zsh**, which does not word-split unquoted parameters — `set -- $var` in a
  build loop silently passed empty scons options. Write the invocations out.
