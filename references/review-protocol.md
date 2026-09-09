# Independent review protocol

The review unit is a coherent completed change, not an individual edit.

## Ordinary review

```text
Primary implements + validates
  -> synchronous Opus review
  -> same-state retry if network-blocked
  -> result contract
  -> Primary fixes findings
  -> same-session synchronous re-review with fix delta
  -> repeat until PASS / accepted risk
```

Commands:

```bash
claude-review.sh start REVIEW_PACKET STATE_DIR reviewer-1
claude-review.sh status STATE_DIR
claude-review.sh collect STATE_DIR
claude-review.sh retry STATE_DIR
claude-review.sh resume STATE_DIR FIX_DELTA
```

`retry` is only for a network/API-blocked initial review. It keeps the same
state and Claude session, and should be run through network-enabled command
execution. `resume` continues the Claude session created by `start` in a new
foreground turn. The fix delta is supplied as the new user turn, while the
original packet and previous review remain in the conversation context.

## High-risk dual review

```text
review packet
    |
neutral foreground seed (SEED_READY only)
    |
foreground Reviewer 1 + foreground Reviewer 2
```

```bash
claude-review.sh dual-start REVIEW_PACKET GROUP_DIR
claude-review.sh dual-status GROUP_DIR
claude-review.sh dual-advance GROUP_DIR
claude-review.sh dual-collect GROUP_DIR
```

The two reviewers run sequentially and independently. Neither reads the other
reviewer's result before completing its own analysis.

## Review packet

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

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK

BLOCKERS:
- severity, location, failure scenario, required correction

NONBLOCKING:
- only materially useful items

TEST_GAPS:
- missing verification that could expose a real defect

PREVIOUS_FINDINGS:
- OPEN/CLOSED on re-review turns
```

Reviewers do not implement fixes. Luna synthesizes evidence rather than
counting votes.
