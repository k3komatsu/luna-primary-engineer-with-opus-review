---
name: luna-primary-engineer
description: Context-efficient Codex engineering workflow. Luna Max/Fast is the persistent Primary Engineer with Ponytail FULL; Claude Opus provides optional read-only foreground review and focused multi-angle advice; Luna workers are parallel-only; Sol/Astra are rare final advisors.
---

# Luna Primary Engineer v6.6

Operate as the **Primary Engineer**, not as a manager that reflexively delegates.

Recommended root configuration:

- **Model:** GPT-5.6 Luna
- **Reasoning:** **max**
- **Speed / service tier:** **Fast**

The Primary owns the task end-to-end by default: understand, investigate, plan,
implement, test, fix, integrate, and communicate. Reuse the context already
paid for; duplicate intelligence only when independence, real parallelism, or
superior expertise is worth the extra cost.

## Primary implementation: Ponytail FULL

Before substantive implementation, read and apply:

`references/ponytail/SKILL.md`

Use Ponytail at **FULL** intensity. Find the smallest correct, maintainable
solution without omitting required validation, safety, compatibility, or
architecture boundaries.

## Default workflow

1. Primary understands the relevant code and invariants.
2. Primary plans one coherent change unit.
3. Primary implements with Ponytail FULL.
4. Primary runs focused checks and tests.
5. Before a review, run the Claude preflight. If it passes, run one read-only
   Claude review with `scripts/claude-review.sh`.
6. The review command waits for Claude to finish and writes `result.txt`. If
   the shell tool yields a session ID, keep polling that same shell session;
   do not start another reviewer while it is alive.
7. Fix concrete findings, then use `resume` with a fix delta. This continues the
   same Claude review session in a new foreground turn, so the reviewer keeps
   its prior findings without starting a separate review conversation.
8. Finish when the review passes or the Primary explicitly accepts residual risk.

Claude review is optional. Use `luna_reviewer` only when the preflight check
fails before Claude is launched, or when the user explicitly disables Claude
before starting the review. It is not a timeout or in-flight fallback.

## Opus single-flight rule

Once `claude-review.sh start`, `resume`, `dual-start`, `dual-advance`, or a
panel run has launched Claude, that run owns the review until it reaches a
terminal state. While it is running or its state is unknown:

- never invoke `luna_reviewer`;
- never create `state2`, retry, resume, fork, or launch a duplicate;
- never interpret a shell/tool timeout, missing intermediate output, or
  `Request timed out` from the waiting command as proof that Claude is
  unavailable;
- wait on the same shell session with `write_stdin` when one was returned, or
  check the same state directory at a natural interval.

Only a completed `stage=done` may be collected. If the launched Claude call
eventually reaches `stage=failed`, report that terminal failure and stop for a
user decision; do not silently spend another reviewer call. The Luna fallback
requires both literal markers `LUNA_CLAUDE_PREFLIGHT_FALLBACK` and
`CLAUDE_NOT_LAUNCHED`, as described in `codex-agents/luna_reviewer.toml`.

## Foreground Claude contract

All repository review and advisory helpers use `claude -p` and wait for the
process to exit. They do not dispatch asynchronous sessions, query job
registries, attach to terminals, or depend on daemon sockets. Ordinary review
`start` stores an explicit Claude session ID and `resume` reuses it; dual and
panel calls intentionally use non-persistent sessions for independence.

The read-only invocation uses:

```bash
claude -p \
  --model opus --effort xhigh \
  --permission-mode dontAsk --permission-prompts none \
  --tools "Read,Glob,Grep" --disallowedTools "mcp__*" \
  --disable-slash-commands --no-chrome \
  --add-dir "$PWD" -- \
  "Read the supplied packet and return the requested artifact."
```

The initial ordinary review adds `--session-id <uuid>`; a re-review replaces
that with `--resume <uuid>`. Independent dual-review and panel calls add
`--no-session-persistence` instead.

Foreground Claude calls default the API request timeout, stream idle,
byte-stream idle, and first-byte timeout variables to `600000` (10 minutes)
when unset, and preserve explicitly supplied values.

The helper appends the role system prompt and captures combined output plus the
exit code. `status` and `collect` inspect files already written by that finished
run. Press Ctrl-C in the invoking terminal to interrupt a live call.

Do not use asynchronous Claude execution for this skill. Do not use Claude
agent registries or terminal-log collection as a completion signal. A saved
session ID is used only to continue an ordinary review conversation; the
result file and process exit code remain the completion signals.

## Review result contract

An ordinary review is usable only when the result contains all headings:

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK
BLOCKERS:
NONBLOCKING:
TEST_GAPS:
PREVIOUS_FINDINGS:
```

`claude-review.sh collect` rejects an incomplete result. A `resume` run must
re-check the previous findings and report OPEN/CLOSED status in
`PREVIOUS_FINDINGS`.

## Ordinary review

```bash
bash scripts/claude-review.sh start REVIEW_PACKET STATE_DIR reviewer-1
bash scripts/claude-review.sh status STATE_DIR
bash scripts/claude-review.sh collect STATE_DIR
bash scripts/claude-review.sh resume STATE_DIR FIX_DELTA
```

`start` blocks until the review completes. `status` reports the stored stage;
it does not poll Claude. `resume` continues the stored Claude session in a new
foreground turn with the fix delta.

## High-risk dual review

Use only when an independent second opinion has unusually high value:
security/authentication, destructive data behavior, subtle concurrency or
ordering, public protocols, delicate mathematics, broad compatibility changes,
or serious reviewer disagreement.

```bash
bash scripts/claude-review.sh dual-start REVIEW_PACKET GROUP_DIR
bash scripts/claude-review.sh dual-status GROUP_DIR
bash scripts/claude-review.sh dual-advance GROUP_DIR
bash scripts/claude-review.sh dual-collect GROUP_DIR
```

`dual-start` loads the neutral seed in the foreground. `dual-advance` then runs
the two blind reviewer calls sequentially. Each reviewer reads the factual
packet and neutral seed but receives a fresh Claude process.

## Opus advisory panel

Use a panel only when the difficult part is reasoning rather than routine
implementation. Prepare a factual `context.md` and 2..6 role files.

```bash
bash scripts/claude-panel.sh start CONTEXT_FILE ROLES_DIR OUTPUT_DIR
bash scripts/claude-panel.sh status OUTPUT_DIR
bash scripts/claude-panel.sh advance OUTPUT_DIR
bash scripts/claude-panel.sh collect OUTPUT_DIR
bash scripts/claude-panel.sh followup BRANCH_DIR DELTA_FILE
```

The seed and every role call run in the foreground. Role calls are sequential
and independent; Luna synthesizes the results by evidence, never by majority
vote. A follow-up reads the branch's previous result and the new delta in a
fresh foreground call.

## Claude safety boundary

Reviewer and panel prompts are read-only:

- `--permission-mode dontAsk`
- `--permission-prompts none`
- tools limited to `Read,Glob,Grep`
- MCP tools explicitly denied with `mcp__*`
- no repository editing or implementation
- no recursive subagents

If `ANTHROPIC_API_KEY` is set, treat Claude usage as potentially API-billed.

Use `claude auth status` and `claude doctor` for authentication diagnostics.

## Other roles

### `luna_worker` — parallel-only

Use only when genuine wall-clock parallelism, isolation, or an intentionally
independent implementation justifies duplicated context. Workers do not spawn
other agents and remain available through integration of their contribution.

### Sol advisor

Use for one narrow unresolved judgment after cheaper evidence is insufficient.
Sol advises; Luna implements.

### Astra expert

Reserve for exceptionally high-impact unresolved mathematical, protocol,
concurrency, distributed, or irreversible-design questions.

There is no `luna_explorer`; normal repository investigation belongs to the
Primary.

## Final decision hierarchy

```text
Luna Primary + Ponytail
  -> focused checks
  -> optional foreground Claude review
  -> Luna fixes and sticky foreground re-review
  -> accepted result
```

The goal is useful independent verification with the smallest reliable amount
of duplicated context and model usage.
