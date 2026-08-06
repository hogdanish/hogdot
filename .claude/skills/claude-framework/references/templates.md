# Skill templates — copy the matching one

Frontmatter mechanics and the ⚠ YAML colon trap are in [frontmatter.md](frontmatter.md). Read that first.

## Scope article (the default in hogdot)

```markdown
---
name: <scope>
description: <What it covers — name the real files, classes and commands.> <Primary use case first.>
when_to_use: Load when <situation>. Boundary — <this> is X; <neighbor> is Y.
user-invocable: false
---

# <Scope>

<One paragraph: what the scope is, its entry points, and any version caveat.>

⚠ <The single most expensive-to-rediscover fact about this scope, if there is one.>

## <Seam or topic>
- <Dense factual lines. Every ⚠ gotcha preserved verbatim from the source.>

## Reference material
- [<topic>.md](references/<topic>.md) — <what's in it, when to read it>.

---
*Source of truth for <domain> — update it in the same change as the code.*
```

## Reference file (depth, loaded on demand)

```markdown
# <Skill> — <topic>

<One line on what this file is and what it is derived from.>

## <Section>
<The table, catalog or spec that belongs here — kept out of SKILL.md because it loads on demand.>
```

Placeholder form, when scaffolding a skill to be filled later:

```markdown
# <Skill> — <topic>

FILL: <one line on what this reference must contain and its source — files to read, which fork document,
which Context7 library.>
```

## Living log (append-only — the one case a lone small reference is right)

```markdown
# <Scope> log — living, append-only

One entry per <unit>. **Append in the same change as the work**, never as follow-up.

⚠ **Never delete or rewrite an entry.** If a later finding invalidates an earlier one, add a new entry
saying so. A wrong-but-recorded finding is recoverable; a deleted one is not.

## Template
​```markdown
### <name> — YYYY-MM-DD — <SHA>
**Verification:** applied | compiles | links | runs | renders
- …
​```

## Entries
_None yet._
```

`port/references/slice-log.md` is the working example.

## Invocable cookbook (a repeatable procedure)

```markdown
---
name: <verb-noun>
description: <The procedure and when to run it.>
argument-hint: [<arg>]
allowed-tools: Read, Grep, Glob, Edit, Write
---

# <Verb noun>

<Numbered steps. Point at the owning scope skill for "how the system works" rather than restating it.>
```

## Forked lookup (`find-*`)

See [frontmatter.md](frontmatter.md) → "The `context: fork` lookup recipe". `context: fork` +
`agent: Explore`, inject the index with a ` ```! ` block, return only the artifact. The index reference
file is the only real content; the SKILL.md is a thin shell.

⚠ None exist in hogdot yet. The natural first one is a slice-picker over
`./hogdot/port-surface.sh --conflicts`, so the 39-row table never reaches the main context.

## Custom subagent (`.claude/agents/<name>.md`) — only if a fork needs tools Explore lacks

```markdown
---
name: <name>
description: When to delegate to this agent.
tools: Read, Grep, Glob
model: haiku
---

<System prompt: the agent's job, its output contract, its constraints.>
```
