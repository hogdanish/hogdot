# `hogdot/` — fork-local tooling

Everything in this directory belongs to the fork, not to Godot. It lives at the repo root, in a
directory mainline will never create, so it survives every rebase onto a newer Godot release without
ever conflicting. Nothing upstream reads it.

| File              | What it is                                                                 |
| ----------------- | -------------------------------------------------------------------------- |
| `refs.env`        | The three git refs every port derivation depends on. **The one place to bump the tracked Godot release.** |
| `port-surface.sh` | Classifies every file GodotWebGPU touches by how hard it is to carry onto the tracked release. |
| `build_profile.web.gdbuild` | A tracked **copy** of the game's `godot/build_profile.web.gdbuild`; its sha256 goes in every release body as the drift check. Never edited by hand — re-copied when the game's changes. |
| `install-vulkan-sdk-macos.sh` | Pinned, sha256-verified LunarG SDK install for the `macos-editor` release job. Replaces upstream's `misc/scripts/install_vulkan_sdk_macos.sh`, which fetches `latest` and runs it unverified. **Bumping the pin moves two constants together** — recipe in the file header. |

Owning docs: `refs.env` / `port-surface.sh` → the **`port`** skill; the build profile and the
Vulkan SDK pin → **`build-export`** ("The cg-release channel").

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
