# Claude Code integration — v6.5

Claude is optional. When available, Opus provides independent review and high-value multi-angle reasoning without making Claude the implementation owner.

## Long work uses background sessions

v6.5 uses **Claude Code background sessions** for long work:

```text
claude --bg ... "prompt"
```

Do not use synchronous `claude -p` for long repository review/panel work. Codex shell wait/yield limits are not Claude failure signals.

## Read-only boundary

Helpers use:

```text
--permission-mode plan
--tools Read,Glob,Grep
--disallowedTools mcp__*
--disable-slash-commands
--no-chrome
```

Claude must analyze/review, not edit or implement.

`--tools` does not disable MCP tools by itself, so v6.5 explicitly denies `mcp__*`.

Do not add `--bare`; it caused authentication failures in observed real setups. Preserve normal authentication and constrain the role through permissions, tools, system instructions, and session structure.

No hard `--max-turns` is used. Claude Code's print-mode max-turn limit can terminate before a final review is emitted; background review should finish naturally.

## Authentication / billing

Default mode:

```bash
export LUNA_ORCH_CLAUDE=auto
```

- `auto`: requires `claude auth status` to succeed.
- `on`: skip the auth-status precheck and attempt Claude directly.
- `off`: disable Claude; use Luna reviewer fallback.

If `ANTHROPIC_API_KEY` is set, the helpers warn because the run may be API-billed rather than using the intended Claude subscription.

## Model / effort

Defaults:

```bash
export LUNA_ORCH_CLAUDE_MODEL=opus
export LUNA_ORCH_CLAUDE_REVIEW_EFFORT=xhigh
export LUNA_ORCH_CLAUDE_PANEL_EFFORT=max
```

For seed-and-fork operations, seed and branches keep model/effort/tool/system-prompt/working-directory configuration stable for cache-friendly lineage.

## Conversation identity: job ID vs sessionId

Claude agent state exposes two identities:

- short background `id`: used by `claude logs`, `claude attach`, `claude stop`;
- full `sessionId`: the Claude conversation ID used by `claude --resume`.

v6.5 stores both. This matters because a sticky re-review/follow-up can run as a new supervised background job while still being the **same conversation**.

## Resume vs fork policy

Never write concurrently to a live conversation.

- ordinary first review: fresh background conversation;
- ordinary re-review: after Reviewer 1 is `done`, `--resume <same sessionId> --bg` **without** `--fork-session`;
- further re-review: keep resuming that same Reviewer 1 sessionId until PASS / accepted risk;
- dual review: neutral background seed, then two blind forks using `--fork-session`;
- dual-review finding closure: each reviewer resumes its own sessionId;
- advisory panel: neutral seed, then 2..6 independent role forks;
- sticky advisor follow-up: resume the chosen completed expert's same sessionId;
- intentionally independent new opinion: fork/fresh session as appropriate.

Fork is for **independence**. Resume is for **continuity**.

## Result collection

Background mode does not use JSON print output. The helpers:

1. parse the short background ID printed by `claude --bg`;
2. query `claude agents --json --all` for state and conversation `sessionId`;
3. only after `done`, collect recent output with `claude logs <id>`;
4. persist/verify sessionId for sticky re-review and advisor follow-up.

Do not infer completion from elapsed time or Codex shell behavior.

## macOS caveat

Claude background sessions can be affected by macOS privacy restrictions when repositories live under Desktop, Documents, or Downloads. Address the OS/location issue instead of repeatedly spawning new reviewers.
