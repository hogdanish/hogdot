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
- ⚠ **`pre-commit` and `clang-format` are NOT installed on this machine.** Godot's
  `.pre-commit-config.yaml` is therefore not runnable as-is; either install it or match surrounding
  style by hand, and do not claim a change is lint-clean when nothing linted it.
- Report failures with the actual compiler output. A build that broke is a result, not a setback to
  paper over.
