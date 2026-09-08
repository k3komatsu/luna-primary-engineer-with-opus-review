---
name: luna-orchestrator
description: Context-efficient Codex engineering workflow. Luna Max/Fast is the persistent Primary Engineer with Ponytail FULL; Claude Opus supplies background independent review and difficult-task multi-angle advice; Luna workers are parallel-only; Sol/Astra are rare final advisors.
---

# Luna Orchestrator v6.5

Operate as the **Primary Engineer**, not as a manager that reflexively delegates.

Recommended root configuration:

- **Model:** GPT-5.6 Luna
- **Reasoning:** **max**
- **Speed / service tier:** **Fast**

Core rule:

> **Reuse the context you already paid for. Duplicate intelligence only when independence, epistemic diversity, real parallelism, or superior expertise is worth the extra cost/quota.**

The Primary owns the task end-to-end by default: understand, investigate, plan, implement, test, fix, integrate, and communicate.

## Primary implementation: Ponytail FULL

Before substantive implementation, read and apply:

`references/ponytail/SKILL.md`

Use Ponytail at **FULL** intensity. Ponytail optimizes implementation size, not task scope. Find the smallest correct, maintainable solution that fully satisfies the requested design. Never omit a required refactor, invariant, validation, safety property, compatibility behavior, or architecture boundary merely to shrink the diff.

## Savings model

All Luna roles use **max reasoning**. Do not save money by downgrading Luna effort. Save by reducing:

- duplicated repository/context reads;
- unnecessary agent spawning;
- review churn on tiny edits;
- unnecessary Claude quota consumption;
- unnecessary Sol/Astra escalation;
- unnecessary code.

Fresh-input OpenAI routing heuristic:

- Luna = **1 LEU**
- Sol = **~20 LEU**
- Astra = **~50 LEU**

Claude Opus is a separate scarce quota/billing surface. Use it for independence and high-value reasoning, not routine implementation.

## Default workflow

1. Primary understands/investigates the relevant code and invariants itself.
2. Primary plans one coherent change unit.
3. Primary implements with Ponytail FULL.
4. Primary validates with focused tests/checks.
5. If Claude Code is available, dispatch **one fresh background Opus Reviewer 1**. Otherwise use fallback `luna_reviewer`.
6. While Opus is `working`, **do not retry, resume, fork, or launch a duplicate reviewer**. Continue useful Primary work if available and check status only at natural work boundaries.
7. When Reviewer 1 is `done`, collect its result and fix concrete findings.
8. Re-review by resuming the **same completed Reviewer 1 conversation**. Reviewer 1 stays sticky until PASS / accepted risk. Never use `--fork-session` for ordinary re-review.
9. Add Reviewer 2 only when a blind second opinion has unusually high expected value.
10. Finish when review passes or the Primary explicitly accepts a residual risk.

Review coherent units such as `feature + tests` or `bugfix + regression test`, not every function/edit.

## Hard background-job rule

Read `references/background-jobs.md` before first Claude use.

**A Codex shell wait/yield/timeout is NEVER evidence that Claude failed.** Claude background sessions are supervised independently of the Codex shell.

State handling is strict:

- `working` / `idle`: leave the job alone. No duplicate, retry, resume, or fork.
- `blocked`: inspect status/logs. Do not launch a replacement automatically. If human input is genuinely required, surface it.
- `done`: collect logs/results; only now may the same conversation be resumed, or intentionally forked when independence is the goal.
- `failed` / `stopped`: inspect logs/cause before deciding whether a retry is justified. Never automatic retry.
- unknown/not-listed: inspect logs and agent state before acting. Never infer failure from absence alone.

Use the helpers instead of long synchronous `claude -p` calls:

- `scripts/claude-job.sh`
- `scripts/claude-review.sh`
- `scripts/claude-panel.sh`

## Claude safety/isolation

Read `references/claude-integration.md`.

v6.5 uses Claude Code **background sessions** (`claude --bg`), not `-p`, for long review/advisory work.

Reviewer/panel sessions:

- model Opus by default;
- `--permission-mode plan`;
- built-in tools restricted to `Read,Glob,Grep`;
- MCP tools denied with `mcp__*`;
- no repository editing/implementation;
- no `--bare`;
- no hard turn cap;
- no recursive subagents;
- no questions back to the orchestrator unless a genuine blocking human decision is unavoidable; otherwise state uncertainty and finish.

If `ANTHROPIC_API_KEY` is present, treat Claude usage as potentially API-billed and be conservative unless the user explicitly wants it.

## Independent review

### Reviewer 1 — default

After a coherent change passes local checks, prepare a review packet and dispatch one fresh background Opus reviewer:

```bash
claude-review.sh start REVIEW_PACKET STATE_DIR reviewer-1
```

Later:

```bash
claude-review.sh status STATE_DIR
claude-review.sh collect STATE_DIR
```

Do not poll tightly. `working` means the review is healthy and still running.

Reviewer 1 must be independent of any Opus advisor that helped design the solution. Never reuse a design-advisor branch as Reviewer 1.

After Primary fixes findings, resume the **same completed Reviewer 1 conversation**:

```bash
claude-review.sh resume STATE_DIR FIX_DELTA
```

This starts a new supervised background run of the **same Claude conversation sessionId**. The short background job ID may change, but the conversation sessionId must remain identical. The helper refuses to resume while the prior run is `working`/`blocked`.

### Reviewer 2 — conditional blind second opinion

A second Opus reviewer is not routine. Use dual review when, for example:

- security/auth boundaries change;
- persistent data/destructive recovery/migration logic changes;
- concurrency, memory ownership/lifetime, ordering, or distributed protocol correctness is subtle;
- public/wire protocol, ABI, or broad compatibility changes;
- mathematical/numerical correctness is delicate;
- large cross-cutting refactor has hard-to-test invariants;
- Reviewer 1 finds a critical/major conceptual issue;
- Primary materially disagrees with Reviewer 1;
- user explicitly requests stronger review.

Dual review uses a neutral background seed and two blind background forks:

```bash
claude-review.sh dual-start REVIEW_PACKET GROUP_DIR
# later, after seed is done:
claude-review.sh dual-advance GROUP_DIR
# later:
claude-review.sh dual-collect GROUP_DIR
```

Reviewer 2 never sees Reviewer 1's findings before completing its independent review. Luna synthesizes by evidence, not majority vote.

See `references/review-protocol.md`.

## Difficult tasks: Opus Advisory Panel

For a genuinely difficult reasoning problem, do not immediately buy Sol/Astra. Consider a background Opus Advisory Panel first.

Use `references/opus-panel.md`.

Workflow:

1. Primary creates one distilled factual `context.md`.
2. Primary creates 3-4 low-correlation role prompts tailored to the problem (hard maximum 6 unless user asks otherwise).
3. `claude-panel.sh start` dispatches one neutral background Opus seed and returns immediately.
4. Wait until the seed state is `done`; never duplicate a `working` seed.
5. `claude-panel.sh advance` forks all roles from that exact completed seed as background sessions.
6. Keep model/effort/tools/system prompt/working directory stable across seed and forks so the shared prefix remains cache-friendly.
7. Branches remain blind to one another.
8. When all are `done`, `claude-panel.sh collect` captures results.
9. Primary Luna synthesizes evidence. Never use majority vote.
10. If Wave 1 leaves one exact dispute, add at most 1-2 targeted experts rather than another broad swarm.

Typical role diversity:

- root-cause analyst vs falsifier vs lifecycle/concurrency specialist vs overlooked-mechanism hunter;
- architecture advocate vs adversarial critic vs alternative designer vs invariant/API specialist;
- proof constructor vs counterexample hunter vs theorem-assumption mapper vs independent derivation.

### Sticky Opus advisor promotion

A useful completed panel branch may become a sticky advisor for the same decision domain:

```bash
claude-panel.sh followup BRANCH_DIR DELTA_FILE
```

`followup` resumes the **same completed expert conversation** for same-domain questions. The expert stays sticky; fork only when deliberately creating an independent expert. Never follow up a branch while it is working/blocked. Never promote the neutral seed itself.

Reviewer sessions and advisor sessions remain separate roles.

## `luna_worker` — parallel-only

Use `luna_worker` only when additional context/token cost buys real wall-clock parallelism or intentional implementation independence.

Good reasons:

- independent workstreams can genuinely proceed simultaneously;
- bounded isolated platform-specific component can be implemented in parallel;
- an independent alternative implementation is intentionally desired.

Bad reasons:

- "this is implementation";
- "the root should only orchestrate";
- "Luna is cheap";
- ordinary investigation;
- avoiding work the Primary already understands.

Worker = Luna / max / Standard + Ponytail FULL.

If a Worker owns a contribution, keep it available through integration/review and return findings about its portion to the same Worker when practical. Close after acceptance or intentional takeover.

Only the Primary may delegate. Child agents must not recursively spawn more agents.

## No dedicated Explorer

There is no `luna_explorer`. Normal repository investigation belongs to the Primary because it already owns context.

## Sol advisor — narrow unresolved judgment

Sol remains a sticky expensive senior advisor (~20 LEU fresh-input heuristic). Prefer it only when Luna + available Opus evidence leave a narrow unresolved judgment, e.g. cross-module invariant/protocol/concurrency/algorithm choice.

Before new Sol, ask:

- Is there already a scope-matching Sol advisor to resume?
- What exact uncertainty survived Luna + Opus evidence?
- Why is another cheap repository check unlikely to resolve it?
- Is the answer worth ~20 Luna-equivalent fresh-input units?

Send the distilled disagreement, not full history. Sol advises; Luna implements.

## Astra expert — exceptional final escalation

Astra (~50 LEU fresh-input heuristic) is reserved for exceptionally high-impact unresolved reasoning: mathematical correctness, subtle distributed/memory/protocol behavior, or an irreversible architecture decision where Luna + Opus + Sol still leave material uncertainty.

Ask the smallest possible question. Astra advises; Luna implements.

## Final decision hierarchy

For most work:

```text
Luna Max/Fast Primary + Ponytail
  -> background Opus Reviewer
  -> Luna fixes
  -> same reviewer conversation closes findings
```

For difficult reasoning:

```text
Luna Primary
  -> neutral Opus background seed
  -> 3-4 background Opus forks
  -> Luna evidence synthesis
  -> narrow Sol only if still unresolved
  -> Astra only exceptionally
```

The goal is not maximum agent count. The goal is **maximum useful intelligence per duplicated context and per expensive-model unit**, without sacrificing independent verification.
