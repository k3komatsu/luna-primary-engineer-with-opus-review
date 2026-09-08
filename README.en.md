# Luna Primary Engineer

[日本語](README.md) | English

A software-development workflow for Codex Desktop and Codex CLI. It uses GPT-5.6 Luna as the primary engineer and Claude Code Opus as an optional, read-only reviewer.

## Who it is for

- Developers who want Codex to handle investigation, implementation, and tests as one workflow
- Teams that want an independent model to review larger changes
- Users who need a Codex-only fallback when Claude is unavailable
- Projects that benefit from focused changes without unnecessary abstractions or dependencies

## Why this workflow exists

This workflow started from a practical setup: Codex is the main development environment, and Claude Team (Standard) is also available and worth putting to use. I wanted to keep the Codex Plus usage allowance focused on implementation, but sending a Luna implementation to Terra or Sol for review can consume a substantial part of the five-hour usage window even when the review is the only extra work.

The resulting split is simple: Codex Luna handles investigation, implementation, testing, and integration, while Claude Code Opus provides an independent, read-only review when needed. Codex remains the center of the workflow, with a second model added for another perspective.

## Setup

### Requirements

- Codex Desktop or Codex CLI
- Bash
- Git if Ponytail must be downloaded
- Claude Code with valid authentication for Opus reviews

Claude Code is optional. Without it, the Codex `luna_reviewer` agent can provide the fallback review.

### Install

```bash
git clone https://github.com/k3komatsu/luna-primary-engineer-with-opus-review.git
cd luna-primary-engineer-with-opus-review
bash scripts/install.sh
```

If you already have a checkout, run `bash scripts/install.sh` from that directory.

The installer updates these locations:

| Target | Default location | Contents |
|---|---|---|
| Skill | `~/.agents/skills/luna-primary-engineer` | Instructions loaded by Codex and helper scripts |
| Custom agents | `$CODEX_HOME/agents` (usually `~/.codex/agents`) | `luna_worker`, `luna_reviewer`, `sol_advisor`, and `astra_expert` |
| Ponytail | `$CODEX_HOME/luna-primary-engineer/deps/ponytail` | Supporting skill used by implementation workers |

An existing copy of the same skill is replaced by the checkout contents. If `CODEX_HOME` is set, it controls the custom-agent and Ponytail locations.

To use a local Ponytail checkout, provide a directory containing `skills/ponytail/SKILL.md`:

```bash
LUNA_PRIMARY_ENGINEER_PONYTAIL_SOURCE=/path/to/ponytail bash scripts/install.sh
```

After installation, restart Codex Desktop, start a new session, and enter:

```text
$luna-primary-engineer
```

The recommended settings are GPT-5.6 Luna, Max reasoning, and Fast service tier.

### Update and verify

```bash
git pull --ff-only origin master
bash scripts/install.sh
bash scripts/doctor.sh
bash scripts/self-test.sh
```

## How it works

The main Codex session owns the work from requirements through implementation and tests. An Opus review is added when an independent check is useful.

```text
Requirements
     ↓
Codex / Luna Primary Engineer
  ├─ investigate / plan / implement / test
  └─ optional read-only Claude Opus review
             ↓
          fix findings → fresh review
```

Ponytail is the implementation discipline used to avoid unnecessary abstractions and dependencies while preserving required behavior and safety.

## Roles

| Role | Use it for |
|---|---|
| Primary Engineer | Normal investigation, implementation, testing, and integration in the main Codex session |
| Claude Reviewer | Independent read-only review by Opus |
| Claude Panel | Multi-angle reasoning about a difficult design decision |
| `luna_worker` | An isolated implementation that benefits from parallel execution |
| `luna_reviewer` | Read-only review fallback when Claude Code is unavailable |
| `sol_advisor` | One narrow technical judgment unresolved by Luna and Opus |
| `astra_expert` | An exceptionally difficult, high-impact final judgment |

The Primary Engineer normally completes a task alone. Workers and specialist agents are for cases where additional independence or parallelism has clear value.

## Opus reviews

### Ordinary review

Create a factual `review-packet.md` containing the change goal, acceptance criteria, constraints, changed files, checks already run, and known concerns.

```markdown
# Review packet

## Change goal / acceptance criteria
What changed and what must be true when it is complete

## Relevant invariants / architecture constraints
Contracts, constraints, and state transitions that must not break

## Changed files and compact diff/hunks
Changed files and important parts of the diff

## Focused surrounding code if needed
Surrounding code needed to verify the change

## Tests/checks run and results
Checks already run and their results

## Known compromises / open concerns
Known tradeoffs and concerns
```

Start a review. The state directory stores the run state and result; use a new one for each initial review.

```bash
bash scripts/claude-review.sh start review-packet.md /tmp/luna-review-1 reviewer-1
```

Inspect or collect a finished result with:

```bash
bash scripts/claude-review.sh status /tmp/luna-review-1
bash scripts/claude-review.sh collect /tmp/luna-review-1
```

A result is valid only when it contains all five headings:

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK
BLOCKERS:
NONBLOCKING:
TEST_GAPS:
PREVIOUS_FINDINGS:
```

If the verdict is `CHANGES_REQUIRED`, summarize the fixes in `fix-delta.md` and run a fresh review:

```bash
bash scripts/claude-review.sh resume /tmp/luna-review-1 fix-delta.md
```

Despite its name, `resume` does not resume a saved Claude conversation. It passes the original packet, previous result, and fix delta to a new Claude process. With `PASS_WITH_RISK`, inspect and explicitly accept the remaining risk.

### High-risk dual review

Use this when a second independent opinion is especially valuable, for example for security, authentication, destructive data operations, concurrency, public protocols, ABI changes, or broad compatibility changes. It takes more time and Opus usage than an ordinary review.

```bash
bash scripts/claude-review.sh dual-start review-packet.md /tmp/luna-dual-review
bash scripts/claude-review.sh dual-status /tmp/luna-dual-review
bash scripts/claude-review.sh dual-advance /tmp/luna-dual-review
bash scripts/claude-review.sh dual-collect /tmp/luna-dual-review
```

The two reviewers run sequentially, do not see each other's results, and evaluate the same packet independently.

### Opus advisory panel

Use a panel for difficult design reasoning rather than a normal review verdict. Prepare 2–6 role files with `.md` or `.txt` extensions:

```text
roles/
  analyst.md
  skeptic.md
  lifecycle.md
```

```bash
bash scripts/claude-panel.sh start context.md roles /tmp/luna-panel
bash scripts/claude-panel.sh status /tmp/luna-panel
bash scripts/claude-panel.sh advance /tmp/luna-panel
bash scripts/claude-panel.sh collect /tmp/luna-panel
```

Each role runs as an independent foreground call. To ask one role a follow-up question:

```bash
bash scripts/claude-panel.sh followup /tmp/luna-panel/analyst delta.md
```

The panel provides evidence for the Primary Engineer; it does not decide by majority vote.

## Execution and safety

Claude review and panel calls run in the foreground and wait until the process exits. Several minutes is normal. Do not launch a duplicate call; press `Ctrl-C` in the invoking terminal to interrupt one.

The calls use these restrictions:

```text
--model opus
--effort xhigh (max for panels)
--permission-mode dontAsk
--permission-prompts none
--tools "Read,Glob,Grep"
--disallowedTools "mcp__*"
--disable-slash-commands
--no-chrome
--no-session-persistence
```

Claude can read the repository and return a result, but it cannot edit files, call MCP tools, or spawn subagents. Completion is determined by the process exit code and the result contract.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `LUNA_PRIMARY_ENGINEER_CLAUDE` | `auto` | `auto` checks authentication first; `on` skips that check; `off` selects the Luna reviewer fallback |
| `LUNA_PRIMARY_ENGINEER_CLAUDE_MODEL` | `opus` | Claude model for ordinary reviews |
| `LUNA_PRIMARY_ENGINEER_CLAUDE_REVIEW_EFFORT` | `xhigh` | Reasoning effort for ordinary reviews |
| `LUNA_PRIMARY_ENGINEER_CLAUDE_PANEL_EFFORT` | `max` | Reasoning effort for panels |
| `CODEX_HOME` | `~/.codex` | Base directory for custom agents and dependencies |
| `LUNA_PRIMARY_ENGINEER_PONYTAIL_SOURCE` | unset | Local Ponytail checkout used during installation |

If `ANTHROPIC_API_KEY` is set, Claude Code may use an API-billed authentication path.

## Troubleshooting

### The skill is not loaded

Restart Codex Desktop completely, start a new session, and enter `$luna-primary-engineer`.

### Claude is unavailable

```bash
command -v claude
claude auth status
claude doctor
```

To use the fallback reviewer intentionally:

```bash
export LUNA_PRIMARY_ENGINEER_CLAUDE=off
```

### The review is taking a while

Foreground calls wait for completion, so several minutes is expected. Do not retry while the process is still running.

### A state directory cannot be reused

Use `status`, `collect`, or `resume` for an existing run. Choose a new directory for a new initial review.

## Repository layout

```text
README.md                         Japanese user guide
README.en.md                      English user guide
SKILL.md                          Codex skill instructions
VERSION                           Package version
agents/openai.yaml                Skill display metadata
codex-agents/                     Custom agent definitions
scripts/install.sh                Installer
scripts/doctor.sh                 Installation diagnostics
scripts/self-test.sh              Focused self-test
scripts/claude-*.sh               Claude review, panel, and state helpers
references/                       Detailed design and operation docs
```

## Checks for contributors

```bash
bash -n scripts/*.sh
bash scripts/self-test.sh
git diff --check
```

## Version

The current package version is recorded in `VERSION`.
