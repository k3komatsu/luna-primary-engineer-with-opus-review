# Opus Advisory Panel — v6.5

Use a panel only when the difficult part is **reasoning**, not routine implementation.

The Primary Luna remains the router and evidence synthesizer. Opus branches are independent read-only specialists.

## Architecture

```text
Luna creates common factual packet + low-correlation roles
                    |
                    v
          neutral Opus seed --bg
                    |
                state=done
                    |
       +------------+------------+
       |            |            |
   fork --bg    fork --bg    fork --bg ...
   Analyst      Skeptic       Specialist
       \            |            /
        \-----------+-----------/
                    v
             Luna synthesis
```

The neutral seed exists for shared context and prompt-cache lineage. It must not diagnose or recommend.

## Role generation

Choose roles that attack different failure modes. Do not send the same question N times with cosmetic wording changes.

Examples:

### Debugging
- causal/root-cause analyst;
- falsifier of the leading hypothesis;
- ownership/concurrency/lifecycle specialist;
- overlooked-state/alternative-mechanism hunter.

### Architecture
- best-design advocate under constraints;
- adversarial critic;
- alternative-architecture designer;
- invariant/API/compatibility specialist.

### Mathematics / algorithms
- proof/derivation constructor;
- counterexample hunter;
- theorem-assumption mapper;
- independent alternative derivation.

## Shared seed packet

Create `context.md` containing stable facts:

```text
Goal / decision needed:
Observed facts:
Relevant code/equations/API:
Constraints and invariants:
Evidence/tests/measurements:
What Luna already tried:
Current hypotheses/options (factually described, not endorsed):
Exact unresolved question:
```

Prefer common relevant excerpts/evidence in the packet. Do not let the seed choose hypothesis-dependent evidence that would bias every branch.

## Commands

Start the neutral seed and return immediately:

```bash
claude-panel.sh start CONTEXT_FILE ROLES_DIR OUTPUT_DIR
```

Check at a natural work boundary:

```bash
claude-panel.sh status OUTPUT_DIR
```

Only when the seed is `done`:

```bash
claude-panel.sh advance OUTPUT_DIR
```

This dispatches all independent forked experts as Claude background jobs. Later:

```bash
claude-panel.sh collect OUTPUT_DIR
```

`collect` succeeds only when all branches are done. `working` is not failure and never triggers replacement.

## Synthesis

The Primary reads all branch results and produces its own synthesis. Do **not** use majority vote. A single expert with a decisive counterexample can outweigh several agreeing but weaker analyses.

Synthesize:

1. claims shared across experts;
2. true disagreements;
3. evidence each conclusion depends on;
4. strongest counterexample/failure mode;
5. what repository evidence can cheaply adjudicate disagreement;
6. final Primary decision and confidence.

## Adaptive second wave

If Wave 1 leaves one exact dispute, add only 1-2 targeted independent branches rather than another broad swarm. Hard maximum remains 6 unless the user explicitly requests more.

## Sticky advisor continuation

If one completed expert branch is uniquely useful and the same decision domain continues:

```bash
claude-panel.sh followup BRANCH_DIR DELTA_FILE
```

v6.5 resumes **that same expert conversation sessionId** without `--fork-session`. This preserves the specialist's accumulated domain context and avoids paying to rebuild it. A new fork is appropriate only when you deliberately want an independent perspective.

Never follow up a `working` or `blocked` branch. Never promote the neutral seed itself.
