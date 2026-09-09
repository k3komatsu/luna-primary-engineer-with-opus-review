# Claude Code integration — foreground mode

Claude is optional. When available, Opus provides independent read-only review
and focused reasoning without becoming the implementation owner.

## Execution model

Every helper invokes Claude with `-p/--print` and waits for the process to
exit. The result is combined stdout/stderr captured in a state directory, and
the exit code is stored beside it. Ordinary review `start` creates a persistent
session with an explicit ID; `resume` continues that session. Dual-review and
panel calls use fresh non-persistent sessions.

The common read-only options are:

```text
--permission-mode dontAsk
--permission-prompts none
--tools Read,Glob,Grep
--disallowedTools mcp__*
--disable-slash-commands
--no-chrome
```

Ordinary review calls add `--session-id <uuid>` on the initial turn and
`--resume <uuid>` on re-review turns. Independent dual-review and panel calls
add `--no-session-persistence`.

Foreground calls default `API_TIMEOUT_MS`, the stream idle, byte-stream idle,
and first-byte timeouts to `600000` (10 minutes) when the corresponding Claude
variables are unset. This allows extended Opus thinking pauses and slow API
requests to finish instead of being cut off by a shorter local default; set
the variables explicitly to choose other positive millisecond values.

The helper reads the role system prompt and passes it through
`--append-system-prompt`. `--add-dir` grants read access to the packet/state
directory. Reviewers do not edit files, implement fixes, use MCP tools, or
spawn subagents.

Do not use `--bare`; it can bypass normal authentication sources. Keep the
prompt bounded enough for one foreground invocation to finish.

## Authentication

```bash
export LUNA_PRIMARY_ENGINEER_CLAUDE=auto
claude auth status
claude doctor
```

- `auto`: require `claude auth status` to succeed.
- `on`: skip the authentication precheck and attempt Claude.
- `off`: use the Luna reviewer fallback before launching Claude; it is not a
  fallback for a review that has already started.

`ANTHROPIC_API_KEY` may indicate API-billed authentication and is reported by
the helpers.

## Result handling

`start`, `resume`, `dual-start`, and `dual-advance` wait for Claude and write
their result files before returning. If the shell tool yields a session ID,
poll that same session until it exits. A shell/tool timeout or `Request timed
out` while waiting does not authorize a duplicate or Luna fallback. `status`
only reads the state directory; `collect` validates and prints stored output.

An ordinary review is accepted only when all headings are present:

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK
BLOCKERS:
NONBLOCKING:
TEST_GAPS:
PREVIOUS_FINDINGS:
```

Ordinary re-review uses the stored Claude session ID and continues the same
conversation with the new fix delta. Panel follow-up remains a fresh foreground
call and passes the prior result and new question as explicit context.
