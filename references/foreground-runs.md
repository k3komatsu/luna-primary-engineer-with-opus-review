# Claude synchronous run lifecycle

The helpers use one synchronous Claude call per operation. The invoking shell
owns the lifetime, so completion is determined by the process exit code and the
files it writes.

## State machine

```text
running
  -> done       result.txt exists and exit code is 0
  -> blocked    Claude exits with a network/API or proxy error
  -> failed     Claude exits for another reason or output is invalid
```

`status` reads `stage` and `run_exit_code`; it never polls another process.
`collect` is valid only for `stage=done`.

`blocked` is not a review verdict. It means the synchronous Claude process
could not reach Anthropic from the current command environment. The state keeps
the original `session_id` and can be retried after network access is restored.

## State directory

Ordinary review state contains:

```text
review-packet.md
packet_path
session_id
stage
run_exit_code
result.txt
rereview-N/
network-retry-N/
```

Dual-review and panel branches additionally archive their first result as
`initial-result.txt`.

Panel and dual-review state use the same files under `seed/` and one directory
per role. A result directory is single-use for its initial run. Ordinary
re-review uses the stored `session_id` and the same Claude conversation;
panel follow-up remains a fresh call with explicit prior-result context.

## Interruption and failure

Press Ctrl-C in the terminal running Claude. An interrupted initial call leaves
its partial output and non-zero or absent exit marker; inspect the state before
trying again. A network-blocked initial call is recorded as `stage=blocked`; run
`retry` on that same state with network-enabled command execution. A network-
blocked re-review keeps its current round blocked; rerun `resume` with the same
fix delta. A non-network failed ordinary re-review marks both the round and
its parent state as failed, so `collect` cannot return the previous successful
result; rerun `resume` to retry the failed round in the stored session. Do not
treat a partial result as a review verdict.

If the Claude preflight fails before launch, or the user disabled Claude before
launch, use the Luna reviewer fallback with its explicit preflight markers.
Once Claude has launched, never invoke the fallback, retry, or create a second
state while the run is pending. A shell/tool timeout or missing intermediate
output is not evidence that a launched review is unavailable. If the process
has exited and the helper records `blocked_reason=network`, retry the same
state/session with network-enabled command execution. Do not use the fallback.
If the launched call reaches terminal non-network `failed`, report it and wait
for a user decision.

## Commands

```bash
claude-review.sh start packet.md state reviewer-1
claude-review.sh status state
claude-review.sh collect state
claude-review.sh retry state
claude-review.sh resume state fix-delta.md

claude-panel.sh start context.md roles panel
claude-panel.sh status panel
claude-panel.sh advance panel
claude-panel.sh collect panel
claude-panel.sh followup panel/analyst delta.md
```
