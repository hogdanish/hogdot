# SKILL.md frontmatter — the complete reference

Distilled from code.claude.com/docs/en/skills + /en/sub-agents. All fields optional; only `description` is
recommended. YAML between `---` markers at the top of `SKILL.md`.

## ⚠ The trap that silently kills a skill

**A bare `: ` (colon-space) inside an unquoted `description` or `when_to_use` breaks the YAML**, and the
frontmatter fails to parse — which makes the **entire skill invisible to Claude**, with no error anywhere.
It fails silently and you will not notice until the skill never fires.

- Write `Boundary — this is X` with an em dash, **never** `Boundary: this is X`.
- The same applies to any `key: value`-looking text mid-sentence.
- If you genuinely need a colon, quote the whole scalar: `description: "Foo: bar"`.
- Ratio marks (`3.25x`), URLs (`https://…`) and paths are fine — it is specifically `: ` that ends a key.

After editing frontmatter, confirm the skill still appears in the skills listing.

## Fields

| Field | Purpose / notes |
| --- | --- |
| `name` | Display name in listings. Defaults to the directory name; the command you type (`/name`) comes from the **directory**, not this field. Keep it equal to the dir name. |
| `description` | *What the skill covers*, primary use case first. Claude matches against this to auto-invoke. Combined with `when_to_use`, truncated at **1,536 chars** in the listing. |
| `when_to_use` | *When to load it* — trigger phrases, example requests, and the boundary with neighbouring skills. Appended to `description`; counts toward the same cap. |
| `argument-hint` | Autocomplete hint, e.g. `[skill-name]`. |
| `arguments` | Named positional args for `$name` substitution. Space-separated string or YAML list; names map to positions in order. |
| `disable-model-invocation` | `true` = only the user can invoke it (`/name`); **its description leaves Claude's context** (frees listing budget) and it won't preload into subagents or fire from a scheduled task. For side-effectful commands. Default `false`. |
| `user-invocable` | `false` = hidden from the `/` menu; Claude-only background knowledge. **Description still stays in context.** Default `true`. |
| `allowed-tools` | Tools pre-approved (no permission prompt) while the skill is active. Doesn't restrict the pool. |
| `disallowed-tools` | Tools removed from the pool while active (clears on your next message). |
| `model` | Model override for the rest of the turn — `sonnet`/`opus`/`haiku`/`fable`/full-id/`inherit`. |
| `effort` | `low`/`medium`/`high`/`xhigh`/`max` — overrides session effort while active. |
| `context` | `fork` = run the skill in a forked subagent; the SKILL.md body becomes the subagent's prompt, with no main-conversation history. |
| `agent` | Which subagent type when `context: fork` — `Explore`, `Plan`, `general-purpose`, or a custom `.claude/agents/` type. Defaults to `general-purpose`. |
| `hooks` | Hooks scoped to this skill's lifecycle. |
| `paths` | Globs that gate **auto-invocation** to matching file work. Does not hide the description. |
| `shell` | `bash` (default) or `powershell` for `` !`cmd` `` injection. |

## Invocation matrix

| Frontmatter | You invoke | Claude invokes | Description in context |
| --- | --- | --- | --- |
| (default) | yes | yes | yes |
| `disable-model-invocation: true` | yes | no | **no** |
| `user-invocable: false` | no | yes | yes |

**In hogdot:** scope articles (`port`, `godotwebgpu`, `docs`, `engine`, `build-export`) →
`user-invocable: false`. Meta/authoring (`claude-framework`) → default. A side-effectful workflow →
`disable-model-invocation: true`.

⚠ **`paths:` is deliberately unused here.** hogdot is 14,000 files and a port touches unpredictable
corners; gating auto-invocation by glob suppresses a skill exactly when an unexpected file drags you into
its scope. Let the `description`/`when_to_use` do the triggering.

## String substitutions (in body and `allowed-tools`)

`$ARGUMENTS` (all args; auto-appended as `ARGUMENTS: …` if absent) · `$ARGUMENTS[N]` / `$N` (0-based) ·
`$name` (a declared `arguments:` entry) · `${CLAUDE_SESSION_ID}` · `${CLAUDE_EFFORT}` ·
`${CLAUDE_SKILL_DIR}` (this skill's dir — use it to reference bundled files) · `${CLAUDE_PROJECT_DIR}`
(repo root). Escape a literal with `\$`.

## Dynamic context injection

`` !`command` `` (inline, at line start or after whitespace) or a ` ```! ` fenced block runs the shell
command **before** Claude sees the content, and replaces the placeholder with its output. Runs once, not
re-scanned. For a forked skill this executes at fork time, so injected content reaches the subagent and
never the main context.

Natural fit in this repo: injecting `./hogdot/port-surface.sh --conflicts` into a forked slice-picker, so
the 39-row table never lands in the main window.

## The `context: fork` lookup recipe

For picking one item out of a large index without spending the main agent's context or model on it:

```yaml
---
name: find-thing
description: Pick a <thing> from <the index>. Returns the exact <artifact>.
when_to_use: When you need one <thing> and the index should never reach the main context.
context: fork
agent: Explore            # Haiku, read-only, skips CLAUDE.md — cheapest possible
argument-hint: [what it's for]
allowed-tools: Read
---
## Index
```!
cat ${CLAUDE_SKILL_DIR}/references/thing-index.md
```
Pick the single best match for **$ARGUMENTS** and return ONLY `<the exact artifact string>`.
```

Why `Explore`: it is Haiku, read-only, and skips CLAUDE.md — strictly cheaper than any custom agent (which
loads CLAUDE.md). Build a custom `.claude/agents/` type only if the fork needs tools Explore lacks.

⚠ Use `$ARGUMENTS` (the full typed string), **not** a named `arguments:` positional, for free-text input.
Named and indexed positionals are shell-tokenized, so `$description` captures only the first word
("the RD core slice" → "the"). `$ARGUMENTS` always expands to the whole argument as typed.

## Budgets

- `SKILL.md` body: a lean overview. Docs cap it at <500 lines; aim far lower. Once invoked the whole body
  stays in context for the session (re-attached after compaction within a 25k-token pool) — every line recurs.
- Push API tables, catalogues and specs into `references/*.md`, each linked with a one-line what/when.
  ⚠ **Don't split off a lone small reference** — a single file under ~250 lines that isn't a living log or
  a fork-injected index belongs inline. A thin body deferring everything to one small ref is pointless
  indirection.
- `description` + `when_to_use`: ≤1,536 chars combined, key case first (it truncates there).
- `CLAUDE.md`: ≤200 lines, glossary lines not paragraphs.
- All unscoped rules together: keep under ~80 lines — a shared always-on cost.

## Custom subagent frontmatter (`.claude/agents/*.md`), for reference

`name`, `description` (required) · `tools` / `disallowedTools` · `model` (default `inherit`) · `effort` ·
`skills` (preload full skill bodies) · `permissionMode` · `maxTurns` · `memory`
(`user`/`project`/`local`, cross-session) · `mcpServers` · `hooks` · `color`. Only `Explore` and `Plan`
skip CLAUDE.md; every other agent, built-in or custom, loads it.
