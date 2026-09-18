# Claude review lifecycle

## State machine

```text
queued/running
  -> done       designated result exists and passes its contract
  -> blocked    Claude exits with a recognizable network/API error
  -> failed     Claude exits otherwise, writes an invalid result, or escapes the boundary
```

`status` reads the stored state and background PID; it never starts a retry.
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
packet_path
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

An empty stdout stream is harmless when the designated file is complete. A
missing, empty, or incomplete designated file is a technical failure and its
stdout/stderr diagnostics are reported. It is never an automatic retry
condition. A network-blocked state is retried only by an explicit user-approved
`retry` or `resume` using the same ordinary session. CLI validation errors,
unsupported permission rules, and `No conversation found` are not network
blocks even if stdout also contains `Request timed out`; they remain terminal
and must not cause a new session to be created automatically.

If Claude preflight fails before launch, or the user disabled Claude before
launch, use the Luna fallback with its explicit markers. Once Claude has
launched, never use the fallback, create a second state, or duplicate the
review.

## Commands

```bash
claude-review.sh start packet.md [state] [label]
claude-review.sh start-background packet.md [state] [label]
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
