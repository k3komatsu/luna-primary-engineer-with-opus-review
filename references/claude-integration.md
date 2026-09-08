# Claude Code integration — foreground mode

Claude is optional. When available, Opus provides independent read-only review
and focused reasoning without becoming the implementation owner.

## Execution model

Every helper invokes Claude with `-p/--print` and waits for the process to
exit. The result is combined stdout/stderr captured in a state directory, and
the exit code is stored beside it. There is no asynchronous job or daemon state
to poll.

The common read-only options are:

```text
--permission-mode dontAsk
--permission-prompts none
--tools Read,Glob,Grep
--disallowedTools mcp__*
--disable-slash-commands
--no-chrome
--no-session-persistence
```

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
- `off`: use the Luna reviewer fallback.

`ANTHROPIC_API_KEY` may indicate API-billed authentication and is reported by
the helpers.

## Result handling

`start`, `resume`, `dual-start`, and `dual-advance` wait for Claude and write
their result files before returning. `status` only reads the state directory;
`collect` validates and prints stored output.

An ordinary review is accepted only when all headings are present:

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK
BLOCKERS:
NONBLOCKING:
TEST_GAPS:
PREVIOUS_FINDINGS:
```

Re-review and panel follow-up commands use fresh foreground calls. They pass
the prior result and new fix/question files as explicit context rather than
depending on conversation identity or runtime state.
