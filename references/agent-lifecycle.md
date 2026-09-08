# Agent and external-session lifecycle v6.5

## Primary

The root Luna Max/Fast session is the long-lived Primary Engineer and default owner of investigation, implementation, tests, fixes, integration, expert routing, and user communication.

## Claude background-state rule

Every long Claude reviewer/advisor job is supervised by Claude Code, not by one Codex shell call.

```text
working / idle -> leave alone
blocked        -> inspect, do not duplicate/resume
done           -> collect; same session may resume, or fork if independence is intended
failed/stopped -> inspect cause before retry
```

A Codex shell timeout/yield is not a Claude lifecycle event.

## Claude Opus review sessions

Ordinary review:

```text
FRESH REVIEWER --bg -> WORKING -> DONE -> FINDINGS
FINDINGS -> PRIMARY_FIX -> RESUME SAME REVIEWER SESSION --bg
RE-REVIEW -> DONE -> FIX AGAIN? -> RESUME SAME SESSION
PASS/ACCEPTED -> ARCHIVE STATE
```

The Reviewer conversation is sticky until acceptance. Background job IDs may change between runs; conversation `sessionId` must not.

High-risk dual review:

```text
NEUTRAL SEED --bg -> DONE
DONE -> FORK REVIEWER 1 --bg + FORK REVIEWER 2 --bg
REVIEWERS -> DONE -> INDEPENDENT FINDINGS -> LUNA SYNTHESIS
R1 FINDING -> PRIMARY_FIX -> RESUME SAME R1 SESSION
R2 FINDING -> PRIMARY_FIX -> RESUME SAME R2 SESSION
```

Do not create a new reviewer merely because an existing reviewer is slow. The neutral seed is never itself a reviewer and never contains a verdict.

## Claude Opus panel sessions

```text
NEUTRAL SEED --bg -> DONE
DONE -> FORK A/B/C/D --bg -> DONE -> INDEPENDENT ANALYSES -> LUNA SYNTHESIS
```

Each panel member is an independent fork from the same neutral seed and cannot see peers. If one completed fork becomes a useful domain specialist, **resume that same expert conversation** for same-scope follow-ups.

Never concurrently resume/fork a live Claude conversation.

## luna_reviewer

Fallback reviewer when Claude is unavailable or intentionally disabled. Sticky through the current change's fix/re-review loop, then close.

## luna_worker

```text
SPAWNED -> IMPLEMENTING -> REPORTED -> INTEGRATION/REVIEW
INTEGRATION/REVIEW -> FIX_REQUESTED -> IMPLEMENTING
INTEGRATION/REVIEW -> ACCEPTED -> CLOSED
```

Parallel-only. `REPORTED` is not terminal. Keep the same Worker through review of its owned contribution when practical.

## Sol / Astra

Domain-scoped sticky advisors. Reuse for semantically continuous follow-ups. Sol gets only the narrow unresolved point after cheaper Luna/Opus evidence gathering where practical. Astra is exceptional final escalation.
