# Claude background job lifecycle — v6.5

v6.5 separates **dispatch** from **completion**, and also separates a Claude background **job ID** from the underlying conversation **sessionId**.

Long Opus work is launched with `claude --bg`. The launch command returns quickly; Claude continues under its own background supervisor even when the launching shell is gone.

## Why

A long synchronous Claude call can outlive Codex's willingness to wait for one shell command. A Codex-side yield/timeout does not mean Claude failed and must never trigger duplicate reviewer/advisor launches.

For sticky re-review/advice, the completed Claude conversation is resumed by its full `sessionId`; a new background run may have a different short job ID while remaining the same conversation.

## State machine

Use `claude agents --json --all` through the helpers and honor these states:

```text
working / idle
  -> healthy/in progress; DO NOTHING destructive

blocked
  -> inspect logs/status; do not auto-replace or resume

done
  -> collect logs; same conversation may now be resumed
     OR intentionally forked when independence is desired

failed / stopped
  -> inspect cause first; retry only after explicit reasoning

unknown
  -> inspect listing/logs; never infer failure solely from absence
```

Hard rule:

> **Never resume, fork, retry, or duplicate a Claude job while its state is `working` or `blocked`.**

Two processes must not write the same Claude conversation concurrently.

## Resume vs fork

Use **resume without `--fork-session`** when continuity is the goal:

- Reviewer 1 checking fixes to its own findings;
- Reviewer 2 checking fixes to its own findings;
- a promoted Opus expert answering another question in the same decision domain.

Use **`--fork-session`** only when independence/diversity is the goal:

- panel branches from a neutral seed;
- blind Reviewer 1 and Reviewer 2 from a neutral review seed;
- an intentionally independent new opinion.

## IDs

Claude agent state exposes both:

- `id`: short background ID for `claude logs`, `claude stop`, `claude attach`;
- `sessionId`: full conversation ID for `claude --resume`.

v6.5 helpers persist `sessionId` for sticky sessions and verify that re-review/follow-up has not silently switched conversations.

## Helpers

Generic one-job management:

```bash
claude-job.sh status STATE_DIR
claude-job.sh logs STATE_DIR
claude-job.sh collect STATE_DIR
claude-job.sh stop STATE_DIR
```

Review:

```bash
claude-review.sh start packet.md state reviewer-1
claude-review.sh status state
claude-review.sh collect state
claude-review.sh resume state fix-delta.md
```

Panel:

```bash
claude-panel.sh start context.md roles panel
claude-panel.sh status panel
claude-panel.sh advance panel   # only after neutral seed is done
claude-panel.sh collect panel
claude-panel.sh followup panel/analyst delta.md   # same analyst conversation
```

## Polling discipline

Do not tight-loop status checks. Check at natural Primary work boundaries. If useful Primary work remains, continue it while Opus works.

## Blocked jobs

When blocked:

1. inspect `claude logs <id>`;
2. do not launch a replacement or resume concurrently;
3. if a human action is genuinely required, surface it or attach to the session;
4. continue only after the same job is unblocked or intentionally stopped.

## Background-session caveats

On macOS, background Claude sessions can have additional OS privacy restrictions for repositories under Desktop, Documents, or Downloads. Fix the OS/location issue rather than duplicating jobs.

Background sessions are durable but not immortal. Machine shutdown, daemon failures, upgrades, or bugs can stop/strand jobs. `failed/stopped` is an inspection trigger, not an automatic retry trigger.
