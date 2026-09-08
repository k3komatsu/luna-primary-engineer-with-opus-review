#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

usage() {
  cat <<'TXT'
Usage:
  claude-review.sh start        REVIEW_PACKET [STATE_DIR] [LABEL]
  claude-review.sh status       STATE_DIR
  claude-review.sh collect      STATE_DIR
  claude-review.sh resume       STATE_DIR FIX_DELTA

  claude-review.sh dual-start   REVIEW_PACKET [GROUP_DIR]
  claude-review.sh dual-status  GROUP_DIR
  claude-review.sh dual-advance GROUP_DIR
  claude-review.sh dual-collect GROUP_DIR

v6.5 lifecycle:
  - Every long Opus review runs as a Claude Code background session (`claude --bg`).
  - start/dual-start return immediately after dispatch.
  - `working` is NEVER treated as timeout/failure and MUST NOT be duplicated.
  - re-review resumes the SAME completed reviewer conversation (sticky until PASS).
  - dual review is a background neutral seed, followed by two blind background forks; each reviewer then stays sticky for re-review.

Examples:
  claude-review.sh start review.md /tmp/reviewer-1 reviewer-1
  claude-review.sh status /tmp/reviewer-1
  claude-review.sh collect /tmp/reviewer-1
  claude-review.sh resume /tmp/reviewer-1 fix-delta.md

  claude-review.sh dual-start review.md /tmp/dual-review
  claude-review.sh dual-status /tmp/dual-review
  claude-review.sh dual-advance /tmp/dual-review   # only launches forks after seed is done
  claude-review.sh dual-collect /tmp/dual-review
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
EFFORT="${LUNA_ORCH_CLAUDE_REVIEW_EFFORT:-xhigh}"
SYSTEM_PROMPT="$ROOT_DIR/references/claude/reviewer-system.md"

# IMPORTANT: these flags are the same for neutral seed and reviewer forks.
# --tools does not restrict MCP tools, so deny them explicitly.
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

launch_bg() {
  local state_dir="$1" name="$2" prompt="$3"; shift 3
  local launch="$state_dir/launch.txt" id
  mkdir -p "$state_dir"
  set +e
  claude --bg "${base_args[@]}" --add-dir "$state_dir" "$@" --name "$name" "$prompt" >"$launch" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc" > "$state_dir/launch_exit_code"
  if (( rc != 0 )); then
    cat "$launch" >&2
    return "$rc"
  fi
  id="$(luna_orch_extract_bg_id "$launch" || true)"
  if [[ -z "$id" ]]; then
    echo "ERROR: could not parse Claude background ID from $launch" >&2
    cat "$launch" >&2
    return 4
  fi
  printf '%s\n' "$id" > "$state_dir/job_id"
  printf '%s\n' "$PWD" > "$state_dir/cwd"
  if [[ ! -f "$state_dir/session_id" ]]; then luna_orch_store_session_id "$state_dir" >/dev/null 2>&1 || true; fi
  printf 'JOB_ID=%s\nSESSION_ID=%s\nSTATE_DIR=%s\n' "$id" "$(cat "$state_dir/session_id" 2>/dev/null || true)" "$state_dir"
}

review_status() {
  local state_dir="$1" id expected actual
  if [[ -f "$state_dir/job_id" && -f "$state_dir/session_id" ]]; then
    id="$(cat "$state_dir/job_id")"
    expected="$(cat "$state_dir/session_id")"
    actual="$(luna_orch_bg_session_id "$id" 2>/dev/null || true)"
    if [[ -n "$actual" && "$actual" != "$expected" ]]; then
      echo "ERROR: reviewer background job $id belongs to sessionId $actual, expected sticky sessionId $expected." >&2
      return 17
    fi
  fi
  luna_orch_print_state_dir "$state_dir"
}

review_collect() {
  local state_dir="$1" id rec state status out
  [[ -f "$state_dir/job_id" ]] || { echo "ERROR: missing $state_dir/job_id" >&2; return 2; }
  id="$(cat "$state_dir/job_id")"
  rec="$(luna_orch_bg_record "$id")"
  state="${rec%%$'\t'*}"
  status="${rec#*$'\t'}"
  out="$state_dir/result.txt"
  case "$state" in
    done|completed)
      if [[ ! -f "$state_dir/session_id" ]]; then luna_orch_store_session_id "$state_dir" >/dev/null 2>&1 || true; fi
      expected_sid="$(cat "$state_dir/session_id" 2>/dev/null || true)"
      actual_sid="$(luna_orch_bg_session_id "$id" 2>/dev/null || true)"
      if [[ -n "$expected_sid" && -n "$actual_sid" && "$actual_sid" != "$expected_sid" ]]; then
        echo "ERROR: reviewer job $id is attached to unexpected sessionId $actual_sid (expected $expected_sid)." >&2
        return 17
      fi
      luna_orch_bg_logs "$id" "$out"
      if [[ -f "$state_dir/current_round" ]]; then
        round_dir="$state_dir/$(cat "$state_dir/current_round")"
        mkdir -p "$round_dir"
        cp "$out" "$round_dir/result.txt"
      elif [[ ! -f "$state_dir/initial-result.txt" ]]; then
        cp "$out" "$state_dir/initial-result.txt"
      fi
      cat "$out"
      ;;
    working|idle)
      echo "NOT_READY: reviewer $id is $state. Do not resume/retry/duplicate it. $status" >&2
      return 10
      ;;
    blocked|needs_input|needs-input)
      echo "BLOCKED: reviewer $id needs input. Do not launch a replacement automatically. $status" >&2
      claude logs "$id" >&2 || true
      return 11
      ;;
    failed)
      echo "FAILED: reviewer $id. Inspect logs before any retry. $status" >&2
      claude logs "$id" >&2 || true
      return 12
      ;;
    stopped)
      echo "STOPPED: reviewer $id. Inspect cause before any retry. $status" >&2
      claude logs "$id" >&2 || true
      return 13
      ;;
    *)
      echo "UNKNOWN: reviewer $id is not in agent listing. Inspect logs before any retry." >&2
      claude logs "$id" >&2 || true
      return 14
      ;;
  esac
}

case "$MODE" in
  start)
    require_claude
    [[ $# -ge 1 && $# -le 3 ]] || { usage >&2; exit 2; }
    PACKET="$1"
    STATE_DIR="${2:-$(luna_orch_runtime_dir)-review}"
    LABEL="${3:-reviewer-1}"
    [[ -f "$PACKET" ]] || { echo "ERROR: packet not found: $PACKET" >&2; exit 2; }
    mkdir -p "$STATE_DIR"
    cp "$PACKET" "$STATE_DIR/review-packet.md"
    printf '%s\n' "$LABEL" > "$STATE_DIR/label"
    printf 'single-review\n' > "$STATE_DIR/kind"
    PACKET_ABS="$(cd "$STATE_DIR" && pwd)/review-packet.md"
    launch_bg "$STATE_DIR" "luna-orch-$LABEL" \
      "Independently review the coherent change. First read the review packet at: $PACKET_ABS . Inspect repository files only as needed. Do not ask the orchestrator questions; if evidence is incomplete, record the uncertainty in the review and finish. Return the review contract from your system instructions."
    ;;

  status)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    review_status "$1"
    ;;

  collect)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    review_collect "$1"
    ;;

  resume)
    require_claude
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    STATE_DIR="$1"; DELTA="$2"
    [[ -f "$STATE_DIR/job_id" ]] || { echo "ERROR: missing $STATE_DIR/job_id" >&2; exit 2; }
    [[ -f "$DELTA" ]] || { echo "ERROR: delta not found: $DELTA" >&2; exit 2; }

    JOB_ID="$(cat "$STATE_DIR/job_id")"
    STATE="$(luna_orch_bg_state "$JOB_ID")"
    if [[ "$STATE" != "done" && "$STATE" != "completed" ]]; then
      echo "ERROR: reviewer job $JOB_ID is '$STATE'. Never resume a working or blocked reviewer." >&2
      exit 10
    fi

    SESSION_ID="$(cat "$STATE_DIR/session_id" 2>/dev/null || true)"
    if [[ -z "$SESSION_ID" ]]; then
      SESSION_ID="$(luna_orch_bg_session_id "$JOB_ID" 2>/dev/null || true)"
    fi
    [[ -n "$SESSION_ID" ]] || {
      echo "ERROR: could not resolve Claude conversation sessionId for reviewer job $JOB_ID; refusing to create a new reviewer implicitly." >&2
      exit 16
    }
    printf '%s\n' "$SESSION_ID" > "$STATE_DIR/session_id"

    N=1
    while [[ -e "$STATE_DIR/rereview-$N" ]]; do N=$((N+1)); done
    ROUND="$STATE_DIR/rereview-$N"
    mkdir -p "$ROUND"
    cp "$DELTA" "$ROUND/fix-delta.md"
    printf '%s\n' "$JOB_ID" > "$ROUND/previous_job_id"
    printf '%s\n' "$SESSION_ID" > "$ROUND/session_id"
    [[ -f "$STATE_DIR/result.txt" ]] && cp "$STATE_DIR/result.txt" "$ROUND/previous-result.txt"
    [[ -f "$STATE_DIR/launch.txt" ]] && cp "$STATE_DIR/launch.txt" "$ROUND/previous-launch.txt"
    printf 'rereview-%s\n' "$N" > "$STATE_DIR/current_round"
    DELTA_ABS="$(cd "$ROUND" && pwd)/fix-delta.md"

    # Sticky reviewer: the previous background run is already done, so resume
    # the SAME Claude conversation. Do not use --fork-session here. Forks are
    # reserved for intentionally independent reviewers/panel branches.
    launch_bg "$STATE_DIR" "luna-orch-rereview" \
      "Continue the SAME review conversation. Read the Primary's fix delta and verification evidence at: $DELTA_ABS . Re-check your previous findings, mark each relevant finding OPEN or CLOSED, inspect regressions introduced by the fixes, and return the same concise review contract. Do not broaden scope unless the fix reveals a new blocker. Do not ask questions; finish with the evidence available." \
      --resume "$SESSION_ID"

    # `--resume` without `--fork-session` must keep the same conversation ID.
    # The short background job ID may change across supervised runs, which is OK.
    NEW_JOB_ID="$(cat "$STATE_DIR/job_id")"
    NEW_SESSION_ID="$(luna_orch_bg_session_id "$NEW_JOB_ID" 2>/dev/null || true)"
    if [[ -n "$NEW_SESSION_ID" && "$NEW_SESSION_ID" != "$SESSION_ID" ]]; then
      echo "ERROR: Claude returned a different conversation sessionId on sticky re-review ($NEW_SESSION_ID != $SESSION_ID). Stop and inspect; do not silently accept a fresh reviewer." >&2
      exit 17
    fi
    printf '%s\n' "$SESSION_ID" > "$STATE_DIR/session_id"
    printf 'STICKY_REVIEWER_SESSION_ID=%s\nCURRENT_JOB_ID=%s\nROUND=rereview-%s\nSTATE_DIR=%s\n' "$SESSION_ID" "$NEW_JOB_ID" "$N" "$STATE_DIR"
    ;;

  dual-start)
    require_claude
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    PACKET="$1"
    GROUP="${2:-$(luna_orch_runtime_dir)-dual-review}"
    [[ -f "$PACKET" ]] || { echo "ERROR: packet not found: $PACKET" >&2; exit 2; }
    mkdir -p "$GROUP/seed" "$GROUP/reviewer-1" "$GROUP/reviewer-2"
    cp "$PACKET" "$GROUP/review-packet.md"
    printf '%s\n' "$PWD" > "$GROUP/cwd"
    printf 'dual-review\n' > "$GROUP/kind"
    printf 'seed_running\n' > "$GROUP/stage"
    PACKET_ABS="$(cd "$GROUP" && pwd)/review-packet.md"
    # For cache reuse, the seed and branches all use GROUP as --add-dir and the
    # same base_args. launch_bg would add seed dir, so launch explicitly here.
    LAUNCH="$GROUP/seed/launch.txt"
    set +e
    claude --bg "${base_args[@]}" --add-dir "$GROUP" --name "luna-review-seed" \
      "LUNA_ORCH_SHARED_SEED_MODE. Read the review packet at: $PACKET_ABS . Load it as shared factual context only. Do not evaluate correctness, identify defects, rank risks, or propose fixes. Do not ask questions. Reply exactly SEED_READY when loaded." >"$LAUNCH" 2>&1
    RC=$?
    set -e
    printf '%s\n' "$RC" > "$GROUP/seed/launch_exit_code"
    if (( RC != 0 )); then cat "$LAUNCH" >&2; exit "$RC"; fi
    ID="$(luna_orch_extract_bg_id "$LAUNCH" || true)"
    [[ -n "$ID" ]] || { echo "ERROR: could not parse seed background ID" >&2; cat "$LAUNCH" >&2; exit 4; }
    printf '%s\n' "$ID" > "$GROUP/seed/job_id"
    printf 'SEED_JOB_ID=%s\nGROUP_DIR=%s\nNEXT=run dual-advance after seed state is done\n' "$ID" "$GROUP"
    ;;

  dual-status)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$1"
    [[ -f "$GROUP/seed/job_id" ]] || { echo "ERROR: invalid dual group: $GROUP" >&2; exit 2; }
    echo "STAGE=$(cat "$GROUP/stage" 2>/dev/null || echo unknown)"
    echo "[seed]"
    luna_orch_print_state_dir "$GROUP/seed" || true
    for n in 1 2; do
      if [[ -f "$GROUP/reviewer-$n/job_id" ]]; then
        echo "[reviewer-$n]"
        luna_orch_print_state_dir "$GROUP/reviewer-$n" || true
      fi
    done
    ;;

  dual-advance)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$1"
    [[ -f "$GROUP/seed/job_id" ]] || { echo "ERROR: invalid dual group: $GROUP" >&2; exit 2; }
    if [[ -f "$GROUP/reviewer-1/job_id" || -f "$GROUP/reviewer-2/job_id" ]]; then
      echo "INFO: dual reviewer forks already launched; no action taken."
      exit 0
    fi
    SEED_ID="$(cat "$GROUP/seed/job_id")"
    SEED_STATE="$(luna_orch_bg_state "$SEED_ID")"
    case "$SEED_STATE" in
      done|completed) ;;
      working|idle) echo "NOT_READY: seed $SEED_ID is $SEED_STATE. Do not duplicate it." >&2; exit 10 ;;
      blocked|needs_input|needs-input) echo "BLOCKED: seed $SEED_ID. Inspect logs; do not replace it automatically." >&2; claude logs "$SEED_ID" >&2 || true; exit 11 ;;
      failed) echo "FAILED: seed $SEED_ID. Inspect logs before retry." >&2; claude logs "$SEED_ID" >&2 || true; exit 12 ;;
      stopped) echo "STOPPED: seed $SEED_ID." >&2; exit 13 ;;
      *) echo "UNKNOWN seed state for $SEED_ID" >&2; exit 14 ;;
    esac
    luna_orch_bg_logs "$SEED_ID" "$GROUP/seed/result.txt" || true
    SEED_SESSION_ID="$(luna_orch_bg_session_id "$SEED_ID" 2>/dev/null || true)"
    [[ -n "$SEED_SESSION_ID" ]] || { echo "ERROR: could not resolve full sessionId for review seed job $SEED_ID." >&2; exit 16; }
    printf '%s\n' "$SEED_SESSION_ID" > "$GROUP/seed/session_id"
    for n in 1 2; do
      D="$GROUP/reviewer-$n"; LAUNCH="$D/launch.txt"
      set +e
      claude --bg "${base_args[@]}" --add-dir "$GROUP" \
        --resume "$SEED_SESSION_ID" --fork-session --name "luna-orch-reviewer-$n" \
        "You are Reviewer $n, an independent blind branch forked from the neutral review seed. Review the inherited coherent change now. Never seek or infer the other reviewer's opinion. Inspect repository files only as needed. Do not ask the orchestrator questions; record uncertainty and finish. Return the review contract from your system instructions." >"$LAUNCH" 2>&1
      RC=$?
      set -e
      printf '%s\n' "$RC" > "$D/launch_exit_code"
      if (( RC != 0 )); then cat "$LAUNCH" >&2; exit "$RC"; fi
      ID="$(luna_orch_extract_bg_id "$LAUNCH" || true)"
      [[ -n "$ID" ]] || { echo "ERROR: could not parse reviewer-$n background ID" >&2; cat "$LAUNCH" >&2; exit 4; }
      printf '%s\n' "$ID" > "$D/job_id"
      printf '%s\n' "$SEED_ID" > "$D/parent_job_id"
      printf '%s\n' "$SEED_SESSION_ID" > "$D/parent_session_id"
      printf 'REVIEWER_%s_JOB_ID=%s\n' "$n" "$ID"
    done
    printf 'reviewers_running\n' > "$GROUP/stage"
    ;;

  dual-collect)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$1"
    for n in 1 2; do
      [[ -f "$GROUP/reviewer-$n/job_id" ]] || { echo "ERROR: reviewer forks not launched; run dual-advance after seed completes." >&2; exit 2; }
    done
    FAIL=0
    printf 'reviewer\tstate\tjob_id\tresult\n' > "$GROUP/manifest.tsv"
    for n in 1 2; do
      D="$GROUP/reviewer-$n"; ID="$(cat "$D/job_id")"; REC="$(luna_orch_bg_record "$ID")"; STATE="${REC%%$'\t'*}"; STATUS="${REC#*$'\t'}"
      case "$STATE" in
        done|completed)
          luna_orch_store_session_id "$D" >/dev/null 2>&1 || true
          luna_orch_bg_logs "$ID" "$D/result.txt"
          [[ -f "$D/initial-result.txt" ]] || cp "$D/result.txt" "$D/initial-result.txt"
          printf 'reviewer-%s\t%s\t%s\t%s\n' "$n" "$STATE" "$ID" "$D/result.txt" >> "$GROUP/manifest.tsv"
          ;;
        working|idle) echo "NOT_READY: reviewer-$n $ID is $STATE. $STATUS" >&2; FAIL=10 ;;
        blocked|needs_input|needs-input) echo "BLOCKED: reviewer-$n $ID. $STATUS" >&2; claude logs "$ID" >&2 || true; FAIL=11 ;;
        failed) echo "FAILED: reviewer-$n $ID. $STATUS" >&2; claude logs "$ID" >&2 || true; FAIL=12 ;;
        stopped) echo "STOPPED: reviewer-$n $ID." >&2; FAIL=13 ;;
        *) echo "UNKNOWN: reviewer-$n $ID." >&2; FAIL=14 ;;
      esac
    done
    if (( FAIL != 0 )); then exit "$FAIL"; fi
    printf 'done\n' > "$GROUP/stage"
    cat "$GROUP/manifest.tsv"
    echo "--- Reviewer 1 ---"; cat "$GROUP/reviewer-1/result.txt"
    echo "--- Reviewer 2 ---"; cat "$GROUP/reviewer-2/result.txt"
    ;;

  *) usage >&2; exit 2 ;;
esac
