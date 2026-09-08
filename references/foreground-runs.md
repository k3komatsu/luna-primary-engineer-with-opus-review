# Claude foreground run lifecycle

The helpers use one synchronous Claude call per operation. The invoking shell
owns the lifetime, so completion is determined by the process exit code and the
files it writes.

## State machine

```text
running
  -> done       result.txt exists and exit code is 0
  -> failed     Claude exits non-zero or output is invalid
```

`status` reads `stage` and `run_exit_code`; it never polls another process.
`collect` is valid only for `stage=done`.

## State directory

Ordinary review state contains:

```text
review-packet.md
packet_path
stage
run_exit_code
result.txt
initial-result.txt
rereview-N/
```

Panel and dual-review state use the same files under `seed/` and one directory
per role. A result directory is single-use for its initial run. Reuse the same
top-level directory only through the explicit `resume`/`followup` commands.

## Interruption and failure

Press Ctrl-C in the terminal running Claude. An interrupted call leaves its
partial output and non-zero or absent exit marker; start a new state directory
after inspecting it. Do not treat a partial result as a review verdict.

If Claude is unavailable or authentication fails, use the Luna reviewer
fallback. Do not silently create a second call while the first foreground call
is still running.

## Commands

```bash
claude-review.sh start packet.md state reviewer-1
claude-review.sh status state
claude-review.sh collect state
claude-review.sh resume state fix-delta.md

claude-panel.sh start context.md roles panel
claude-panel.sh status panel
claude-panel.sh advance panel
claude-panel.sh collect panel
claude-panel.sh followup panel/analyst delta.md
```
