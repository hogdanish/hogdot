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
    zero and behaviour is unchanged until `mesh_storage.cpp` lands in slice 2. Landed in Phase 1.
- ⚠ **Four additive paths are not in the phase-1 brief's import list** and needed their own calls:
  `GODOT_README.md`, `misc/dist/html/webgpu-full-size.html`, `.github/workflows/webgpu_tests.yml`,
  `.github/copilot-instructions.md`. Re-derive the full additive set from `port-surface.sh` rather
  than trusting the brief's enumeration.
- ⚠ **BSD `xargs` has no `-a`.** Use `xargs -0 … < file` with `git diff --name-only -z` when checking
  out file lists of this size.

_The first hand-port entry will be **rd-core** (slice 1); see the `port` skill for why that one goes
first._
