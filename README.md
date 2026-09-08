# Luna Orchestrator v6.5 for Codex Desktop / CLI

v6.5 keeps **Luna Max/Fast** as the persistent Primary Engineer, uses **Ponytail FULL** for implementation economy, and uses Claude Opus as an optional external reviewer / difficult-task reasoning accelerator.

v6.5 keeps the background-job reliability model and changes reviewer continuity:

> **Reviewer 1 is fresh once, then its same Claude conversation is resumed until PASS. Fork only when independence is intentional.**

Long Opus work still runs as Claude Code background sessions, so Codex shell wait/yield behavior is not treated as Claude failure. v6.5 additionally tracks the short background job ID separately from Claude's full conversation `sessionId`, using the latter for sticky re-review/advisor continuation.

## Architecture

```text
                                 difficult reasoning
                           neutral Opus seed --bg
                                  state=done
                              /      |      \
                       fork --bg fork --bg fork --bg
                         analyst  skeptic  specialist ...
                              \      |      /
                               Luna synthesis
                                      |
User -> Luna Max/Fast Primary + Ponytail FULL
        investigate / plan / implement / test / fix
                                      |
                                 coherent change
                                      |
                           Opus Reviewer 1 --bg
                                      |
                           working? leave it alone
                                      |
                                   done
                                      |
                               collect logs
                                      |
                                Primary fixes
                                      |
                   resume SAME reviewer session --bg
                                      |
                                  re-review

Fallback if Claude unavailable: Luna Max reviewer
Parallel-only: Luna Max Worker + Ponytail
Still unresolved: sticky Sol -> exceptional Astra
```

## Roles

| Role | Model | Effort | Ponytail | Purpose |
|---|---|---:|---|---|
| **Primary Engineer** | Luna | **Max / Fast** | **FULL** | default end-to-end engineering |
| Opus Reviewer 1 | Claude Opus | **xhigh default** | OFF | ordinary independent background review |
| Dual Reviewers | Claude Opus ×2 | **xhigh default** | OFF | high-risk blind background forks from neutral seed |
| Opus Panel | Claude Opus ×3-4 | **max default** | OFF | difficult-task multi-angle background reasoning |
| `luna_reviewer` | Luna | **Max** | OFF | review fallback |
| `luna_worker` | Luna | **Max** | **FULL** | parallel-only implementation |
| `sol_advisor` | Sol | Max | OFF | narrow unresolved judgment |
| `astra_expert` | Astra | Max | OFF | exceptional final escalation |

All Luna roles use **max** reasoning. No `luna_explorer`.

## The v6.5 hard rule

Claude background state, not elapsed time, determines what to do:

```text
working / idle -> healthy/in progress; DO NOT retry/resume/fork/duplicate
blocked        -> inspect logs/input need; DO NOT auto-replace
done           -> collect result; same session may resume, or fork only for independence
failed/stopped -> inspect cause before any retry
unknown        -> inspect agent listing/logs before acting
```

A Codex shell tool yielding or reaching its own wait ceiling is **not** a Claude failure signal.

## Ordinary Opus review

Dispatch and immediately return control to Codex:

```bash
bash scripts/claude-review.sh start /tmp/review.md /tmp/reviewer-1 reviewer-1
```

At a natural work boundary:

```bash
bash scripts/claude-review.sh status /tmp/reviewer-1
```

When `done`:

```bash
bash scripts/claude-review.sh collect /tmp/reviewer-1
```

After Luna fixes findings:

```bash
bash scripts/claude-review.sh resume /tmp/reviewer-1 /tmp/fix-delta.md
```

`resume` deliberately reuses the **same completed Reviewer conversation**. It resolves and stores Claude's full conversation `sessionId`, resumes that `sessionId` without `--fork-session`, and verifies that a resumed run did not silently switch conversations. `working`/`blocked` sessions cannot be resumed.

The same `STATE_DIR` remains the Reviewer 1 identity across re-review rounds. Per-round deltas/results are archived under `rereview-N/`, while `status`/`collect` continue to target the same `STATE_DIR`.

## Dual high-risk review

Start one neutral background seed:

```bash
bash scripts/claude-review.sh dual-start /tmp/review.md /tmp/dual-review
```

Check seed state:

```bash
bash scripts/claude-review.sh dual-status /tmp/dual-review
```

Only after seed is `done`:

```bash
bash scripts/claude-review.sh dual-advance /tmp/dual-review
```

This dispatches two blind reviewer forks. Later:

```bash
bash scripts/claude-review.sh dual-collect /tmp/dual-review
```

Use dual review only when a second independent opinion is worth the extra Claude quota: security/auth, destructive/persistent-data behavior, subtle concurrency/lifetime/order, public/wire protocol or ABI changes, delicate mathematical/numerical correctness, major cross-cutting invariants, serious Reviewer/Primary disagreement, or explicit user request.

## Opus Advisory Panel

Prepare a factual `context.md` and 3-4 role files, e.g.:

```text
root-cause analyst
falsifier of leading hypothesis
concurrency/lifecycle specialist
alternative mechanism hunter
```

Start the neutral background seed:

```bash
bash scripts/claude-panel.sh start /tmp/context.md /tmp/roles /tmp/panel
```

Later:

```bash
bash scripts/claude-panel.sh status /tmp/panel
```

After seed is `done`:

```bash
bash scripts/claude-panel.sh advance /tmp/panel
```

The role branches are then dispatched as independent background forks. A useful completed branch can later be kept as a sticky advisor by resuming that same branch conversation.

```bash
bash scripts/claude-panel.sh collect /tmp/panel
```

Luna synthesizes by evidence, never majority vote. Panel size is 2..6, with 3-4 recommended.

A particularly useful completed branch can become a same-domain sticky advisor:

```bash
bash scripts/claude-panel.sh followup /tmp/panel/root-cause /tmp/new-question.md
```

Never follow up a branch while it is `working` or `blocked`.

## Generic background-job helper

```bash
bash scripts/claude-job.sh status STATE_DIR
bash scripts/claude-job.sh logs STATE_DIR
bash scripts/claude-job.sh collect STATE_DIR
bash scripts/claude-job.sh stop STATE_DIR
```

The helpers never automatically retry a failed/stopped/unknown job.

## Cache-preservation rules

For seed-and-fork fan-out, keep these stable between seed and branches:

- Claude model;
- effort level;
- tool set;
- permission mode;
- appended system prompt;
- working directory / shared added directory.

The neutral seed loads common facts but must not diagnose or recommend. Forks inherit shared history without inheriting another expert's conclusion.

## Claude read-only boundary

v6.5 long Claude work uses `claude --bg`, **not `claude -p`**.

Helpers use:

```text
--permission-mode plan
--tools Read,Glob,Grep
--disallowedTools mcp__*
--disable-slash-commands
--no-chrome
```

No `--bare` is used because it caused authentication failures in observed setups. No hard `--max-turns` cap is used.

`--tools` alone does not disable MCP tools, hence the explicit `mcp__*` deny.

## Claude quota / billing controls

Defaults:

```bash
export LUNA_ORCH_CLAUDE=auto
export LUNA_ORCH_CLAUDE_MODEL=opus
export LUNA_ORCH_CLAUDE_REVIEW_EFFORT=xhigh
export LUNA_ORCH_CLAUDE_PANEL_EFFORT=max
```

Set `LUNA_ORCH_CLAUDE=off` to force Luna review/no Opus panel. `on` skips the auth-status precheck; `auto` requires `claude auth status` to succeed.

If `ANTHROPIC_API_KEY` is set, the scripts warn because Claude usage may be API-billed rather than coming from the intended subscription context.

## macOS background caveat

Claude background sessions can have macOS privacy restrictions when repositories are under Desktop, Documents, or Downloads. If a reviewer cannot read files there, fix the OS/location issue rather than repeatedly spawning new reviewers.

## Install on macOS

First install needs `git` to fetch Ponytail unless a local checkout is supplied.

```bash
unzip luna-orchestrator-v6.5.zip
cd luna-orchestrator
bash scripts/install.sh
```

Offline/local Ponytail:

```bash
LUNA_ORCH_PONYTAIL_SOURCE=/path/to/ponytail bash scripts/install.sh
```

Then fully quit/restart Codex Desktop and start a new session with:

- GPT-5.6 Luna
- Reasoning **Max**
- Speed **Fast**

Invoke:

```text
$luna-orchestrator
```

## Verify

```bash
bash scripts/doctor.sh
```

Doctor checks Claude presence/auth plus the CLI capabilities used by v6.5. Claude remains optional; fallback Luna review is installed.

## Design principles

1. **Primary first:** reuse Luna's existing context.
2. **Ponytail for implementers:** minimize implementation, never requirements.
3. **Independent review:** a separate model lineage validates coherent changes.
4. **Background, not timeout:** long Opus work is supervised outside Codex's shell wait.
5. **Never duplicate `working`:** state, not elapsed time, controls recovery.
6. **Seed once, fork many:** shared context for intentionally independent multi-Opus reasoning/review.
7. **Sticky after identity is chosen:** re-review and same-domain advisor follow-ups resume the same conversation sessionId.
8. **Neutral seed:** shared evidence, never shared conclusion.
9. **Blind branches:** experts/reviewers do not see peer answers.
10. **No model democracy:** Luna synthesizes evidence.
11. **Sol/Astra last:** expensive OpenAI models see only the narrow unresolved point.
