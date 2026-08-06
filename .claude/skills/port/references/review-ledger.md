# Review ledger — living, append-only

Every hunk carried from GodotWebGPU is read with a critical eye during porting: bugs, inconsistencies,
regressions, performance concerns, questionable design — anything the original author may have missed.
Findings land **here**, not in the code. This file is the record that lets "port now, judge later" be
safe instead of sloppy.

## The directive

- **Default disposition is `deferred`** — record the finding, port the hunk faithfully, move on.
  The port's audit trail depends on ported code matching its cited source; silent "improvements"
  poison provenance.
- **Fix now only when** the finding (a) blocks compilation or correctness on 4.7.1, or (b) is a
  trivial, obviously-correct bug fix (≤ ~5 lines). Either way the fix is a **separate commit** from
  the port commit, its message referencing the ledger ID. Never mix a fix into a port commit —
  `.claude/rules/port-provenance.md` explains why.
- ⚠ A finding that changes what gets ported (a hunk deliberately dropped or altered because of it)
  must ALSO appear in the slice-log entry and the port commit body. The ledger records the judgment;
  the slice log records what was done about it.
- ⚠ **Never delete or rewrite an entry.** Later information gets a new entry linking the old ID.

## Entry format

```markdown
### RL-NNN — YYYY-MM-DD — <severity: blocker | bug | perf | smell | question>
**Where:** `path/to/file.cpp` (area/function)
**Found while:** <slice or phase>
**What:** <the concern, 1–4 lines, with evidence — line refs, measurements, or reasoning>
**Disposition:** deferred | fixed-in <sha> | wontfix — <one line why>
```

Severities: **blocker** (breaks 4.7.1 correctness/compile — must be fixed now) · **bug** (latent
defect, works by luck or fails in an edge case) · **perf** (measurable cost the author missed or
accepted) · **smell** (design/consistency concern, no known defect) · **question** (needs
investigation before it can be classified).

---

## Entries

### RL-001 — 2026-08-06 — bug
**Where:** `servers/rendering/renderer_rd/shaders/effects/copy.glsl` (both `main()` sanitize paths)
**Found while:** phase 1, clean-mods
**What:** The fork replaces `isinf(color)` with `greaterThan(abs(color), vec4(3.0e+10))` and
`isnan(color)` with `notEqual(color, color)`, presumably because Tint/WGSL does not give usable
`isinf`. The NaN replacement is exact. The infinity replacement is **not**: `3.0e10` is 28 orders of
magnitude below `FLT_MAX` (~3.4e38), so ordinary finite HDR values above 3e10 are now clamped to
`vec4(100.0)` as if they were infinite. This changes glow/luminance behaviour on **every** RD
backend, not just WebGPU, since these shaders are shared.
**Disposition:** deferred — carried faithfully. Revisit in Phase 5; the honest fix is to gate the
substitution behind the WebGPU backend, or raise the threshold to just below `FLT_MAX`.

### RL-002 — 2026-08-06 — bug
**Where:** `servers/rendering/renderer_rd/shaders/canvas_sdf.glsl`,
`servers/rendering/renderer_rd/shaders/effects/resolve.glsl` (`MODE_RESOLVE_GI`)
**Found while:** phase 1, clean-mods
**What:** Both reduce a "large sentinel" initializer from `1e20` to `1e6` — in `canvas_sdf.glsl` the
initial nearest-distance `d`, in `resolve.glsl` the initial `best_depth`. No comment explains it;
the likely motive is Safari/WGSL rejecting large float literals (cf. fork commit `d1da774`,
"shorten large float literals"). `1e6` is still far above any plausible SDF distance or depth, so
this is probably safe, but it is a silent narrowing of a sentinel's headroom on all backends and
would fail if a scene ever exceeded it.
**Disposition:** deferred — carried faithfully. Low risk; recorded so a future "why is the SDF wrong
in a huge scene" bug has a starting point.

### RL-003 — 2026-08-06 — smell
**Where:** `modules/glslang/config.py` (`can_build`)
**Found while:** phase 1, clean-mods
**What:** The fork appends `or env["webgpu"]` to the or-chain. `env["webgpu"]` raises `KeyError` when
the option is undeclared; it is only harmless on desktop because `env["vulkan"]` short-circuits
first. On the web platform vulkan/d3d12/metal are all False, so this is a hard configure-time crash
until `SConstruct` declares the option. Using `env.get("webgpu", False)` would have made the file
independent of slice ordering.
**Disposition:** deferred — hunk not carried in Phase 1; lands in Phase 2 alongside the SConstruct
option. Recorded in the clean-mods slice-log entry.

### RL-004 — 2026-08-06 — question
**Where:** `servers/rendering/renderer_rd/shaders/canvas.glsl` (end of `main()`)
**Found while:** phase 1, clean-mods
**What:** The fork's only change to this file is an added blank line before the closing brace — no
semantic content. Carried for faithfulness, but it is pure diff noise against mainline and a
candidate to drop at the next rebase-forward.
**Disposition:** deferred — carried faithfully.
