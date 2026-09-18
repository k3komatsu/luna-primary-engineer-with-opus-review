---
name: luna-primary-engineer
description: Context-efficient Codex engineering workflow. Luna Max/Fast is the persistent Primary Engineer with Ponytail FULL; Claude Opus provides optional read-only foreground review and focused multi-angle advice; Luna workers are parallel-only; Sol/Astra are rare final advisors.
---

# Luna Primary Engineer v6.8.0

Operate as the Primary Engineer, not as a manager that reflexively delegates.
Luna owns investigation, planning, implementation, testing, integration, and
communication. Use independent review only when its additional evidence is
worth the Claude usage.

## Primary implementation: Ponytail FULL

Before substantive implementation, read and apply:

`references/ponytail/SKILL.md`

Use Ponytail at FULL intensity. Keep the solution minimal while retaining the
required validation, safety, compatibility, and architecture boundaries.

## Default workflow

1. Luna understands the task and its invariants.
2. Luna plans one coherent change unit.
3. Luna implements it and runs focused checks.
4. If requested or useful, run one Claude Opus review with
   `scripts/claude-review.sh start`.
5. Wait for that foreground process to finish. Collect only a completed,
   validated result file.
6. Fix concrete findings, evaluate their importance, the fix scope, and
   regression risk, then run `resume` when any axis is high. This continues
   the same Claude session and preserves the sticky re-review context.
7. If all three axes are low, skip re-review, run focused checks, and report
   the checks and skip rationale. Finish on PASS or accepted residual risk.

Claude review is optional. Use `luna_reviewer` only when the Claude preflight
fails before Claude is launched, or when the user disables Claude before
launch. It is never a timeout, output, network, or in-flight fallback.

Every Claude review, re-review, retry, dual branch, and panel role consumes
Claude usage. An ordinary same-session re-review immediately after fixing
findings may proceed without additional user approval under the decision rule
below. Initial reviews, technical retries, process-loss reruns, dual reviews,
and panel calls still require explicit user approval. An empty stdout stream
is not a retry condition.

## Re-review decision

After fixing review findings, evaluate three axes:

- finding importance is high for blockers or material correctness, security,
  data-loss, compatibility, or public-contract concerns;
- fix scope is broad when it crosses subsystems, public interfaces, shared
  behavior, or multiple data-flow boundaries;
- regression risk is high for shared logic, authentication, persistence or
  migration, concurrency, protocols, broad compatibility, or weak coverage.

If any axis is high, run a same-session `resume` with the fix delta without
asking for additional user approval. If all axes are low, do not re-review;
run focused checks and tell the user why re-review was skipped. Apply the same
rule after later re-review fixes. A retry after network, CLI, result-contract,
or process failure is technical recovery, not an ordinary fix re-review, and
always requires explicit user approval.

## Opus single-flight rule

Once `claude-review.sh start`, `resume`, `retry`, `dual-start`,
`dual-advance`, or a panel operation has launched Claude, that operation owns
the review until its state reaches a terminal stage. While it is running or
unknown:

- never invoke `luna_reviewer`;
- never create `state2`, fork, retry, resume, or launch a duplicate;
- never treat a shell/tool timeout, missing intermediate output, or
  `Request timed out` from the waiting command as proof that Claude is done;
- continue polling the same process/state when the caller can wait.

Never stop a launched Opus process. Do not send SIGINT, SIGTERM, or SIGKILL,
invoke `kill`, `pkill`, `killall`, or use an equivalent process-termination
action for an initial review, re-review, dual review, panel role, or follow-up.
If continuous waiting may not be possible, choose the explicit background
form before launch.

Only the ordinary fix re-review selected by the three-axis rule may spend
another Claude turn without another user decision. Other retries, resumes, or
new reviews require explicit approval. A network-blocked state is not a
code-review verdict; it preserves the same session and diagnostics for an
approved retry. A non-network `failed` state is terminal until the user
decides what to do.

The Luna fallback requires both literal markers
`LUNA_CLAUDE_PREFLIGHT_FALLBACK` and `CLAUDE_NOT_LAUNCHED`, as described in
`codex-agents/luna_reviewer.toml`.

## Synchronous and explicit background lifecycle

Ordinary `start` and `resume` are synchronous `claude -p` foreground calls.
They wait for Claude to exit and never cut a PTY to force a result. If the
caller must stop waiting, use the explicit wrapper-owned forms:

```bash
bash scripts/claude-review.sh start-background REVIEW_PACKET [STATE_DIR] [LABEL]
bash scripts/claude-review.sh status STATE_DIR
bash scripts/claude-review.sh resume-background STATE_DIR FIX_DELTA
```

These forms detach the wrapper with persisted runner and Claude PIDs, then use
the same `status`/`collect` files. They do not use the Claude daemon or
Claude's own `--bg` session registry. `status` checks the system process list
without sending a signal. If both processes are gone while the state remains
non-terminal and no adopted result exists, it records
`failure_reason=process_gone_without_result`, reports
`USER_CONFIRMATION_REQUIRED=1`, and returns the normal failed-state status.
Ask the user whether to run Opus again; never relaunch automatically.
If PID liveness is `unknown` or
`PROCESS_LIST_PERMISSION_REQUIRED=1`, `ps` was rejected by the sandbox. Do not
change state or relaunch. Request execution-permission escalation and rerun
`status` with system process-list access.

`dual-start`, `dual-advance`, and panel operations remain sequential foreground
calls. The panel and dual paths use the same result-file and workspace rules.

## Review workspace and state

Before creating a review, resolve the Git worktree root from the current
working directory with `git rev-parse --show-toplevel`, canonicalize it, and
use:

```text
<worktree-root>/tmp/luna-primary-engineer/reviews/<unique-id>/
```

The helper creates missing directories with `mkdir -p` only. It never removes
or recursively replaces existing contents. The worktree `tmp` directory and
every review path component must not be a symlink and must not resolve to a
system temporary directory. Explicit state/group paths outside this workspace
are rejected. Packets, state, result files, stdout/stderr diagnostics, attempt
metadata, session IDs, and background logs all live under the review directory.

Do not use a system temporary directory, `TMPDIR`, `mktemp`, or a path outside
the worktree review workspace for review state. The repository's `tmp/` should
be ignored by Git.

## Result-file contract and handoff

Claude does not return the review by stdout. Each call receives one exact
absolute designated result path. With Claude Code 2.1.266 and compatible
versions, the wrapper exposes `Write` but scopes the file permission with the
`Edit` rule:

```text
Edit(//absolute/result/path)
```

Claude Code uses `Edit(path)` permission rules for all file-editing tools,
including `Write`. The `--tools` allowlist exposes only `Read,Glob,Grep,Write`,
and the wrapper denies Bash and MCP; it does not pass unsupported deny names
such as `MultiEdit`. The reviewer system prompt explicitly says
`指定結果ファイル以外は絶対に編集しない` and forbids editing implementation
files. The wrapper validates the path and snapshots the repository status
before and after the call as a best-effort detector for newly introduced
changes; the exact `Edit(path)` permission is the actual read-only boundary.

When the shell variable already contains an absolute path such as
`/home/.../reviewer-result.md`, pass `--allowedTools "Edit(/$result_file)"`.
The resulting rule is `Edit(//home/.../reviewer-result.md)`; the doubled
leading slash is intentional because Claude Code treats a single leading slash
as project-relative.

The presence of `--allowedTools` in `claude --help` alone does not prove that
every permission-rule spelling is supported. If the CLI does not expose a
usable path-scoped file rule, the helper does not enable a generic write tool.
It asks for a framed `LUNA_RESULT_BEGIN` / `LUNA_RESULT_END` handoff, writes
that validated frame into the designated file itself, and then treats the
file—not raw stdout—as the canonical result. `LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF=stdout`
can force this conservative mode for testing or compatibility.

For an ordinary review and re-review, the designated file must contain all of:

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK
BLOCKERS:
NONBLOCKING:
TEST_GAPS:
PREVIOUS_FINDINGS:
```

After Claude exits, the wrapper checks that the designated file exists, is
non-empty, and contains every heading. Only then is it copied to the state
`result.txt`. stdout and stderr are retained separately as diagnostics and are
never used as the result source. A missing, empty, or incomplete result is a
technical `failed` state with state, exit code, stdout, and stderr paths shown;
it never triggers an automatic re-review.

Seed and panel artifacts use their own contracts (`SEED_READY` or the compact
panel artifact), but they use the same designated-file handoff, diagnostics,
scope check, and worktree workspace.

## Ordinary review

```bash
bash scripts/claude-review.sh start REVIEW_PACKET [STATE_DIR] [LABEL]
bash scripts/claude-review.sh status STATE_DIR
bash scripts/claude-review.sh collect STATE_DIR
bash scripts/claude-review.sh retry STATE_DIR
bash scripts/claude-review.sh resume STATE_DIR FIX_DELTA
```

The initial ordinary call stores an explicit UUID session ID. `resume` uses
`--resume` with that same ID and passes the original packet, previous result,
and fix delta as explicit context. `retry` is only an explicitly requested
retry of an initial network-blocked call and reuses the same session; it does
not create `state2`. A CLI validation error or `No conversation found` is not
a network block and is terminal until the caller explicitly starts a new
review. Re-review findings must be closed or kept open in
`PREVIOUS_FINDINGS`.

The wrapper defaults API, stream-idle, byte-idle, and first-byte timeouts to
600000 milliseconds when unset. Longer waiting is allowed, but it does not
override a network/proxy timeout returned by Claude or an upstream service.

## High-risk dual review

Use only when an independent second opinion has unusually high value:
security/authentication, destructive data behavior, subtle concurrency or
ordering, public protocols, delicate mathematics, broad compatibility, or
serious reviewer disagreement.

```bash
bash scripts/claude-review.sh dual-start REVIEW_PACKET [GROUP_DIR]
bash scripts/claude-review.sh dual-status GROUP_DIR
bash scripts/claude-review.sh dual-advance GROUP_DIR
bash scripts/claude-review.sh dual-collect GROUP_DIR
```

`dual-start` stores a neutral `SEED_READY` artifact. `dual-advance` then runs
two independent, non-persistent reviewers sequentially. Neither reviewer
reads the other's result before completing its own contract.

## Opus advisory panel

Use a panel only when the difficult part is reasoning rather than routine
implementation. Prepare factual context and 2..6 role files.

```bash
bash scripts/claude-panel.sh start CONTEXT_FILE ROLES_DIR [OUTPUT_DIR]
bash scripts/claude-panel.sh status OUTPUT_DIR
bash scripts/claude-panel.sh advance OUTPUT_DIR
bash scripts/claude-panel.sh collect OUTPUT_DIR
bash scripts/claude-panel.sh followup BRANCH_DIR DELTA_FILE
```

The seed and roles are sequential, independent foreground calls. Each role
writes its compact artifact through the same designated-file handoff. A
follow-up reads the prior branch result and new delta in a fresh call.

## Claude safety boundary

Reviewer and panel calls use:

- `--permission-mode dontAsk` and `--permission-prompts none` (this is not
  Plan mode; unapproved tools are denied rather than waiting for approval);
- `Read,Glob,Grep` plus `Write` scoped by the exact absolute `Edit(//path)`
  permission rule when supported;
- no generic Edit, Bash, notebook, or MCP tool;
- no repository implementation editing or recursive subagents.

If `ANTHROPIC_API_KEY` is set, treat Claude usage as potentially API-billed.
Use `claude auth status` and `claude doctor` for authentication and transport
diagnostics. Authentication success does not prove API reachability from a
Codex sandbox. In a network-restricted Codex execution, a real Opus request
may require escalating the sandbox command to network-enabled execution.
Request that authorization before launch when needed; `claude auth status` or
`claude doctor` success alone does not prove that the sandbox can reach the
Anthropic API and is not a review result.

## Other roles

### `luna_worker` — parallel-only

Use only for genuine wall-clock parallelism, isolation, or intentionally
independent implementation. Workers do not spawn other agents.

### Sol advisor

Use for one narrow unresolved judgment after cheaper evidence is insufficient.
Sol advises; Luna implements.

### Astra expert

Reserve for exceptionally high-impact unresolved mathematical, protocol,
concurrency, distributed, or irreversible-design questions.

There is no `luna_explorer`; normal repository investigation belongs to Luna.

## Final decision hierarchy

```text
Luna Primary + Ponytail
  -> focused checks
  -> optional synchronous Claude review
  -> explicit retry only for a blocked transport state
  -> Luna fixes and applies the three-axis re-review decision
  -> sticky synchronous re-review when any axis is high
  -> focused checks and documented skip when all axes are low
  -> accepted result
```

The goal is useful independent verification with the smallest reliable amount
of duplicated context and model usage.
