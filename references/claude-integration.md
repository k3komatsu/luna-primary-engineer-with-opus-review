# Claude Code integration — v6.6

Claude is optional. When available, Opus provides independent review and high-value multi-angle reasoning without making Claude the implementation owner.

## Long work uses background sessions

v6.6 uses **Claude Code background sessions** for long work:

```text
claude --bg ... "prompt"
```

Do not use synchronous `claude -p` for long repository review/panel work. Use
`-p` only for a short, bounded, one-turn read-only question; its answer is
stdout plus an exit code, with no background job ID, lifecycle state, or sticky
resume path. Codex shell wait/yield limits are not Claude failure signals.

Example for a short question:

```bash
claude -p \
  --model opus --effort xhigh \
  --permission-mode dontAsk --permission-prompts none \
  --tools "Read,Glob,Grep" --disallowedTools "mcp__*" \
  --disable-slash-commands --no-chrome --add-dir "$PWD" \
  "Read source/v4/config.d and answer this bounded question: ..."
```

Keep the prompt narrow enough that one response is sufficient. Do not invent a
background job ID from this command and do not use `claude agents`, `collect`, or
sticky `resume` for it. If the question grows into a review, stop using `-p`
and dispatch `claude-review.sh start` instead.

## Read-only boundary

Helpers use:

```text
--permission-mode dontAsk
--permission-prompts none
--tools Read,Glob,Grep
--disallowedTools mcp__*
--disable-slash-commands
--no-chrome
```

Claude must analyze/review, not edit or implement.

`dontAsk` plus the explicit read-only tool set avoids an interactive plan or
permission approval pause. If an allowed read is unavailable, the reviewer
should record the evidence gap and finish rather than wait for approval.

`--tools` does not disable MCP tools by itself, so v6.6 explicitly denies `mcp__*`.

Do not add `--bare`; it caused authentication failures in observed real setups. Preserve normal authentication and constrain the role through permissions, tools, system instructions, and session structure.

No hard `--max-turns` is used. Claude Code's print-mode max-turn limit can terminate before a final review is emitted; background review should finish naturally.

## Authentication / runtime diagnostics

Default mode:

```bash
export LUNA_ORCH_CLAUDE=auto
```

- `auto`: requires `claude auth status` to succeed.
- `on`: skip the auth-status precheck and attempt Claude directly.
- `off`: disable Claude; use Luna reviewer fallback.

Check authentication separately from background runtime health:

```bash
claude auth status
claude doctor
```

`loggedIn: true` does not prove that the background daemon can create its job
state or that its control socket is alive. `EROFS` under `~/.claude/jobs` is a
host/sandbox write-permission failure. `ECONNREFUSED` or `ENOENT` for a
`control.sock` is a daemon/socket failure. Inspect the exact process and
socket, move only a confirmed stale socket directory aside if needed, and
retry deliberately; do not interpret either error as an Opus request for code
permission.

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

v6.6 stores both and rejects empty agent IDs during JSON matching. This matters
because a sticky re-review/follow-up can run as a new supervised background
job while still being the **same conversation**. If the recorded job's actual
`sessionId` differs from the saved one, stop and inspect; never silently resume
another conversation.

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
2. query `claude agents --json --all` for lifecycle state and conversation `sessionId`;
3. only after lifecycle `state=done`, collect recent output with `claude logs <id>`;
4. persist/verify sessionId for sticky re-review and advisor follow-up.

`status=idle` is only an activity substate. A terminal `Worked ... · done`
footer in `claude logs` means the latest turn rendered, and may appear while
the background session remains open. Treat a complete contract in that log as
turn-complete but lifecycle-open; do not retry or resume it. Do not infer
completion from elapsed time or Codex shell behavior.

For a review result, require `VERDICT`, `BLOCKERS`, `NONBLOCKING`, `TEST_GAPS`,
and `PREVIOUS_FINDINGS`. The review helper rejects a collected log missing one
of these headings instead of treating a bare `done` marker as a verdict.

## macOS caveat

Claude background sessions can be affected by macOS privacy restrictions when repositories live under Desktop, Documents, or Downloads. Address the OS/location issue instead of repeatedly spawning new reviewers.
