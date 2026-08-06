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

_The first hand-port entry will be **rd-core** (slice 1); see the `port` skill for why that one goes
first._
