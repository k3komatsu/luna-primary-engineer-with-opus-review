#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

usage() {
  cat <<'TXT'
Usage:
  claude-panel.sh start    CONTEXT_FILE ROLES_DIR [OUTPUT_DIR]
  claude-panel.sh status   OUTPUT_DIR
  claude-panel.sh advance  OUTPUT_DIR
  claude-panel.sh collect  OUTPUT_DIR
  claude-panel.sh followup BRANCH_DIR DELTA_FILE

ROLES_DIR contains 2..6 *.md or *.txt role files.

Claude is always run in the foreground with `claude -p`. start waits for the
neutral seed, advance runs each role sequentially, and collect reads results
already written to disk. Use Ctrl-C in the invoking terminal to interrupt.
TXT
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
MODE="$1"
shift

require_claude() {
  if ! luna_primary_engineer_claude_available; then
    echo "ERROR: Claude Code is unavailable, unauthenticated, or disabled (LUNA_PRIMARY_ENGINEER_CLAUDE=off)." >&2
    exit 3
  fi
  luna_primary_engineer_warn_billing
}

MODEL="${LUNA_PRIMARY_ENGINEER_CLAUDE_MODEL:-opus}"
EFFORT="${LUNA_PRIMARY_ENGINEER_CLAUDE_PANEL_EFFORT:-max}"
SYSTEM_PROMPT="$ROOT_DIR/references/claude/panel-system.md"
SYSTEM_PROMPT_TEXT="$(cat "$SYSTEM_PROMPT")"
base_args=(
  --print
  --model "$MODEL"
  --effort "$EFFORT"
  --permission-mode dontAsk
  --permission-prompts none
  --tools "Read,Glob,Grep"
  --disallowedTools "mcp__*"
  --append-system-prompt "$SYSTEM_PROMPT_TEXT"
  --disable-slash-commands
  --no-chrome
  --no-session-persistence
)

run_foreground() {
  local output="$1" exit_file="$2" add_dir="$3" prompt="$4"
  shift 4
  mkdir -p "$(dirname "$output")"
  luna_primary_engineer_run_foreground "$output" "$exit_file" "${base_args[@]}" --add-dir "$add_dir" "$@" "$prompt"
}

case "$MODE" in
  start)
    require_claude
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    CONTEXT="$1"
    ROLES_DIR="$2"
    OUTPUT="${3:-$(luna_primary_engineer_runtime_dir)-panel}"
    [[ -f "$CONTEXT" ]] || { echo "ERROR: context not found: $CONTEXT" >&2; exit 2; }
    [[ -d "$ROLES_DIR" ]] || { echo "ERROR: roles directory not found: $ROLES_DIR" >&2; exit 2; }
    shopt -s nullglob
    ROLES=("$ROLES_DIR"/*.md "$ROLES_DIR"/*.txt)
    COUNT=${#ROLES[@]}
    (( COUNT >= 2 )) || { echo "ERROR: panel requires at least 2 role files; got $COUNT" >&2; exit 2; }
    (( COUNT <= 6 )) || { echo "ERROR: panel hard limit is 6 role files; got $COUNT" >&2; exit 2; }
    luna_primary_engineer_require_fresh_state_tree "$OUTPUT" || exit $?

    mkdir -p "$OUTPUT/seed" "$OUTPUT/roles"
    cp "$CONTEXT" "$OUTPUT/context.md"
    CONTEXT_ABS="$(cd "$OUTPUT" && pwd)/context.md"
    printf '%s\n' "$PWD" > "$OUTPUT/cwd"
    printf 'panel\n' > "$OUTPUT/kind"
    printf 'seed_running\n' > "$OUTPUT/stage"
    : > "$OUTPUT/role-names.txt"
    for role in "${ROLES[@]}"; do
      base="$(basename "$role")"
      stem="${base%.*}"
      cp "$role" "$OUTPUT/roles/$stem.md"
      printf '%s\n' "$stem" >> "$OUTPUT/role-names.txt"
      mkdir -p "$OUTPUT/$stem"
      printf '%s\n' "$OUTPUT" > "$OUTPUT/$stem/panel_root"
    done
    printf 'running\n' > "$OUTPUT/seed/stage"
    if run_foreground "$OUTPUT/seed/result.txt" "$OUTPUT/seed/run_exit_code" "$OUTPUT" \
      "LUNA_PRIMARY_ENGINEER_SHARED_SEED_MODE. This is a foreground factual-context load. Read the shared context at: $CONTEXT_ABS . Load it into the conversation. Do not diagnose, rank hypotheses, recommend a design, or propose a fix. Do not ask questions. Reply exactly SEED_READY when loaded."; then
      :
    else
      printf 'failed\n' > "$OUTPUT/seed/stage"
      printf 'failed\n' > "$OUTPUT/stage"
      cat "$OUTPUT/seed/result.txt" >&2 || true
      exit "$(cat "$OUTPUT/seed/run_exit_code")"
    fi
    if ! grep -Fq 'SEED_READY' "$OUTPUT/seed/result.txt"; then
      printf 'failed\n' > "$OUTPUT/seed/stage"
      printf 'failed\n' > "$OUTPUT/stage"
      echo "ERROR: foreground seed did not return SEED_READY." >&2
      cat "$OUTPUT/seed/result.txt" >&2 || true
      exit 18
    fi
    printf 'done\n' > "$OUTPUT/seed/stage"
    printf 'seed_done\n' > "$OUTPUT/stage"
    echo "SEED_READY"
    echo "OUTPUT_DIR=$OUTPUT"
    echo "NEXT=run claude-panel.sh advance $OUTPUT"
    ;;

  status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$1"
    [[ -d "$OUTPUT" ]] || { echo "ERROR: invalid panel directory: $OUTPUT" >&2; exit 2; }
    echo "STAGE=$(cat "$OUTPUT/stage" 2>/dev/null || echo unknown)"
    echo "[seed]"
    luna_primary_engineer_print_state_dir "$OUTPUT/seed" || true
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      if [[ -d "$OUTPUT/$stem" ]]; then
        echo "[$stem]"
        luna_primary_engineer_print_state_dir "$OUTPUT/$stem" || true
      fi
    done < "$OUTPUT/role-names.txt"
    ;;

  advance)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$1"
    [[ -f "$OUTPUT/seed/result.txt" && "$(cat "$OUTPUT/stage" 2>/dev/null || true)" == "seed_done" ]] || {
      echo "ERROR: foreground seed is not complete: $OUTPUT" >&2
      exit 10
    }
    HAS_ANY=0
    MISSING=0
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      if [[ -f "$OUTPUT/$stem/result.txt" ]]; then HAS_ANY=1; else MISSING=1; fi
    done < "$OUTPUT/role-names.txt"
    if (( HAS_ANY == 1 )); then
      if (( MISSING == 1 )); then
        echo "ERROR: panel is partially complete; inspect results before rerunning." >&2
        exit 15
      fi
      echo "INFO: all panel roles already ran; no action taken."
      exit 0
    fi

    CONTEXT_ABS="$(cd "$OUTPUT" && pwd)/context.md"
    SEED_ABS="$(cd "$OUTPUT/seed" && pwd)/result.txt"
    FAIL=0
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      D="$OUTPUT/$stem"
      ROLE_ABS="$(cd "$OUTPUT" && pwd)/roles/$stem.md"
      printf 'running\n' > "$D/stage"
      if run_foreground "$D/result.txt" "$D/run_exit_code" "$OUTPUT" \
        "You are an independent foreground panel expert. Read the shared context at: $CONTEXT_ABS , the neutral seed result at: $SEED_ABS , and your assigned role at: $ROLE_ABS . Analyze strictly from that role. Do not seek consensus with hypothetical peers. Do not ask questions; state uncertainty and finish. Return the compact panel artifact from your system instructions."; then
        if [[ -s "$D/result.txt" ]]; then
          printf 'done\n' > "$D/stage"
          cp "$D/result.txt" "$D/initial-result.txt"
        else
          printf 'failed\n' > "$D/stage"
          echo "ERROR: panel role $stem returned an empty result." >&2
          FAIL=18
        fi
      else
        printf 'failed\n' > "$D/stage"
        echo "ERROR: panel role $stem foreground Claude call failed." >&2
        FAIL="$(cat "$D/run_exit_code")"
      fi
    done < "$OUTPUT/role-names.txt"
    if (( FAIL != 0 )); then
      printf 'failed\n' > "$OUTPUT/stage"
      exit "$FAIL"
    fi
    printf 'done\n' > "$OUTPUT/stage"
    "$0" collect "$OUTPUT"
    ;;

  collect)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$1"
    [[ -f "$OUTPUT/role-names.txt" ]] || { echo "ERROR: invalid panel directory: $OUTPUT" >&2; exit 2; }
    printf 'role\tstate\tresult\n' > "$OUTPUT/manifest.tsv"
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      D="$OUTPUT/$stem"
      [[ "$(cat "$D/stage" 2>/dev/null || true)" == "done" && -f "$D/result.txt" ]] || {
        echo "ERROR: panel role $stem is not complete." >&2
        exit 10
      }
      printf '%s\tdone\t%s\n' "$stem" "$D/result.txt" >> "$OUTPUT/manifest.tsv"
    done < "$OUTPUT/role-names.txt"
    cat "$OUTPUT/manifest.tsv"
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      echo "--- $stem ---"
      cat "$OUTPUT/$stem/result.txt"
    done < "$OUTPUT/role-names.txt"
    ;;

  followup)
    require_claude
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    BRANCH="$1"
    DELTA="$2"
    [[ -f "$BRANCH/result.txt" && "$(cat "$BRANCH/stage" 2>/dev/null || true)" == "done" ]] || {
      echo "ERROR: completed foreground branch not found: $BRANCH" >&2
      exit 10
    }
    [[ -f "$DELTA" ]] || { echo "ERROR: delta not found: $DELTA" >&2; exit 2; }
    ROOT="$(cat "$BRANCH/panel_root" 2>/dev/null || dirname "$BRANCH")"
    N=1
    while [[ -e "$BRANCH/followup-$N" ]]; do N=$((N + 1)); done
    ROUND="$BRANCH/followup-$N"
    mkdir -p "$ROUND"
    cp "$DELTA" "$ROUND/followup.md"
    cp "$BRANCH/result.txt" "$ROUND/previous-result.txt"
    printf '%s\n' "$ROOT" > "$ROUND/panel_root"
    CHILD_ABS="$(cd "$ROUND" && pwd)"
    if run_foreground "$ROUND/result.txt" "$ROUND/run_exit_code" "$ROOT" \
      "Continue this panel expert's work in a fresh foreground turn. Read the previous result at: $CHILD_ABS/previous-result.txt and the new delta/question at: $CHILD_ABS/followup.md . Stay within the same decision domain, answer only the new unresolved point, do not ask questions, and finish with the compact panel artifact from your system instructions."; then
      cp "$ROUND/result.txt" "$BRANCH/result.txt"
      cp "$ROUND/run_exit_code" "$BRANCH/run_exit_code"
      printf 'done\n' > "$ROUND/stage"
      printf 'done\n' > "$BRANCH/stage"
      cat "$BRANCH/result.txt"
    else
      printf 'failed\n' > "$ROUND/stage"
      printf 'failed\n' > "$BRANCH/stage"
      cat "$ROUND/result.txt" >&2 || true
      exit "$(cat "$ROUND/run_exit_code")"
    fi
    ;;

  *) usage >&2; exit 2 ;;
esac
