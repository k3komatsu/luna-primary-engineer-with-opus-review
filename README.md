# Luna Primary Engineer v6.6 for Codex Desktop / CLI

v6.6 keeps **Luna Max/Fast** as the persistent Primary Engineer, uses **Ponytail FULL** for implementation economy, and uses Claude Opus as an optional external reviewer / difficult-task reasoning accelerator.

v6.6 keeps the background-job reliability model and changes reviewer continuity:

> **Reviewer 1 is fresh once, then its same Claude conversation is resumed until PASS. Fork only when independence is intentional.**

Long Opus work still runs as Claude Code background sessions, so Codex shell wait/yield behavior is not treated as Claude failure. v6.6 additionally tracks the short background job ID separately from Claude's full conversation `sessionId`, rejects empty-ID matches, and uses the latter for sticky re-review/advisor continuation.

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

## The v6.6 hard rule

Claude background state, not elapsed time, determines what to do:

```text
status=idle    -> activity substate only; inspect lifecycle state
state=working  -> healthy/nonterminal; DO NOT retry/resume/fork/duplicate
state=blocked  -> inspect logs/input need; attach only for an explicit read-only continuation
state=done     -> collect result; same session may resume, or fork only for independence
failed/stopped -> inspect cause before any retry
unknown        -> inspect agent listing/logs before acting
```

A Codex shell tool yielding or reaching its own wait ceiling is **not** a Claude failure signal.

`claude logs JOB_ID` is a terminal redraw, not a structured result. A footer such as
`Worked for 5m 40s · done` means that the latest turn rendered a response; it can
coexist with `status=idle,state=working` while the background conversation or an
attached client remains open. Treat this as **turn-complete but lifecycle-open**:
read the response, do not duplicate the job, and use the helper's formal
`collect`/`resume` gate only after lifecycle `state=done`.

## Short `claude -p` questions

Use `claude -p` / `--print` for a small, bounded, one-turn question whose answer can
be consumed from stdout. It has no background job ID, no `claude agents` state, no
`collect`, and no sticky `resume`; capture the exit code and output yourself.

```bash
claude -p \
  --model opus --effort xhigh \
  --permission-mode dontAsk --permission-prompts none \
  --tools "Read,Glob,Grep" --disallowedTools "mcp__*" \
  --disable-slash-commands --no-chrome --add-dir "$PWD" \
  "Read source/v4/config.d and answer this bounded question: ..."
```

Use a background review helper for a repository-wide review or anything likely to
take more than one short turn. Do not use `--bare`; it can bypass the normal
authentication sources used by background sessions. A shell timeout or yield is
not evidence that `claude -p` failed unless its process actually returned a
non-zero exit code.

## Ordinary Opus review

Dispatch and immediately return control to Codex:

```bash
bash scripts/claude-review.sh start /tmp/review.md /tmp/reviewer-1 reviewer-1
```

At a natural work boundary:

```bash
bash scripts/claude-review.sh status /tmp/reviewer-1
```

For a manual check, inspect both the lifecycle and the visible turn:

```bash
claude agents --json --all
claude logs JOB_ID
```

To inspect one row without confusing an empty interactive-session ID with the
background job:

```bash
JOB_ID=7c5dcf5d
claude agents --json --all | jq -r --arg id "$JOB_ID" '
  first(.[] | (.id // "") as $rid
    | select($rid != "" and ($rid == $id or ($rid | startswith($id)) or ($id | startswith($rid)))))
  // {state:"unknown"}
  | "id=\(.id // "") state=\(.state // "unknown") status=\(.status // "") sessionId=\(.sessionId // "")"
'
```

To find the contract headings in the terminal redraw (ANSI control sequences
removed):

```bash
claude logs "$JOB_ID" |
  perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\e\][^\a]*\a//g; s/\r/\n/g' |
  rg -n 'VERDICT|BLOCKERS|NONBLOCKING|TEST_GAPS|PREVIOUS_FINDINGS|Worked for'
```

The review is usable only when its response contains all five headings:
`VERDICT`, `BLOCKERS`, `NONBLOCKING`, `TEST_GAPS`, and `PREVIOUS_FINDINGS`.
Interpret the verdict as follows:

```text
PASS             -> review closed
CHANGES_REQUIRED -> fix the listed blockers, write a fix delta, then resume the same reviewer
PASS_WITH_RISK   -> record the residual risk and explicitly accept it before closing
```

Do not treat a `done` footer, a `status=idle` line, or a partial response as a
verdict. If the headings are present but lifecycle state is still `working`, do
not create a second reviewer; resolve the open/attached background session and
re-check its state.

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

## Claude runtime troubleshooting

Authentication and background runtime health are separate:

```bash
claude auth status
claude doctor
```

`loggedIn: true` confirms authentication only. `EROFS` while creating
`~/.claude/jobs` is a host/sandbox writeability problem, not a request from Opus
for code-edit approval. `ECONNREFUSED` or `ENOENT` for a daemon
`control.sock` means the control daemon/socket is unavailable. Inspect the exact
process and socket, move only a confirmed stale socket directory aside, and retry
once. Never reuse a state directory with an old `job_id` or `session_id`; record
the new short job ID and full `sessionId` together.

If a legacy/interactive run is genuinely blocked at a plan or input prompt, attach
to that exact short job ID and send one explicit read-only continuation, for example:

```bash
claude attach "$JOB_ID"
# In the attached Claude terminal:
# Continue the read-only review now. Do not edit files or wait for approval;
# inspect the remaining evidence and finish with the required review contract.
```

Return to the shell with the attach command's documented terminal control, then
re-check `claude agents --json --all`. Do not use this procedure for a normal
`status=idle,state=working` job whose review is still progressing.

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

Long Claude work uses `claude --bg`; short bounded questions may use `claude -p`
as documented above.

Helpers use:

```text
--permission-mode dontAsk
--permission-prompts none
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
export LUNA_PRIMARY_ENGINEER_CLAUDE=auto
export LUNA_PRIMARY_ENGINEER_CLAUDE_MODEL=opus
export LUNA_PRIMARY_ENGINEER_CLAUDE_REVIEW_EFFORT=xhigh
export LUNA_PRIMARY_ENGINEER_CLAUDE_PANEL_EFFORT=max
```

Set `LUNA_PRIMARY_ENGINEER_CLAUDE=off` to force Luna review/no Opus panel. `on` skips the auth-status precheck; `auto` requires `claude auth status` to succeed.

If `ANTHROPIC_API_KEY` is set, the scripts warn because Claude usage may be API-billed rather than coming from the intended subscription context.

## macOS background caveat

Claude background sessions can have macOS privacy restrictions when repositories are under Desktop, Documents, or Downloads. If a reviewer cannot read files there, fix the OS/location issue rather than repeatedly spawning new reviewers.

## Install on macOS

First install needs `git` to fetch Ponytail unless a local checkout is supplied.

```bash
unzip luna-primary-engineer-v6.6.zip
cd luna-primary-engineer
bash scripts/install.sh
```

Offline/local Ponytail:

```bash
LUNA_PRIMARY_ENGINEER_PONYTAIL_SOURCE=/path/to/ponytail bash scripts/install.sh
```

Then fully quit/restart Codex Desktop and start a new session with:

- GPT-5.6 Luna
- Reasoning **Max**
- Speed **Fast**

Invoke:

```text
$luna-primary-engineer
```

## Verify

```bash
bash scripts/doctor.sh
bash scripts/self-test.sh
```

Doctor checks Claude presence/auth plus the CLI capabilities used by v6.6. Claude remains optional; fallback Luna review is installed.

## Design principles

1. **Primary first:** reuse Luna's existing context.
2. **Ponytail for implementers:** minimize implementation, never requirements.
3. **Independent review:** a separate model lineage validates coherent changes.
4. **Background, not timeout:** long Opus work is supervised outside Codex's shell wait.
5. **State before footer:** lifecycle `state`, not `status=idle`, elapsed time, or a terminal log footer controls recovery.
6. **Seed once, fork many:** shared context for intentionally independent multi-Opus reasoning/review.
7. **Sticky after identity is chosen:** re-review and same-domain advisor follow-ups resume the same conversation sessionId.
8. **Neutral seed:** shared evidence, never shared conclusion.
9. **Blind branches:** experts/reviewers do not see peer answers.
10. **No model democracy:** Luna synthesizes evidence.
11. **Sol/Astra last:** expensive OpenAI models see only the narrow unresolved point.
