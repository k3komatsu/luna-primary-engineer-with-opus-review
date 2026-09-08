# Opus advisory panel

Use a panel only when the difficult part is reasoning, not routine
implementation. Luna remains the router and evidence synthesizer.

## Architecture

```text
Luna creates factual context + role files
                    |
          foreground neutral seed
                    |
       foreground Analyst / Skeptic / Specialist
                    |
                Luna synthesis
```

The seed must load facts only and return `SEED_READY`. Each role is an
independent foreground call that reads the shared context and its assigned role.
Role calls run sequentially to avoid concurrent Claude instability.

## Role generation

Choose roles that attack different failure modes, for example:

- causal/root-cause analyst;
- falsifier of the leading hypothesis;
- ownership/concurrency/lifecycle specialist;
- overlooked-state or alternative-mechanism hunter.

Keep the hard maximum at six roles unless the user explicitly requests more.

## Commands

```bash
claude-panel.sh start CONTEXT_FILE ROLES_DIR OUTPUT_DIR
claude-panel.sh status OUTPUT_DIR
claude-panel.sh advance OUTPUT_DIR
claude-panel.sh collect OUTPUT_DIR
claude-panel.sh followup BRANCH_DIR DELTA_FILE
```

`start` waits for the neutral seed. `advance` waits for each role in order.
`collect` prints stored role results. `followup` reads the prior branch result
and the new delta in a fresh foreground call.

## Synthesis

Luna should record:

1. claims shared across experts;
2. true disagreements;
3. evidence each conclusion depends on;
4. strongest counterexample or failure mode;
5. cheap repository evidence that can adjudicate disagreement;
6. final decision and confidence.

Do not use majority vote. One decisive counterexample can outweigh several
weaker agreeing analyses.
