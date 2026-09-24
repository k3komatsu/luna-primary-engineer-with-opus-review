# Independent review protocol

The review unit is a coherent completed change, not an individual edit.

## Ordinary review

```text
Primary implements + validates
  -> synchronous Opus 5.5 review to a designated result file
  -> validated result contract (stdout is diagnostic only)
  -> same-state retry if network-blocked and explicitly approved
  -> Primary fixes findings
  -> importance/scope/regression-risk decision
  -> same-session synchronous re-review with fix delta if any axis is high
  -> focused checks and documented skip if all axes are low
  -> repeat until PASS / accepted risk
```

Commands:

```bash
claude-review.sh start REVIEW_INPUT STATE_DIR reviewer-1
claude-review.sh start-background REVIEW_INPUT STATE_DIR reviewer-1
claude-review.sh status STATE_DIR
claude-review.sh collect STATE_DIR
claude-review.sh retry STATE_DIR
claude-review.sh resume STATE_DIR FIX_DELTA
claude-review.sh resume-background STATE_DIR FIX_DELTA
```

`retry` is only for a network/API-blocked initial review after explicit user
approval. It keeps the same state and Claude session, and should be run through
network-enabled command execution. `resume` continues the Claude session
created by `start` in a new foreground turn. The fix delta is supplied as the
new user turn, while the original packet and previous review remain in the
conversation context. CLI permission errors and `No conversation found` are
terminal technical failures, not retryable network states; the latter is
recorded as `failure_reason=claude_session_not_found`. The wrapper
validates the designated result file and refuses both resume forms with exit
code 10 for a known-lost session; it never retries because stdout is empty.

An ordinary fix re-review does not need additional user approval when the
finding is important, the fix is broad, or regression risk is high. Skip it
only when all three axes are low, then run focused checks and report the reason.
Technical recovery, including network, CLI, result-contract, or process-loss
reruns, still requires explicit approval.

## High-risk dual review

```text
review packet
    |
neutral foreground seed (SEED_READY only)
    |
foreground Reviewer 1 + foreground Reviewer 2
```

```bash
claude-review.sh dual-start REVIEW_INPUT GROUP_DIR
claude-review.sh dual-status GROUP_DIR
claude-review.sh dual-advance GROUP_DIR
claude-review.sh dual-collect GROUP_DIR
```

The two reviewers run sequentially and independently. Neither reads the other
reviewer's result before completing its own analysis. If reviewer one has a
technical failure, including an invalid output format, the wrapper stops before
launching reviewer two and requires inspection/approval before another dual
run.

## Review input

`REVIEW_INPUT` can remain a single packet file for backward compatibility. To
keep a reviewer-specific prompt with the reproducible review state, pass a
bundle directory instead:

```text
review-input/
  review-packet.md          # required factual context
  review-prompt.md          # optional reviewer focus/instructions
```

`prompt.md` is accepted as a compatibility alias, but it must not appear
together with `review-prompt.md`. The wrapper copies both files into the fresh
state directory and stores `prompt_path`; a pre-populated state directory is
still rejected so old review data cannot be overwritten. Bundle members must
be non-empty regular files and must not be symlinks. The prompt is context
only: wrapper safety rules and the result contract take precedence. It may
freely specify the review focus, priorities, and questions. The wrapper adds
the canonical output template to every ordinary review turn, including retry,
re-review, and both dual reviewers; the prompt need not duplicate it.

Provide:

```text
Change goal / acceptance criteria:
Relevant invariants / architecture constraints:
Changed files and compact diff/hunks:
Focused surrounding code if needed:
Tests/checks run and results:
Known compromises / open concerns:
```

## Reviewer output contract

The canonical heading and verdict template is
[`claude/review-output-template.txt`](claude/review-output-template.txt). The
wrapper sends it to Claude and derives its heading checks from that same file.
Describe blockers with severity, location, failure scenario, and needed
correction; keep nonblocking items materially useful; identify meaningful test
gaps; and mark previous findings OPEN/CLOSED on re-review. The content beneath
each heading can use any useful structure. A review returned in another
format fails validation. `status` marks the returned text as present and the
format as invalid, and `claude-job.sh logs STATE_DIR raw-result` exposes the
original artifact for inspection. Report useful findings from that text while
making clear that no verdict was adopted; do not launch another Opus call
without approval.

Reviewers do not implement fixes. Luna synthesizes evidence rather than
counting votes.
