# Luna Primary Engineer v6.6 for Codex Desktop / CLI

Luna Max/Fast remains the persistent Primary Engineer. Ponytail FULL keeps
implementation economical, while Claude Opus is an optional read-only reviewer
and reasoning partner.

Claude is deliberately executed in the foreground with `claude -p`. The helper
waits for each call, captures its output and exit code, and stores results in a
state directory. There is no daemon, job registry, terminal-log collection, or
asynchronous session lifecycle.

## Architecture

```text
User -> Luna Primary + Ponytail
        investigate / plan / implement / test
                         |
                   coherent change
                         |
             optional Claude review -p
                         |
                 result.txt + contract
                         |
                 Luna fixes findings
                         |
             fresh foreground re-review
```

For difficult reasoning, the panel seed and role experts also run as ordinary
foreground calls. Luna synthesizes their independent result files.

## Roles

| Role | Model | Effort | Purpose |
|---|---|---:|---|
| Primary Engineer | Luna | Max / Fast | end-to-end engineering |
| Claude Reviewer | Opus | xhigh | independent read-only review |
| Claude Panel | Opus | max | independent role-diverse reasoning |
| `luna_reviewer` | Luna | Max | Claude-unavailable review fallback |
| `luna_worker` | Luna | Max | parallel-only implementation |
| `sol_advisor` | Sol | Max | narrow unresolved judgment |
| `astra_expert` | Astra | Max | exceptional final escalation |

All Luna roles use max reasoning. `luna_explorer` is intentionally absent.

## Foreground Claude invocation

The helpers use this read-only boundary:

```text
claude -p
--permission-mode dontAsk
--permission-prompts none
--tools Read,Glob,Grep
--disallowedTools mcp__*
--disable-slash-commands
--no-chrome
--no-session-persistence
```

The command runs in the invoking terminal. Press Ctrl-C to interrupt it. A
non-zero exit code is recorded and no result is treated as complete.

## Ordinary review

```bash
bash scripts/claude-review.sh start REVIEW_PACKET STATE_DIR reviewer-1
bash scripts/claude-review.sh status STATE_DIR
bash scripts/claude-review.sh collect STATE_DIR
bash scripts/claude-review.sh resume STATE_DIR FIX_DELTA
```

`start` waits until the review finishes. `status` reads the stored stage and
does not contact a Claude job registry. `collect` validates this contract:

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK
BLOCKERS:
NONBLOCKING:
TEST_GAPS:
PREVIOUS_FINDINGS:
```

`resume` is retained as the CLI name for compatibility. It starts a fresh
foreground call that reads the original packet, the previous result, and the
fix delta; it does not reuse a remote conversation.

## High-risk dual review

Use only when a second independent opinion is worth the extra Claude usage.

```bash
bash scripts/claude-review.sh dual-start REVIEW_PACKET GROUP_DIR
bash scripts/claude-review.sh dual-status GROUP_DIR
bash scripts/claude-review.sh dual-advance GROUP_DIR
bash scripts/claude-review.sh dual-collect GROUP_DIR
```

`dual-start` waits for the neutral `SEED_READY` result. `dual-advance` then
runs Reviewer 1 and Reviewer 2 sequentially as fresh, independent foreground
calls. Neither reviewer receives the other reviewer's result.

## Advisory panel

Prepare a factual context file and 2..6 role files:

```bash
bash scripts/claude-panel.sh start CONTEXT_FILE ROLES_DIR OUTPUT_DIR
bash scripts/claude-panel.sh status OUTPUT_DIR
bash scripts/claude-panel.sh advance OUTPUT_DIR
bash scripts/claude-panel.sh collect OUTPUT_DIR
bash scripts/claude-panel.sh followup BRANCH_DIR DELTA_FILE
```

The seed runs during `start`. `advance` runs all role calls sequentially and
stores one result per role. `followup` reads the branch's previous result and
the new delta in a fresh foreground call.

## Generic result helper

```bash
bash scripts/claude-job.sh status STATE_DIR
bash scripts/claude-job.sh logs STATE_DIR
bash scripts/claude-job.sh collect STATE_DIR
```

Foreground runs cannot be stopped by this helper; press Ctrl-C in the terminal.

## Environment

```bash
export LUNA_PRIMARY_ENGINEER_CLAUDE=auto
export LUNA_PRIMARY_ENGINEER_CLAUDE_MODEL=opus
export LUNA_PRIMARY_ENGINEER_CLAUDE_REVIEW_EFFORT=xhigh
export LUNA_PRIMARY_ENGINEER_CLAUDE_PANEL_EFFORT=max
```

- `auto`: require `claude auth status` to succeed.
- `on`: skip the authentication precheck and attempt Claude.
- `off`: use the Luna review fallback.

Use `claude auth status` and `claude doctor` to diagnose authentication. If
`ANTHROPIC_API_KEY` is set, Claude usage may be API-billed.

## Install

The installer copies the skill to `~/.agents/skills/luna-primary-engineer`,
custom agents to `$CODEX_HOME/agents`, and a private Ponytail checkout to
`$CODEX_HOME/luna-primary-engineer/deps/ponytail`.

```bash
unzip luna-primary-engineer-v6.6.zip
cd luna-primary-engineer
bash scripts/install.sh
```

For an offline/local Ponytail checkout:

```bash
LUNA_PRIMARY_ENGINEER_PONYTAIL_SOURCE=/path/to/ponytail bash scripts/install.sh
```

Then fully restart Codex Desktop and start a new session with GPT-5.6 Luna,
Max reasoning, and Fast service tier. Invoke:

```text
$luna-primary-engineer
```

## Verify

```bash
bash scripts/doctor.sh
bash scripts/self-test.sh
```

The doctor checks the installed skill, custom agents, foreground Claude CLI
capabilities, authentication, and the read-only result contract helpers.

## Design rules

- Primary Luna owns the task and normally implements directly.
- Claude reviewers never edit the repository.
- Foreground calls are the only Claude execution mode used by this package.
- Reviewers must return the complete contract before a result is accepted.
- Dual review and panels use independent sequential calls, not shared live
  conversations.
- Luna synthesizes evidence rather than counting votes.
- Sol and Astra receive only narrow unresolved questions.
