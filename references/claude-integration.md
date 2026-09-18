# Claude Code integration

Claude is optional. When enabled, Opus is an independent read-only reviewer;
Luna remains the implementation owner.

## Execution model

Ordinary `start` and `resume` invoke `claude -p` synchronously and wait for
the process to exit. If the caller must stop waiting, use the explicit
wrapper-owned `start-background` or `resume-background` form and inspect the
same state with `status`. These forms do not cut a foreground PTY and do not
use the Claude daemon or its session registry.

The initial ordinary review stores a persistent session UUID. `resume` uses
that UUID with `--resume`; dual reviewers and panel calls use fresh,
non-persistent Claude sessions. Every call consumes Claude usage. No timeout,
empty stdout, missing intermediate output, or transport error automatically
starts another call.

## Read-only boundary and result handoff

The common options are:

```text
--permission-mode dontAsk
--permission-prompts none
--tools Read,Glob,Grep,Write     # Write only in path-scoped mode
--allowedTools "Edit(/$result_file)"  # $result_file is already absolute
--disallowedTools Bash mcp__*
--disable-slash-commands
--no-chrome
```

The reviewer system prompt gives one explicit exception: it may write the
exact absolute designated result file and must never edit anything else. The
wrapper also snapshots Git status before and after the call, so an escaped
implementation edit fails the review.

Claude Code uses the `Edit(path)` permission grammar to scope all file-editing
tools, including the `Write` tool. For an already absolute shell variable, the
extra slash is intentional: `Edit(/$result_file)` becomes
`Edit(//home/.../reviewer-result.md)`. A single leading slash is project-relative
in this grammar. The presence of `--allowedTools` in help is not enough to prove
that every rule spelling is supported; the helper does not pass unsupported
deny names such as `MultiEdit`.

If the installed Claude CLI does not expose a usable path-scoped permission
interface, the helper does not enable generic Write/Edit/Bash. It asks Claude
for a `LUNA_RESULT_BEGIN` / `LUNA_RESULT_END` framed handoff, writes that
validated frame into the designated result file, and still treats the file as
the canonical result. Set
`LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF=stdout` to force that mode.

The wrapper keeps these files for each attempt:

```text
reviewer-result.md  # designated file Claude writes, or wrapper materializes
stdout.txt          # diagnostic only
stderr.txt          # diagnostic only
exit_code
repository-before.txt
repository-after.txt
```

Only a non-empty designated file that passes the artifact contract is adopted
as the state `result.txt`. For an ordinary review the contract is:

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK
BLOCKERS:
NONBLOCKING:
TEST_GAPS:
PREVIOUS_FINDINGS:
```

An absent, empty, or incomplete result is a technical `failed` state. The
error includes the state, exit code, and stdout/stderr diagnostic paths. Raw
stdout is never promoted to `result.txt`, and the wrapper never retries only
because stdout is empty.

## Authentication and network

```bash
export LUNA_PRIMARY_ENGINEER_CLAUDE=auto
claude auth status
claude doctor
```

- `auto`: require `claude auth status` to succeed.
- `on`: skip the authentication precheck and attempt Claude.
- `off`: use the preflight-only Luna fallback before Claude is launched.

Authentication success does not prove that the current Codex command
environment can reach the Anthropic API. A recognizable transport failure is
stored as `stage=blocked` with `blocked_reason=network`; the session and
diagnostics remain available for an explicitly approved `retry` on the same
state. CLI permission/argument errors and `No conversation found` take
precedence over generic timeout text and are terminal until the user chooses
a next step.

`ANTHROPIC_API_KEY` may indicate API-billed authentication and is reported by
the helpers. The API, stream-idle, byte-idle, and first-byte timeout defaults
are 600000 milliseconds when unset, but an upstream network timeout can still
arrive earlier.

## Workspace

The helper resolves the Git worktree root from the current working directory
and stores every packet, state, result, diagnostic, session metadata, and
background log under:

```text
<worktree-root>/tmp/luna-primary-engineer/reviews/<unique-id>/
```

The worktree `tmp` path and its review components must not be symlinks or
resolve to a system temporary directory. Existing contents are never
recursively removed or replaced. State/group arguments outside this workspace
are rejected.
