---
name: claude-framework
description: How hogdot organizes Claude's context — the skill map and scope boundaries, the mechanics of authoring a skill (frontmatter fields, invocation control, the description-vs-when_to_use split, forked lookups, line and character budgets), and the templates to start from.
when_to_use: Read before creating or restructuring a skill, rule or hook, when a scope outgrows its skill, when CLAUDE.md and a skill disagree, or when deciding whether a new piece of guidance is a rule, a skill, a reference file, a hook or a memory. Run /claude-framework to author one.
argument-hint: [skill-name]
allowed-tools: Read, Grep, Glob, Edit, Write, Bash(ls*), Bash(wc*), Bash(fd*), Bash(rg*)
---

# The context framework in hogdot

⚠ **The doctrine is not here.** Layers, precedence, where new guidance goes, and the self-improvement
mandate are the global `context-architecture` rule, which is already in context every session. **Do not
restate it** — this skill holds only the mechanics it omits and the hogdot-specific map.

## hogdot deltas

- **Working files → `.claude/work/`** (gitignored), never `docs/`. Plans, specs, notes, scratch — anything
  written *about* the work rather than *being* the work. There is no `docs/` at the repo root and none
  should appear; ⚠ `doc/` (singular) is upstream Godot's class reference and is untouchable except by the
  rules in the `docs` skill. Name the target path when dispatching a subagent — they don't reliably
  inherit this.
- **This is a fork, so provenance outranks tidiness.** `.claude/rules/port-provenance.md` is the most
  important convention in the repo. Nothing in a skill may contradict it.
- **Numbers are measurements with a date.** Every count in a skill or in CLAUDE.md must be re-derivable
  (`./hogdot/port-surface.sh`, `git log`, `wc -l`). When a re-measurement disagrees, the tool wins —
  update the figure and its date, never leave both.

## The skill map

| Skill | Owns | Boundary |
| --- | --- | --- |
| `claude-framework` | This — the framework mechanics and the map. | Doctrine is the global rule. |
| `port` | Sequencing and integrating the WebGPU port; the slice order; the living slice log. | How the backend *works* is `godotwebgpu`; commit trailers are `rules/port-provenance.md`. |
| `godotwebgpu` | How the WebGPU backend works, plus the 50 imported fork documents. | Porting mechanics are `port`; mainline internals are `engine`. |
| `docs` | Where facts come from — in-tree `doc/classes/`, Context7, upstream URLs. | The fork's own docs are `godotwebgpu`. |
| `engine` | Mainline 4.7.1 internals hogdot touches — `RenderingDevice`/`RenderingDeviceDriver`, `storage_rd`, forward-mobile. | **Scaffold only.** Fill it from the codebase as the RD-core slice lands. |
| `build-export` | Compiling the editor and export templates, ccache, Emscripten, getting a build into CommonGrounds. | **Scaffold only.** Correct it the first time each command actually runs. |

Always-on rules (a shared cost — keep the set lean): `context-scale` · `port-provenance` · `verification`.

## Authoring — the procedure

1. **Locate.** Read the skill's `SKILL.md` and every file under its `references/`. Files containing
   `FILL:` markers are the work.
2. **Map the scope from the codebase**, not from memory and not from a neighbouring skill. Name the real
   artifacts — classes, files, commands, constants. "The shader pipeline" won't trigger;
   `spirv_preprocess.cpp`, `tint_wrapper.cpp`, `wgsl_precompile.py` will.
3. **Research when version-sensitive.** Use the `docs` skill's routing — in-tree `doc/classes/` for engine
   API, Context7 for WebGPU/Dawn/Emscripten/SCons. ⚠ For anything about the fork, author from the fork's
   own documents, and mind the naga→Tint generational split flagged in `godotwebgpu/references/index.md`.
4. **Distill.** `SKILL.md` stays a lean overview — the scope in a paragraph, each seam and gotcha in a
   line, a one-line what/when pointer per reference. Every line is a recurring cost once loaded.
5. **Frontmatter.** Apply [frontmatter.md](references/frontmatter.md).
6. **Verify.** `description`+`when_to_use` ≤1,536 chars · every `references/*.md` linked from the
   SKILL.md · no `FILL:` left in a finished file · CLAUDE.md's glossary line updated in the same change if
   the scope changed.

## Writing standards

- **Preserve every ⚠ gotcha verbatim** from whatever you distil. Those are the expensive-to-rediscover bits.
- **State the neighbour's boundary** ("sequencing the port is `port`; this is how the backend works") so
  skills stop overlapping.
- Dense, imperative, no filler. Match the house voice.
- ⚠ **Never claim a verification tier the work didn't reach** (`rules/verification.md`). "Applies cleanly"
  is not "compiles".

## Reference material

- [frontmatter.md](references/frontmatter.md) — the complete frontmatter field table, the invocation
  matrix, string substitutions, dynamic `` !`cmd` `` injection, the `context: fork` lookup recipe, and the
  budgets. ⚠ Read it before writing any frontmatter; it carries the YAML trap that can make a skill
  silently unreadable.
- [templates.md](references/templates.md) — copy-paste starting points: a scope article, a reference file,
  a living log, an invocable cookbook, a forked lookup, and a custom subagent.

---
*Source of truth for the framework itself — update it when these conventions evolve.*
