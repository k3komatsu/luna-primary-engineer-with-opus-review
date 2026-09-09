# Agent and Claude lifecycle

## Primary

The root Luna Max/Fast session owns investigation, implementation, tests,
review routing, integration, and user communication.

## Claude review

```text
FOREGROUND REVIEW -> DONE -> FINDINGS
FINDINGS -> PRIMARY_FIX -> STICKY FOREGROUND RE-REVIEW
RE-REVIEW -> DONE -> FIX AGAIN? -> STICKY RE-REVIEW
PASS/ACCEPTED -> ARCHIVE RESULT FILES
```

The process exit code and stored result files are the completion signals. An
ordinary review also stores a Claude session ID so `resume` can continue the
same conversation; this is explicit state, not a background job registry.

## High-risk dual review

```text
FOREGROUND NEUTRAL SEED -> DONE
DONE -> FOREGROUND REVIEWER 1 -> DONE
     -> FOREGROUND REVIEWER 2 -> DONE
REVIEWERS -> INDEPENDENT FINDINGS -> LUNA SYNTHESIS
```

Reviewer calls are sequential and independent. The neutral seed contains facts,
not a verdict.

## Claude panel

```text
FOREGROUND NEUTRAL SEED -> DONE
DONE -> FOREGROUND ROLE A/B/C/D -> DONE
ROLE RESULTS -> LUNA SYNTHESIS
```

Each role receives the shared context and its own role file. A follow-up reads
the previous branch result and a new delta in a fresh foreground call.

## luna_reviewer

Fallback reviewer when Claude is unavailable or intentionally disabled. It
reviews the same change and fix evidence without editing files.

## luna_worker

```text
SPAWNED -> IMPLEMENTING -> REPORTED -> INTEGRATION/REVIEW
INTEGRATION/REVIEW -> FIX_REQUESTED -> IMPLEMENTING
INTEGRATION/REVIEW -> ACCEPTED -> CLOSED
```

Parallel-only. A report is not terminal until the contribution is integrated
and accepted.

## Sol / Astra

Domain-scoped advisors for narrow unresolved questions. Sol is preferred for a
material remaining judgment; Astra is exceptional final escalation.
