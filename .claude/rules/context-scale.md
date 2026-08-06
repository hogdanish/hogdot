# Working in a 14,000-file engine repo without drowning

hogdot tracks **13,985 files** at 4.7.1-stable, **4,809** of them vendored `thirdparty/`. The port adds
~1,450 more, ~1,220 of which are vendored Tint/SPIRV-Tools. Naive exploration burns a context window
before reaching anything useful.

- ⚠ **Never `Read` a vendored third-party tree** — `thirdparty/tint`, `thirdparty/spirv-tools`,
  `thirdparty/spirv-headers`, `thirdparty/{mbedtls,harfbuzz,icu4c,…}`. They are upstream drops, not
  code to review, and a single Tint header buys nothing. Port them as bulk imports. If a *specific*
  vendored symbol genuinely matters, `rg` for that symbol with a path filter — never open the tree.
- **Ask the script, not the filesystem.** `./hogdot/port-surface.sh --all` answers "what is left to
  port / what conflicts / what is safe" exactly. Do not reconstruct it with `find`, `git status`, or
  by opening directories.
- **Scope every search.** `rg <pat> servers/rendering drivers/webgpu` beats a repo-wide sweep;
  `rg --glob '!thirdparty/**'` when the path is genuinely unknown. `ast-grep` for structural C++ work.
- **Bound history commands.** `git log` over this repo is effectively unbounded — always pass a path,
  a range, and `--oneline` (`git log --oneline 4.6.2-stable..webgpu/webgpu-4.6.2 -- <path>`).
- ⚠ `rendering_device_driver_webgpu.cpp` is **360 KB** and `spirv_preprocess.cpp` **81 KB**. Read them
  by `offset`/`limit` around a located symbol, never whole. The same goes for `doc/` — the in-tree
  `doc/classes/RenderingDevice.xml` is **215 KB**; `rg` for the member, then read around the hit.
- ⚠ **The fork's 50 imported documents are 1.2 MB** (`.claude/skills/godotwebgpu/references/`) — roughly a
  third of a context window. **Always enter them through `references/index.md`**, which says which single
  file answers your question and which are superseded. Never open the tree, never read two when one will
  do, and `rg` across `notes/`+`site/` when you don't know which file to pick.
