# Claude background job lifecycle — v6.6

v6.6 separates **dispatch** from **completion**, and also separates a Claude background **job ID** from the underlying conversation **sessionId**.

Long Opus work is launched with `claude --bg`. The launch command returns quickly; Claude continues under its own background supervisor even when the launching shell is gone.

## Why

A long synchronous Claude call can outlive Codex's willingness to wait for one shell command. A Codex-side yield/timeout does not mean Claude failed and must never trigger duplicate reviewer/advisor launches.

For sticky re-review/advice, the completed Claude conversation is resumed by its full `sessionId`; a new background run may have a different short job ID while remaining the same conversation.

## State machine

Use `claude agents --json --all` through the helpers and honor these states.
The `state` field is the lifecycle gate; `status` is only the current activity
substate. In particular, `status=idle` does not mean the review is complete.

```text
working / idle
  -> nonterminal session; DO NOTHING destructive

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

`claude logs <id>` can show a terminal footer such as `Worked for ... · done`
before the background registry reaches `state=done`. That footer means the
latest Claude turn rendered a response; it does not by itself authorize
`collect` or `resume`. If the log also contains the complete review contract,
the turn is **turn-complete but lifecycle-open**. Do not launch a duplicate;
check for an attached client or stale daemon state and re-check the lifecycle.

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

v6.6 helpers persist `sessionId` for sticky sessions and verify that re-review/follow-up has not silently switched conversations. They reject an empty agent `id` when matching JSON so the interactive parent session cannot be mistaken for a newly launched background job.

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

Do not tight-loop status checks. Check at natural Primary work boundaries. If useful Primary work remains, continue it while Opus works. When a complete contract is visible in logs but `state=working`, do not wait forever or launch a duplicate; resolve the open/attached session deliberately and then re-check.

## Blocked jobs

When blocked:

1. inspect `claude logs <id>`;
2. do not launch a replacement or resume concurrently;
3. if logs show an input prompt or plan-mode pause, attach to the session and send one explicit read-only continuation instruction; if a genuine human decision is required, surface it;
4. continue only after the same job is unblocked or intentionally stopped.

## Background-session caveats

On macOS, background Claude sessions can have additional OS privacy restrictions for repositories under Desktop, Documents, or Downloads. Fix the OS/location issue rather than duplicating jobs.

Background sessions are durable but not immortal. Machine shutdown, daemon
failures, upgrades, expired auth, or bugs can stop/strand jobs. `failed/stopped`
is an inspection trigger, not an automatic retry trigger. For `unknown` or a
log failure such as `ECONNREFUSED`/`ENOENT` on `control.sock`, inspect
`claude auth status`, `claude doctor`, the exact daemon socket, and running
processes before a deliberate retry. A filesystem `EROFS` under
`~/.claude/jobs` is a host/sandbox write-permission issue, not a reviewer
approval request.
