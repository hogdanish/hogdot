# Verifying an engine change (C++, not GDScript)

Nothing in this repo is proven by reading it. A ported hunk that has not been compiled is a guess.

- **Compilation is the floor, not the ceiling.** "It looks right" and "the diff applies" are not
  results. Say plainly which of these a claim rests on: applied / compiles / links / runs / renders.
- **Builds are long and belong in the background.** A cold `scons platform=macos target=editor` is tens
  of minutes. Run it with `run_in_background` and keep working; don't block a turn on it, and don't
  poll it in a loop — the harness re-invokes you when it exits.
- **Spend the cheapest tier that proves the change:**
  - **Syntax/type only** → build the one affected target directly rather than the whole editor; scons
    rebuilds only what changed once a first build exists.
  - **Does it link** → full target build. Driver work usually needs this; missing vtable entries and
    signature drift only surface at link time.
  - **Does it render** → export a CommonGrounds scene and open it. Expensive; last.
- ⚠ **A failed build's first error is the only real one.** C++ template/macro errors cascade — fix the
  top error and rebuild rather than reading the tail. Pipe to a file and read the head.
- ⚠ **A successful build proves NOTHING about `.glsl` changes.** Godot's build only embeds shader
  source into `*.glsl.gen.h`; glslang compiles it to SPIR-V at **runtime**, on first use. A syntax
  error, a bad `layout(location=)` or a binding mismatch in a shader therefore survives a green build
  and only surfaces when the scene that uses it is drawn. Shader edits reach *compiles* for free and
  need **runs** to mean anything — say so rather than letting "the editor built" stand in for it.
- **Lint through `pre-commit`, never a bare formatter.** `pre-commit` (4.6.1) and `ccache` are installed
  as of 2026-08-06, so Godot's `.pre-commit-config.yaml` runs as-is — `pre-commit run <hook-id> --files
  <path>` while porting, `--all-files` before a commit. ⚠ **`clang-format` is deliberately NOT installed
  standalone**; that config pins v21.1.7 and pre-commit fetches it, so a formula copy would reformat the
  whole engine. Don't claim a change is lint-clean when nothing linted it.
- Report failures with the actual compiler output. A build that broke is a result, not a setback to
  paper over.
