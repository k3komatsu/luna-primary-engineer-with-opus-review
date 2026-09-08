# Independent review protocol — v6.5

The review unit is a **coherent completed change**, not an individual edit.

## Ordinary review: one fresh reviewer, sticky until acceptance

```text
Primary implements + validates
  -> fresh Opus Reviewer 1 --bg
  -> reviewer works independently of Codex shell
  -> state=done
  -> collect result
  -> Primary fixes findings
  -> resume SAME Reviewer 1 conversation --bg
  -> state=done
  -> collect re-review
  -> repeat same session until PASS / accepted risk
```

Commands:

```bash
claude-review.sh start REVIEW_PACKET STATE_DIR reviewer-1
claude-review.sh status STATE_DIR
claude-review.sh collect STATE_DIR
claude-review.sh resume STATE_DIR FIX_DELTA
```

### Sticky-reviewer invariant

`resume` means **resume the same Claude conversation**, not create a fork.

The helper distinguishes:

- background `job_id`: short ID used by `claude logs`, `claude stop`, and agent state;
- conversation `sessionId`: full Claude conversation ID used by `claude --resume`.

A re-review may receive a new short background job ID, but its conversation `sessionId` must remain identical. v6.5 stores and verifies this identity. If the sessionId changes unexpectedly, stop and inspect rather than silently accepting a fresh reviewer.

Never resume while the current reviewer run is `working` or `blocked`. `done` is the gate that makes same-session resume safe.

Why same-session re-review is preferred:

- the reviewer remembers its own prior findings and evidence;
- the Primary can send only the fix delta and verification evidence;
- repeated repository/context loading is reduced;
- closure of OPEN/CLOSED findings is more reliable;
- prompt-cache/context continuity is more likely to help.

A **fresh** reviewer is for independent second opinion, not routine finding closure.

## High-risk review: neutral seed + two blind reviewers

```text
review packet
    |
neutral seed --bg (NO verdict, NO defect analysis)
    |
 state=done
    |
    +-- fork --bg -> Reviewer 1
    |
    +-- fork --bg -> Reviewer 2
```

Commands:

```bash
claude-review.sh dual-start REVIEW_PACKET GROUP_DIR
claude-review.sh dual-status GROUP_DIR
claude-review.sh dual-advance GROUP_DIR
claude-review.sh dual-collect GROUP_DIR
```

Call `dual-advance` only after the seed is `done`.

Both reviewers inherit the same factual prefix but neither sees the other's findings. The seed response is only `SEED_READY`.

After fixes, resume **the same reviewer branch** whose findings need closure:

```bash
claude-review.sh resume GROUP_DIR/reviewer-1 FIX_DELTA
```

Do not fork a third reviewer merely to re-check Reviewer 1's own findings.

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

The implementer uses Ponytail FULL. Opus/Luna reviewers do not.

## When to add Reviewer 2

Use a second blind reviewer only when independence has unusually high expected value, including:

- security/authentication/authorization boundaries;
- persistent-data loss, migration, destructive behavior, or recovery logic;
- concurrency, memory ownership/lifetime, subtle ordering, distributed protocol correctness;
- public/wire protocol, ABI, compatibility changes with broad blast radius;
- delicate mathematical/numerical correctness;
- large cross-cutting refactors with hard-to-test invariants;
- Reviewer 1 reports a critical/major conceptual concern and a fresh second opinion is useful;
- Primary materially disagrees with Reviewer 1;
- user explicitly requests stronger review.

## Synthesis of two reviews

Luna synthesizes; reviewers do not debate each other directly.

Do not count votes:

- same concrete defect from both -> confidence rises;
- one concrete counterexample -> investigate even if the other says PASS;
- conflict -> inspect the exact repository fact/invariant separating conclusions;
- re-review only findings whose closure matters, using each reviewer's own sticky session.

## Background-state discipline

- `working`: wait/continue Primary work; no duplicate and no resume.
- `blocked`: inspect logs; no duplicate and no resume.
- `done`: collect result; same-session resume is allowed; fork only for intentional independence.
- `failed/stopped`: inspect cause; retry only deliberately.

A Codex shell timeout/yield is unrelated to these states.

## Reviewer output contract

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK

BLOCKERS:
- severity, file/location, concrete failure scenario, required correction

NONBLOCKING:
- only materially useful items

TEST_GAPS:
- missing verification that could expose a real defect

PREVIOUS_FINDINGS:
- OPEN/CLOSED on sticky re-review turns
```

Reviewers do not implement fixes.
