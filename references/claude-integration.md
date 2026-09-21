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

Each attempt stores its waiting runner PID and Claude PID. Never terminate a
launched Opus process. `status` uses the system process list without signals;
when both PIDs are gone, the state is still non-terminal, and no adopted result
exists, it records `process_gone_without_result` and requires explicit user
confirmation before another Opus call.
If sandbox policy denies `ps`, liveness is reported as `permission_denied` with
`PROCESS_LIST_PERMISSION_REQUIRED=1`, and no failure transition occurs. A
different `unknown` value means another process-list error. Treat either
output as an instruction to obtain execution-permission escalation and rerun
`status` with process-list access.

Review input can be the legacy packet file or a directory containing
`review-packet.md` and an optional `review-prompt.md` (`prompt.md` is accepted
as an alias). The wrapper copies these inputs into the fresh state directory
and passes paths to Claude. A pre-populated state directory is rejected to
protect existing review data; the prompt is context only and cannot override
the wrapper's safety or result-contract instructions. Bundle members must be
non-empty regular files and must not be symlinks. The prompt can choose review
focus, priorities, and questions without maintaining a separate output format.

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
wrapper also snapshots Git status before and after the call as a best-effort
detector for newly introduced changes; the exact `Edit(path)` permission is
the actual read-only boundary.

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
as the state `result.txt`. Ordinary review turns use the shared
[`claude/review-output-template.txt`](claude/review-output-template.txt) for
both Claude instructions and heading validation. A response in another format
remains available as the raw attempt artifact but is not adopted.
`status` exposes `REVIEW_RESULT_PRESENT=1`, `REVIEW_FORMAT_VALID=0`, and
`RAW_REVIEW_RESULT_PATH` when review text exists but its format is invalid.
Use `claude-job.sh logs STATE_DIR raw-result` to inspect its findings without
spending another Opus turn; body content remains free-form. For an invalid
initial review, obtain approval and use `start` with a new state; `retry` is
reserved for an explicitly network-blocked initial review.

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
precedence over generic timeout text. The latter is stored as
`failure_reason=claude_session_not_found`; both are terminal until the user
chooses a next step. `resume` and `resume-background` refuse a known-lost
session with exit code 10, so the approved recovery is a new `start`.

In a network-restricted Codex sandbox, real Opus calls may require escalating
the command to network-enabled execution. Obtain that authorization before
launch when required. Successful `claude auth status` or `claude doctor`
output does not prove that the sandbox can reach the Anthropic API.

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
