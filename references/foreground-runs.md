# Claude Opus 5.5 review lifecycle

## State machine

```text
queued/running
  -> done       designated result exists and passes its contract
  -> blocked    Claude exits with a recognizable network/API error
  -> failed     Claude exits otherwise, writes an invalid result, escapes the boundary,
                or all tracked processes disappear before result adoption
```

`status` reads stored state and process PIDs. It may reconcile a stale
running/queued state to failed when all tracked processes are gone without an
adopted result, but it never starts a retry.
`collect` is valid only for `stage=done` and validates the adopted
`result.txt` again.

## Workspace and state

Every operation uses a unique directory below
`<worktree-root>/tmp/luna-primary-engineer/reviews/`. A fresh state directory
must be empty. The helper creates directories but never recursively deletes or
overwrites existing review data.

An ordinary state contains:

```text
review-packet.md
review-prompt.md             # optional reviewer context
packet_path
prompt_path                  # present when review-prompt.md was supplied
session_id
handoff_mode
stage
run_exit_code
result.txt                 # canonical adopted result
attempt-N/
  reviewer-result.md       # designated handoff file
  stdout.txt               # diagnostic only
  stderr.txt               # diagnostic only
  exit_code
  runner_pid
  claude_pid
  repository-before.txt
  repository-after.txt
rereview-N/
network-retry-N/
```

Dual and panel branches use the same attempt layout. Seeds and panel roles
have their own artifact contract, but the result-file and safety rules are the
same.

## Interruption and failure

Foreground `start` and `resume` wait for Claude. If the caller needs to stop
waiting, use `start-background` or `resume-background`; those commands detach
the wrapper while retaining the state and a PID for `status`. Do not cut a PTY
and then launch another reviewer.

Never terminate a launched Opus process, including initial review, re-review,
dual, panel, and follow-up calls. `status` checks runner and Claude PIDs through
the system process list without sending signals. If both are absent while the
state is still running/queued and no adopted result exists, `status` changes
the state to `failed`, writes
`failure_reason=process_gone_without_result` and
`user_confirmation_required=1`, and returns 12. Ask the user before another
Opus call. After approval, start a fresh state for a lost initial review,
resume the same session and fix delta when a lost re-review remains resumable,
or start a fresh group for dual/panel work.

If `ps` is denied by the sandbox, `RUNNER_ALIVE` or `CLAUDE_ALIVE` is
`permission_denied` and `PROCESS_LIST_PERMISSION_REQUIRED=1`. A different
`unknown` value means another process-list error. Either value means process
inspection is inconclusive: do not infer process loss, change state, or
relaunch; obtain execution-permission escalation and rerun `status`.

An empty stdout stream is harmless when the designated file is complete. A
missing, empty, or incomplete designated file is a technical failure and its
stdout/stderr diagnostics are reported. It is never an automatic retry
condition. A network-blocked state is retried only by an explicit user-approved
`retry` or `resume` using the same ordinary session. CLI validation errors,
unsupported permission rules, and `No conversation found` are not network
blocks even if stdout also contains `Request timed out`; the latter is recorded
as `failure_reason=claude_session_not_found`. They remain terminal and must
not cause a new session to be created automatically; `resume` and
`resume-background` refuse such a state with exit code 10. Ordinary
same-session re-review after fixes is the only re-review that may proceed
without another user approval, and only under the three-axis rule in the
review protocol.

If Claude preflight fails before launch, or the user disabled Claude before
launch, use the Luna fallback with its explicit markers. Once Claude has
launched, never use the fallback, create a second state, or duplicate the
review.

## Commands

```bash
claude-review.sh start REVIEW_INPUT [state] [label]
claude-review.sh start-background REVIEW_INPUT [state] [label]
claude-review.sh status state
claude-review.sh collect state
claude-review.sh retry state
claude-review.sh resume state fix-delta.md
claude-review.sh resume-background state fix-delta.md

claude-panel.sh start context.md roles [output]
claude-panel.sh status output
claude-panel.sh advance output
claude-panel.sh collect output
claude-panel.sh followup output/role delta.md
```

`REVIEW_INPUT` may be the legacy packet file or a directory containing the
required `review-packet.md` and optional `review-prompt.md` (`prompt.md` is a
compatibility alias). The wrapper copies the bundle into a newly-created,
empty state directory. Do not pre-populate the state directory; its contents
are protected review state, not input staging. Bundle members must be
non-empty regular files and must not be symlinks.
