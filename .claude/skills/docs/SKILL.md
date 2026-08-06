---
name: docs
description: Where to look up Godot, WebGPU, Dawn/Tint, Emscripten and SCons facts from this repo — the in-tree class reference under doc/classes (810 XML files at exactly the tracked release, plus 25 per-module doc_classes dirs), regenerating it with --doctool, Context7 for external libraries, and which upstream doc URLs are safe to cite.
when_to_use: Load before answering or acting on any API question — a RenderingDevice method signature, an enum value, a WebGPU or Emscripten behavior, a SCons option. Also load when a port hunk changes an exposed API and the class XML must move with it. Boundary — this is where facts come from; the WebGPU backend's own 50 fork documents are the godotwebgpu skill, and build commands are build-export.
user-invocable: false
---

# Looking things up from hogdot

⚠ **The single most important fact: hogdot *is* the engine repo.** The class reference in `doc/classes/`
is not a copy of Godot's documentation — it is *the* documentation, at exactly the commit you are working
on. No version skew is possible. Prefer it over every external source for any engine API question, and
never web-search something that is sitting in the tree.

## 1. In-tree first — `doc/classes/`

810 XML files at the repo root, plus **25 per-module** dirs (`modules/*/doc_classes/` — gdscript, gltf,
csg, gridmap, …). Each documents one class's methods, signals, properties, constants and enums, with
descriptions.

```bash
rg -l 'RenderingDevice' doc/classes/                       # which class docs mention it
rg -n 'texture_create|DataFormat' doc/classes/RenderingDevice.xml   # locate the member
```

⚠ **`doc/classes/RenderingDevice.xml` is 215 KB** — the most relevant file for this fork and far too large
to open. `rg` for the member name, then `Read` with `offset`/`limit` around the hit. Same discipline as
`rules/context-scale.md` applies to `doc/` as much as to source.

**Regenerating it** — required whenever a port hunk adds or changes an exposed API (a new
`RenderingDevice` enum value for WebGPU, a changed method signature). The engine dumps its own reference:

```bash
bin/godot.macos.editor.arm64 --doctool     # merges into existing files; implies --headless
```

⚠ Needs an **editor** build (the flag is editor-only) and it *merges* rather than overwrites, so
hand-written descriptions survive. Godot's pre-commit set also validates the XML — see
`.pre-commit-config.yaml`.

Related in-tree sources: **`CONTRIBUTING.md`** (220 lines — engine code style, PR conventions, the rules
this fork inherits), `doc/class.xsd` (the schema class XMLs must satisfy), `doc/tools/make_rst.py`.

## 2. External libraries — Context7

For anything **not** in this tree — the WebGPU specification, Dawn/Tint, Emscripten, SCons, emdawnwebgpu —
use Context7 (`resolve-library-id` → `query-docs`). It is the first stop for external API facts, ahead of
web search, and it matters more than usual here because this fork lives on fast-moving specs your training
data lags. The global `toolbox` rule already sets the per-question call caps; don't restate them, follow them.

Worth looking up rather than recalling: WebGPU binding-model and limits questions, `WGPU*` C API
signatures, Tint's SPIR-V reader behavior, Emscripten link flags and `--use-port` semantics, SCons
`Environment` options.

## 3. Upstream Godot docs — for concepts, pinned to a version

`docs.godotengine.org` covers what class XML doesn't: architecture explanations, tutorials, the rendering
overview, contributor guides.

⚠ **Never cite or fetch a `/stable/` URL** — it tracks whatever is current and will silently drift off the
release hogdot tracks. Pin the version: `https://docs.godotengine.org/en/4.7/…`. If a page only exists
under `/latest/`, say so explicitly rather than quietly citing a different version's behavior.

## 4. What does *not* apply here

⚠ **The `godot-mcp` and `godot-lsp` MCP servers are useless in this repo, and the global `godot` skill
mostly is too.** There is **no `project.godot`** — hogdot is engine C++ source, not a Godot project. Those
servers drive a running editor and a game built from a project; `godot_docs` needs that editor. Nothing to
attach to. The same goes for `gdformat`/`gdlint`: there is no GDScript here.

The verification tiers for this repo are compilation-based and live in `.claude/rules/verification.md`.

## 5. The fork's own documentation

GodotWebGPU's 50 imported documents are **not** covered here — they are the `godotwebgpu` skill's
`references/`, indexed in `references/index.md`. Go there for anything about the WebGPU backend itself.

---
*Source of truth for where facts come from — update it when a doc source is added, moves, or proves wrong.*
