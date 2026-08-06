# `hogdot/` — fork-local tooling

Everything in this directory belongs to the fork, not to Godot. It lives at the repo root, in a
directory mainline will never create, so it survives every rebase onto a newer Godot release without
ever conflicting. Nothing upstream reads it.

| File              | What it is                                                                 |
| ----------------- | -------------------------------------------------------------------------- |
| `refs.env`        | The three git refs every port derivation depends on. **The one place to bump the tracked Godot release.** |
| `port-surface.sh` | Classifies every file GodotWebGPU touches by how hard it is to carry onto the tracked release. |

## Bringing hogdot onto a newer Godot

1. `git fetch upstream --tags`
2. Edit `refs.env` → `HOGDOT_UPSTREAM_BASE=<new tag>`
3. `./hogdot/port-surface.sh --all` — the conflict list is now measured against the new release, and
   is the work list for the rebase.

`port-surface.sh` deliberately stores no data. A checked-in ledger of "what still needs porting" is
stale the moment upstream tags a release; re-deriving takes about a second and is always correct.

## Why the port surface is small

Roughly 1,500 files sounds like the whole engine and isn't. The overwhelming majority are vendored
third-party drops (Tint, SPIRV-Tools, SPIRV-Headers) that apply wholesale, plus tests, notes and site
assets. The files that need human judgment are only those GodotWebGPU modified *and* mainline also
changed — run `./hogdot/port-surface.sh --conflicts` for the current list.
