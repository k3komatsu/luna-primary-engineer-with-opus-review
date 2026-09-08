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

v6.5 background seed-and-fork lifecycle:
  1. `start` dispatches one neutral Opus seed with `claude --bg` and returns immediately.
  2. `status` reports seed/branch states from `claude agents --json --all`.
  3. after seed reaches `done`, `advance` dispatches all role forks as background sessions.
  4. `collect` succeeds only when all branches are done and captures `claude logs`.
  5. a valuable completed branch can be continued with `followup`, which resumes
     the SAME completed expert conversation (sticky advisor) as a new background run.

Never call `advance`, `followup`, retry, or duplicate while the relevant session is working or blocked.
TXT
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
MODE="$1"; shift

require_claude() {
  if ! luna_orch_claude_available; then
    echo "ERROR: Claude Code is unavailable, unauthenticated, or disabled (LUNA_ORCH_CLAUDE=off)." >&2
    exit 3
  fi
  luna_orch_warn_billing
}

MODEL="${LUNA_ORCH_CLAUDE_MODEL:-opus}"
EFFORT="${LUNA_ORCH_CLAUDE_PANEL_EFFORT:-max}"
SYSTEM_PROMPT="$ROOT_DIR/references/claude/panel-system.md"
base_args=(
  --model "$MODEL"
  --effort "$EFFORT"
  --permission-mode plan
  --tools "Read,Glob,Grep"
  --disallowedTools "mcp__*"
  --append-system-prompt-file "$SYSTEM_PROMPT"
  --disable-slash-commands
  --no-chrome
)

launch_and_store() {
  local state_dir="$1" add_dir="$2" name="$3" prompt="$4"; shift 4
  local launch="$state_dir/launch.txt" id rc
  mkdir -p "$state_dir"
  set +e
  claude --bg "${base_args[@]}" --add-dir "$add_dir" "$@" --name "$name" "$prompt" >"$launch" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$state_dir/launch_exit_code"
  if (( rc != 0 )); then cat "$launch" >&2; return "$rc"; fi
  id="$(luna_orch_extract_bg_id "$launch" || true)"
  if [[ -z "$id" ]]; then
    echo "ERROR: could not parse Claude background ID from $launch" >&2
    cat "$launch" >&2
    return 4
  fi
  printf '%s\n' "$id" > "$state_dir/job_id"
  printf '%s\n' "$add_dir" > "$state_dir/panel_root"
  if [[ ! -f "$state_dir/session_id" ]]; then luna_orch_store_session_id "$state_dir" >/dev/null 2>&1 || true; fi
  printf 'JOB_ID=%s\nSESSION_ID=%s\nSTATE_DIR=%s\n' "$id" "$(cat "$state_dir/session_id" 2>/dev/null || true)" "$state_dir"
}

case "$MODE" in
  start)
    require_claude
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    CONTEXT="$1"; ROLES_DIR="$2"; OUTPUT="${3:-$(luna_orch_runtime_dir)-panel}"
    [[ -f "$CONTEXT" ]] || { echo "ERROR: context not found: $CONTEXT" >&2; exit 2; }
    [[ -d "$ROLES_DIR" ]] || { echo "ERROR: roles directory not found: $ROLES_DIR" >&2; exit 2; }
    shopt -s nullglob
    ROLES=("$ROLES_DIR"/*.md "$ROLES_DIR"/*.txt)
    COUNT=${#ROLES[@]}
    (( COUNT >= 2 )) || { echo "ERROR: panel requires at least 2 role files; got $COUNT" >&2; exit 2; }
    (( COUNT <= 6 )) || { echo "ERROR: panel hard limit is 6 role files; got $COUNT" >&2; exit 2; }

    mkdir -p "$OUTPUT/seed" "$OUTPUT/roles"
    cp "$CONTEXT" "$OUTPUT/context.md"
    printf '%s\n' "$PWD" > "$OUTPUT/cwd"
    printf 'panel\n' > "$OUTPUT/kind"
    printf 'seed_running\n' > "$OUTPUT/stage"
    : > "$OUTPUT/role-names.txt"
    for role in "${ROLES[@]}"; do
      base="$(basename "$role")"; stem="${base%.*}"
      cp "$role" "$OUTPUT/roles/$stem.md"
      printf '%s\n' "$stem" >> "$OUTPUT/role-names.txt"
      mkdir -p "$OUTPUT/$stem"
      printf '%s\n' "$OUTPUT" > "$OUTPUT/$stem/panel_root"
    done
    OUT_ABS="$(cd "$OUTPUT" && pwd)"
    launch_and_store "$OUTPUT/seed" "$OUTPUT" "luna-panel-seed" \
      "LUNA_ORCH_SHARED_SEED_MODE. Read the shared factual context at: $OUT_ABS/context.md . Load it into the conversation. Do not diagnose, rank hypotheses, recommend a design, or propose a fix. Do not ask questions. Reply exactly SEED_READY when loaded."
    echo "NEXT=after seed is done, run: claude-panel.sh advance $OUTPUT"
    ;;

  status)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$1"
    [[ -f "$OUTPUT/seed/job_id" ]] || { echo "ERROR: invalid panel directory: $OUTPUT" >&2; exit 2; }
    echo "STAGE=$(cat "$OUTPUT/stage" 2>/dev/null || echo unknown)"
    echo "[seed]"
    luna_orch_print_state_dir "$OUTPUT/seed" || true
    if [[ -f "$OUTPUT/role-names.txt" ]]; then
      while IFS= read -r stem; do
        [[ -n "$stem" ]] || continue
        if [[ -f "$OUTPUT/$stem/job_id" ]]; then
          echo "[$stem]"
          luna_orch_print_state_dir "$OUTPUT/$stem" || true
        fi
      done < "$OUTPUT/role-names.txt"
    fi
    ;;

  advance)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$1"
    [[ -f "$OUTPUT/seed/job_id" && -f "$OUTPUT/role-names.txt" ]] || { echo "ERROR: invalid panel directory: $OUTPUT" >&2; exit 2; }
    # Idempotence: if any branch has a job_id, require all expected branches to
    # already have one; never partially duplicate a panel automatically.
    HAS_ANY=0; MISSING=0
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      if [[ -f "$OUTPUT/$stem/job_id" ]]; then HAS_ANY=1; else MISSING=1; fi
    done < "$OUTPUT/role-names.txt"
    if (( HAS_ANY == 1 )); then
      if (( MISSING == 1 )); then
        echo "ERROR: panel is partially launched. Do not auto-fill missing branches; inspect launch files/state first." >&2
        exit 15
      fi
      echo "INFO: all panel branches already launched; no action taken."
      exit 0
    fi

    SEED_ID="$(cat "$OUTPUT/seed/job_id")"
    SEED_STATE="$(luna_orch_bg_state "$SEED_ID")"
    case "$SEED_STATE" in
      done|completed) ;;
      working|idle) echo "NOT_READY: seed $SEED_ID is $SEED_STATE. Do not duplicate it." >&2; exit 10 ;;
      blocked|needs_input|needs-input) echo "BLOCKED: seed $SEED_ID. Inspect logs; do not replace it automatically." >&2; claude logs "$SEED_ID" >&2 || true; exit 11 ;;
      failed) echo "FAILED: seed $SEED_ID. Inspect logs before any retry." >&2; claude logs "$SEED_ID" >&2 || true; exit 12 ;;
      stopped) echo "STOPPED: seed $SEED_ID." >&2; exit 13 ;;
      *) echo "UNKNOWN seed state for $SEED_ID" >&2; exit 14 ;;
    esac
    luna_orch_bg_logs "$SEED_ID" "$OUTPUT/seed/result.txt" || true
    SEED_SESSION_ID="$(luna_orch_bg_session_id "$SEED_ID" 2>/dev/null || true)"
    [[ -n "$SEED_SESSION_ID" ]] || { echo "ERROR: could not resolve full sessionId for panel seed job $SEED_ID." >&2; exit 16; }
    printf '%s\n' "$SEED_SESSION_ID" > "$OUTPUT/seed/session_id"
    OUT_ABS="$(cd "$OUTPUT" && pwd)"
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      D="$OUTPUT/$stem"
      ROLE_ABS="$OUT_ABS/roles/$stem.md"
      launch_and_store "$D" "$OUTPUT" "luna-panel-$stem" \
        "You are one independent branch forked from the neutral shared-context seed. Read your assigned role at: $ROLE_ABS . Analyze the inherited shared context strictly from that role. Do not seek consensus with hypothetical peers. Do not ask the orchestrator questions; state uncertainty and finish. Return the compact panel artifact from your system instructions." \
        --resume "$SEED_SESSION_ID" --fork-session >/dev/null
      printf '%s\n' "$SEED_ID" > "$D/parent_job_id"
      printf '%s\n' "$SEED_SESSION_ID" > "$D/parent_session_id"
      echo "$stem JOB_ID=$(cat "$D/job_id")"
    done < "$OUTPUT/role-names.txt"
    printf 'branches_running\n' > "$OUTPUT/stage"
    ;;

  collect)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$1"
    [[ -f "$OUTPUT/role-names.txt" ]] || { echo "ERROR: invalid panel directory: $OUTPUT" >&2; exit 2; }
    FAIL=0
    printf 'role\tstate\tjob_id\tresult\n' > "$OUTPUT/manifest.tsv"
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      D="$OUTPUT/$stem"
      [[ -f "$D/job_id" ]] || { echo "ERROR: branch $stem not launched; run advance after seed completes." >&2; exit 2; }
      ID="$(cat "$D/job_id")"; REC="$(luna_orch_bg_record "$ID")"; STATE="${REC%%$'\t'*}"; STATUS="${REC#*$'\t'}"
      case "$STATE" in
        done|completed)
          if [[ ! -f "$D/session_id" ]]; then luna_orch_store_session_id "$D" >/dev/null 2>&1 || true; fi
          luna_orch_bg_logs "$ID" "$D/result.txt"
          [[ -f "$D/initial-result.txt" ]] || cp "$D/result.txt" "$D/initial-result.txt"
          printf '%s\t%s\t%s\t%s\n' "$stem" "$STATE" "$ID" "$D/result.txt" >> "$OUTPUT/manifest.tsv"
          ;;
        working|idle) echo "NOT_READY: $stem $ID is $STATE. $STATUS" >&2; FAIL=10 ;;
        blocked|needs_input|needs-input) echo "BLOCKED: $stem $ID. $STATUS" >&2; claude logs "$ID" >&2 || true; FAIL=11 ;;
        failed) echo "FAILED: $stem $ID. $STATUS" >&2; claude logs "$ID" >&2 || true; FAIL=12 ;;
        stopped) echo "STOPPED: $stem $ID." >&2; FAIL=13 ;;
        *) echo "UNKNOWN: $stem $ID." >&2; FAIL=14 ;;
      esac
    done < "$OUTPUT/role-names.txt"
    if (( FAIL != 0 )); then exit "$FAIL"; fi
    printf 'done\n' > "$OUTPUT/stage"
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
    BRANCH="$1"; DELTA="$2"
    [[ -f "$BRANCH/job_id" ]] || { echo "ERROR: missing $BRANCH/job_id" >&2; exit 2; }
    [[ -f "$DELTA" ]] || { echo "ERROR: delta not found: $DELTA" >&2; exit 2; }
    JOB_ID="$(cat "$BRANCH/job_id")"
    STATE="$(luna_orch_bg_state "$JOB_ID")"
    if [[ "$STATE" != "done" && "$STATE" != "completed" ]]; then
      echo "ERROR: expert job $JOB_ID is '$STATE'. Never resume a working or blocked advisor." >&2
      exit 10
    fi
    SESSION_ID="$(cat "$BRANCH/session_id" 2>/dev/null || true)"
    if [[ -z "$SESSION_ID" ]]; then SESSION_ID="$(luna_orch_bg_session_id "$JOB_ID" 2>/dev/null || true)"; fi
    [[ -n "$SESSION_ID" ]] || { echo "ERROR: could not resolve conversation sessionId for expert job $JOB_ID." >&2; exit 16; }
    printf '%s\n' "$SESSION_ID" > "$BRANCH/session_id"
    ROOT="$(cat "$BRANCH/panel_root" 2>/dev/null || dirname "$BRANCH")"
    N=1; while [[ -e "$BRANCH/followup-$N" ]]; do N=$((N+1)); done
    ROUND="$BRANCH/followup-$N"
    mkdir -p "$ROUND"
    cp "$DELTA" "$ROUND/followup.md"
    printf '%s\n' "$ROOT" > "$ROUND/panel_root"
    printf '%s\n' "$JOB_ID" > "$ROUND/previous_job_id"
    printf '%s\n' "$SESSION_ID" > "$ROUND/session_id"
    [[ -f "$BRANCH/result.txt" ]] && cp "$BRANCH/result.txt" "$ROUND/previous-result.txt"
    [[ -f "$BRANCH/launch.txt" ]] && cp "$BRANCH/launch.txt" "$ROUND/previous-launch.txt"
    CHILD_ABS="$(cd "$ROUND" && pwd)"
    launch_and_store "$BRANCH" "$ROOT" "luna-panel-followup" \
      "Continue the SAME expert conversation for the same decision domain. Read the new delta/question at: $CHILD_ABS/followup.md . Use your existing context, answer only the new unresolved point, do not ask questions, and finish with the compact panel artifact." \
      --resume "$SESSION_ID"
    NEW_JOB_ID="$(cat "$BRANCH/job_id")"
    ACTUAL_SESSION_ID="$(luna_orch_bg_session_id "$NEW_JOB_ID" 2>/dev/null || true)"
    if [[ -n "$ACTUAL_SESSION_ID" && "$ACTUAL_SESSION_ID" != "$SESSION_ID" ]]; then
      echo "ERROR: sticky advisor follow-up unexpectedly changed conversation sessionId ($ACTUAL_SESSION_ID != $SESSION_ID)." >&2
      exit 17
    fi
    printf '%s\n' "$SESSION_ID" > "$BRANCH/session_id"
    printf 'STICKY_ADVISOR_SESSION_ID=%s\nCURRENT_JOB_ID=%s\nROUND=followup-%s\nBRANCH_DIR=%s\n' "$SESSION_ID" "$NEW_JOB_ID" "$N" "$BRANCH"
    ;;

  *) usage >&2; exit 2 ;;
esac
