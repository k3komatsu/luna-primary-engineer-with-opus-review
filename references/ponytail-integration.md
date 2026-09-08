# Ponytail integration in v6.5

Ponytail is used by **implementers**, not independent reviewers or advisors.

## Role policy

- Primary Luna Max/Fast: **Ponytail FULL**
- `luna_worker` Max/Standard: **Ponytail FULL**
- Claude Opus reviewers: **no Ponytail; independent read-only sessions**
- Claude Opus panel/advisors: **no Ponytail**
- fallback `luna_reviewer`: **no Ponytail**
- `sol_advisor`: **no Ponytail**
- `astra_expert`: **no Ponytail**

Ponytail means: minimize **implementation**, never the requested requirement or necessary architecture.

## Primary integration

The installer maintains a private Ponytail checkout at:

```text
${CODEX_HOME:-~/.codex}/luna-orchestrator/deps/ponytail/
```

and copies its `SKILL.md` into:

```text
~/.agents/skills/luna-orchestrator/references/ponytail/SKILL.md
```

The Primary reads/applies it explicitly before substantive implementation.

## Parallel Worker

`luna_worker.toml` gets a direct `[[skills.config]]` attachment to the private Ponytail skill.

## Global Ponytail warning

A globally injected Ponytail plugin can contaminate roles that are deliberately meant to be independent. For strict v6.5 behavior, use this package's private integration rather than global injection during Luna Orchestrator sessions.
