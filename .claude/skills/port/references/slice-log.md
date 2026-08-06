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

_None yet — nothing has been ported. The first entry will be **rd-core** (slice 1); see the `port` skill
for why that one goes first._
