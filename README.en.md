# Luna Primary Engineer

[日本語](README.md) | English

A software-development workflow for Codex Desktop and Codex CLI. GPT-5.6 Luna handles the work from investigation through implementation and testing. When useful, Claude Code Opus provides an optional, read-only review.

## Who it is for

- Developers who want Codex to handle investigation, implementation, and tests as one workflow
- Developers who want a second model to review important changes
- Users who need a Codex-only fallback when Claude is unavailable
- Projects that benefit from focused changes without unnecessary abstractions or dependencies

## Why this workflow exists

This workflow started from a practical setup: Codex is the main development environment, and Claude Team (Standard) is also available and worth putting to use. I wanted to keep the Codex Plus usage allowance focused on implementation, but sending a Luna implementation to Terra or Sol for review can consume a substantial part of the five-hour usage window even when the review is the only extra work.

The resulting split is simple: Codex Luna handles investigation, implementation, testing, and integration, while Claude Code Opus provides an independent, read-only review when needed. Codex remains the center of the workflow, with a second model added for another perspective.

## Setup

### Requirements

- Codex Desktop or Codex CLI
- Bash
- Git if the supporting Ponytail skill should be downloaded automatically
- Claude Code with valid authentication for Opus reviews

Claude Code is optional. Without it, the Codex fallback reviewer is still available.

### Install

```bash
git clone https://github.com/k3komatsu/luna-primary-engineer-with-opus-review.git
cd luna-primary-engineer-with-opus-review
bash scripts/install.sh
```

The installer places the skill and its related agents in your user directories. An existing copy of the same skill is replaced. By default, Ponytail is downloaded from its [GitHub repository](https://github.com/DietrichGebert/ponytail).

If you already have Ponytail locally, provide its path:

```bash
LUNA_PRIMARY_ENGINEER_PONYTAIL_SOURCE=/path/to/ponytail bash scripts/install.sh
```

If `CODEX_HOME` is set, related agents and Ponytail are placed under that directory.

After installation, restart Codex Desktop or start a new Codex CLI session. Then enter:

```text
$luna-primary-engineer
```

GPT-5.6 Luna with Reasoning: Max and Service tier: Fast is recommended.

### Update

```bash
git pull --ff-only origin master
bash scripts/install.sh
```

After updating, restart Codex Desktop or start a new Codex CLI session.

## How it works

Codex Luna handles normal work. For larger or harder-to-judge changes, Claude Code Opus can be added as an independent reviewer.

```text
Request
   ↓
Codex / Luna
  ├─ investigate / plan / implement / test
  └─ optional Claude Code / Opus review
```

Ponytail is a supporting skill that keeps changes focused and avoids unnecessary abstractions and dependencies.

## Opus review

When a second opinion is useful, Claude Code Opus reviews the change in read-only mode. It checks for missed cases and design concerns from a perspective separate from Luna's.

In normal use, ask the Codex session, “Have Opus review this change too.” If Claude Code is unavailable before the review starts, the Codex fallback reviewer can be used instead. Once an Opus review has started, the workflow does not switch reviewers automatically while waiting for its result.

Re-reviews continue the Opus session used for the initial review.

Reviews can take several minutes. Claude API and stream timeouts default to 10 minutes. If the Codex execution environment cannot reach the Anthropic API, the workflow preserves the same review session instead of treating the transport error as a review result, and retries it from a network-enabled environment. See the [Claude integration reference](references/claude-integration.md) for details.

## Troubleshooting

### The skill is not loaded

Restart Codex Desktop or start a new Codex CLI session, then run `$luna-primary-engineer`.

### Claude is unavailable

Check that Claude Code is installed and authenticated:

```bash
command -v claude
claude auth status
claude doctor
```

To use the Codex fallback reviewer without Claude:

```bash
export LUNA_PRIMARY_ENGINEER_CLAUDE=off
```

If `ANTHROPIC_API_KEY` is set, Claude Code may use an API-billed authentication path. Make sure that is the authentication method you intend to use.

### Review stops with `Request timed out`

`claude auth status` can succeed even when the Codex sandbox cannot reach the Anthropic API. If the review state is `stage=blocked` with `blocked_reason=network`, retry the same state from a network-enabled command environment:

```bash
bash scripts/claude-review.sh retry STATE_DIR
```

Switching to an interactive TTY or the Claude daemon does not remove an execution environment's network restriction.
