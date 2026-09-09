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
  claude-review.sh retry        STATE_DIR
  claude-review.sh resume       STATE_DIR FIX_DELTA

  claude-review.sh dual-start   REVIEW_PACKET [GROUP_DIR]
  claude-review.sh dual-status  GROUP_DIR
  claude-review.sh dual-advance GROUP_DIR
  claude-review.sh dual-collect GROUP_DIR

Claude is run synchronously in the foreground with `claude -p`; no Claude
daemon/background job is used. Ordinary `start` creates a persistent session
ID and `resume` continues that session. Dual review calls remain independent
and non-persistent. Network/API failures are recorded as `stage=blocked`, so
`retry` can re-use the same state and session after network access is restored.
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
EFFORT="${LUNA_PRIMARY_ENGINEER_CLAUDE_REVIEW_EFFORT:-xhigh}"
SYSTEM_PROMPT="$ROOT_DIR/references/claude/reviewer-system.md"
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
)

run_foreground() {
  local output="$1" exit_file="$2" add_dir="$3" prompt="$4"
  shift 4
  mkdir -p "$(dirname "$output")"
  luna_primary_engineer_run_foreground "$output" "$exit_file" "${base_args[@]}" "$@" --add-dir "$add_dir" -- "$prompt"
}

show_result() {
  local state_dir="$1"
  [[ -f "$state_dir/result.txt" ]] || { echo "ERROR: missing result: $state_dir/result.txt" >&2; return 2; }
  cat "$state_dir/result.txt"
}

collect_review() {
  local state_dir="$1" stage
  stage="$(cat "$state_dir/stage" 2>/dev/null || true)"
  if [[ "$stage" == blocked ]]; then
    echo "ERROR: review is blocked by the network/API path; use retry on the same state: $state_dir" >&2
    return 11
  fi
  [[ "$stage" == "done" ]] || { echo "ERROR: review is not complete: $state_dir (stage=${stage:-unknown})" >&2; return 10; }
  if ! luna_primary_engineer_review_contract_complete "$state_dir/result.txt"; then
    echo "ERROR: review result lacks the complete review contract." >&2
    return 18
  fi
  cat "$state_dir/result.txt"
}

run_review() {
  local state_dir="$1" prompt="$2" add_dir="$3" rc=0
  shift 3
  rm -f "$state_dir/blocked_reason"
  printf 'running\n' > "$state_dir/stage"
  if run_foreground "$state_dir/result.txt" "$state_dir/run_exit_code" "$add_dir" "$prompt" "$@"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc != 0 )); then
    if luna_primary_engineer_review_network_failure "$state_dir/result.txt"; then
      printf 'blocked\n' > "$state_dir/stage"
      printf 'network\n' > "$state_dir/blocked_reason"
      echo "ERROR: Claude review reached a network/API timeout after launch; this is not a code-review failure and no Luna fallback is allowed." >&2
      echo "ERROR: Re-run the same state with network-enabled command execution: bash scripts/claude-review.sh retry $state_dir" >&2
      cat "$state_dir/result.txt" >&2 || true
      return 11
    fi
    printf 'failed\n' > "$state_dir/stage"
    echo "ERROR: Claude review failed after launch; this is not a preflight fallback condition. Inspect the state and wait for an explicit decision." >&2
    cat "$state_dir/result.txt" >&2 || true
    return "$rc"
  fi
  if ! luna_primary_engineer_review_contract_complete "$state_dir/result.txt"; then
    if luna_primary_engineer_review_network_failure "$state_dir/result.txt"; then
      printf 'blocked\n' > "$state_dir/stage"
      printf 'network\n' > "$state_dir/blocked_reason"
      echo "ERROR: Claude review output shows a network/API timeout; preserve this state and retry it with network access." >&2
      return 11
    fi
    printf 'failed\n' > "$state_dir/stage"
    echo "ERROR: Claude completed but did not return the complete review contract." >&2
    cat "$state_dir/result.txt" >&2 || true
    return 18
  fi
  printf 'done\n' > "$state_dir/stage"
}

retry_initial_review() {
  local state_dir="$1" parent_stage session_id packet_abs review_cwd retry_dir n rc
  parent_stage="$(cat "$state_dir/stage" 2>/dev/null || true)"
  if [[ "$parent_stage" == failed && ! -f "$state_dir/current_round" ]] && \
    luna_primary_engineer_review_network_failure "$state_dir/result.txt"; then
    # Make states produced by older helper versions retryable without asking
    # the caller to edit their state directory by hand.
    printf 'blocked\n' > "$state_dir/stage"
    printf 'network\n' > "$state_dir/blocked_reason"
    parent_stage=blocked
  fi
  [[ "$parent_stage" == blocked && "$(cat "$state_dir/blocked_reason" 2>/dev/null || true)" == network ]] || {
    echo "ERROR: only a network-blocked initial review can use retry: $state_dir" >&2
    return 10
  }
  [[ ! -f "$state_dir/current_round" ]] || {
    echo "ERROR: this is a blocked re-review; rerun resume with the same fix delta: $state_dir" >&2
    return 10
  }
  session_id="$(cat "$state_dir/session_id" 2>/dev/null || true)"
  [[ "$session_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || {
    echo "ERROR: review state has no resumable Claude session ID: $state_dir" >&2
    return 2
  }
  packet_abs="$(cat "$state_dir/packet_path" 2>/dev/null || true)"
  [[ -f "$packet_abs" ]] || { echo "ERROR: original review packet not found: $packet_abs" >&2; return 2; }
  review_cwd="$(cat "$state_dir/cwd" 2>/dev/null || true)"
  [[ -d "$review_cwd" ]] || { echo "ERROR: original review directory is unavailable: $review_cwd" >&2; return 2; }

  n=1
  while [[ -e "$state_dir/network-retry-$n" ]]; do n=$((n + 1)); done
  retry_dir="$state_dir/network-retry-$n"
  mkdir -p "$retry_dir"
  [[ -f "$state_dir/result.txt" ]] && cp "$state_dir/result.txt" "$retry_dir/previous-result.txt"
  printf '%s\n' "$session_id" > "$retry_dir/session_id"
  printf '%s\n' "$packet_abs" > "$retry_dir/packet_path"

  if (cd "$review_cwd" && run_review "$state_dir" \
    "Retry this same read-only review in the existing Claude conversation after a transient network failure. Read the review packet at: $packet_abs . Inspect repository files only as needed. Do not ask questions; finish with the complete review contract from your system instructions." \
    "$state_dir" --resume "$session_id"); then
    printf 'done\n' > "$state_dir/stage"
    cat "$state_dir/result.txt"
    return 0
  else
    rc=$?
    printf '%s\n' "$rc" > "$retry_dir/run_exit_code"
    [[ -f "$state_dir/result.txt" ]] && cp "$state_dir/result.txt" "$retry_dir/result.txt"
    return "$rc"
  fi
}

case "$MODE" in
  start)
    require_claude
    [[ $# -ge 1 && $# -le 3 ]] || { usage >&2; exit 2; }
    PACKET="$1"
    STATE_DIR="${2:-$(luna_primary_engineer_runtime_dir)-review}"
    LABEL="${3:-reviewer-1}"
    [[ -f "$PACKET" ]] || { echo "ERROR: packet not found: $PACKET" >&2; exit 2; }
    luna_primary_engineer_require_fresh_state_dir "$STATE_DIR" || exit $?
    mkdir -p "$STATE_DIR"
    SESSION_ID="$(luna_primary_engineer_new_session_id)" || exit 1
    cp "$PACKET" "$STATE_DIR/review-packet.md"
    PACKET_ABS="$(cd "$STATE_DIR" && pwd)/review-packet.md"
    printf '%s\n' "$LABEL" > "$STATE_DIR/label"
    printf 'single-review\n' > "$STATE_DIR/kind"
    printf '%s\n' "$PWD" > "$STATE_DIR/cwd"
    printf '%s\n' "$SESSION_ID" > "$STATE_DIR/session_id"
    printf '%s\n' "$PACKET_ABS" > "$STATE_DIR/packet_path"
    run_review "$STATE_DIR" \
      "This is a synchronous read-only review. Read the review packet at: $PACKET_ABS . Inspect repository files only as needed. Do not ask the Primary Engineer questions; if evidence is incomplete, record the uncertainty and finish. Return the complete review contract from your system instructions." \
      "$STATE_DIR" --session-id "$SESSION_ID"
    show_result "$STATE_DIR"
    ;;

  status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    luna_primary_engineer_print_state_dir "$1"
    ;;

  collect)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    collect_review "$1"
    ;;

  retry)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    STATE_INPUT="$1"
    [[ -d "$STATE_INPUT" ]] || { echo "ERROR: review state directory not found: $STATE_INPUT" >&2; exit 2; }
    retry_initial_review "$(cd "$STATE_INPUT" && pwd)"
    ;;

  resume)
    require_claude
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    STATE_INPUT="$1"
    DELTA="$2"
    [[ -d "$STATE_INPUT" ]] || {
      echo "ERROR: foreground review state directory not found: $STATE_INPUT" >&2
      exit 2
    }
    STATE_DIR="$(cd "$STATE_INPUT" && pwd)" || {
      echo "ERROR: cannot resolve foreground review state directory: $STATE_INPUT" >&2
      exit 2
    }
    PARENT_STAGE="$(cat "$STATE_DIR/stage" 2>/dev/null || true)"
    LEGACY_ROUND="$(cat "$STATE_DIR/current_round" 2>/dev/null || true)"
    if [[ "$PARENT_STAGE" == failed && "$LEGACY_ROUND" == rereview-* ]] && \
      luna_primary_engineer_review_network_failure "$STATE_DIR/$LEGACY_ROUND/result.txt"; then
      # Older foreground runs marked transport failures as failed. Migrate only
      # that recognizable network case, preserving the same re-review round.
      printf 'blocked\n' > "$STATE_DIR/stage"
      printf 'network\n' > "$STATE_DIR/blocked_reason"
      printf 'blocked\n' > "$STATE_DIR/$LEGACY_ROUND/stage"
      printf 'network\n' > "$STATE_DIR/$LEGACY_ROUND/blocked_reason"
      PARENT_STAGE=blocked
    fi
    [[ -f "$STATE_DIR/result.txt" && ( "$PARENT_STAGE" == "done" || "$PARENT_STAGE" == "failed" || "$PARENT_STAGE" == "blocked" ) ]] || {
      echo "ERROR: completed review or retryable blocked review not found: $STATE_DIR" >&2
      exit 10
    }
    if [[ "$PARENT_STAGE" == "failed" ]]; then
      FAILED_ROUND="$(cat "$STATE_DIR/current_round" 2>/dev/null || true)"
      [[ "$FAILED_ROUND" == rereview-* && "$(cat "$STATE_DIR/$FAILED_ROUND/stage" 2>/dev/null || true)" == "failed" ]] || {
        echo "ERROR: failed re-review state is not retryable: $STATE_DIR" >&2
        exit 10
      }
    fi
    if [[ "$PARENT_STAGE" == "blocked" ]]; then
      BLOCKED_ROUND="$(cat "$STATE_DIR/current_round" 2>/dev/null || true)"
      [[ "$BLOCKED_ROUND" == rereview-* && "$(cat "$STATE_DIR/$BLOCKED_ROUND/stage" 2>/dev/null || true)" == "blocked" && "$(cat "$STATE_DIR/$BLOCKED_ROUND/blocked_reason" 2>/dev/null || true)" == "network" ]] || {
        echo "ERROR: blocked initial review must use retry; blocked re-review state is not retryable: $STATE_DIR" >&2
        exit 10
      }
    fi
    [[ -f "$DELTA" ]] || { echo "ERROR: delta not found: $DELTA" >&2; exit 2; }
    PACKET_ABS="$(cat "$STATE_DIR/packet_path" 2>/dev/null || true)"
    [[ -f "$PACKET_ABS" ]] || { echo "ERROR: original review packet not found: $PACKET_ABS" >&2; exit 2; }
    SESSION_ID="$(cat "$STATE_DIR/session_id" 2>/dev/null || true)"
    [[ "$SESSION_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || {
      echo "ERROR: review state has no resumable Claude session ID: $STATE_DIR" >&2
      exit 2
    }
    REVIEW_CWD="$(cat "$STATE_DIR/cwd" 2>/dev/null || true)"
    [[ -d "$REVIEW_CWD" ]] || { echo "ERROR: original review directory is unavailable: $REVIEW_CWD" >&2; exit 2; }

    if [[ "$PARENT_STAGE" == "blocked" ]]; then
      N="${BLOCKED_ROUND#rereview-}"
      ROUND="$STATE_DIR/$BLOCKED_ROUND"
      cp "$DELTA" "$ROUND/fix-delta.md"
    else
      N=1
      while [[ -e "$STATE_DIR/rereview-$N" ]]; do N=$((N + 1)); done
      ROUND="$STATE_DIR/rereview-$N"
      mkdir -p "$ROUND"
      cp "$DELTA" "$ROUND/fix-delta.md"
      cp "$STATE_DIR/result.txt" "$ROUND/previous-result.txt"
      printf '%s\n' "$PACKET_ABS" > "$ROUND/packet_path"
      printf '%s\n' "$SESSION_ID" > "$ROUND/session_id"
      printf 'rereview-%s\n' "$N" > "$STATE_DIR/current_round"
    fi
    DELTA_ABS="$(cd "$ROUND" && pwd)/fix-delta.md"
    PREVIOUS_ABS="$ROUND/previous-result.txt"
    printf 'running\n' > "$STATE_DIR/stage"
    if (cd "$REVIEW_CWD" && run_review "$ROUND" \
      "This is a sticky synchronous re-review in the same Claude conversation. Read the original review packet at: $PACKET_ABS , the previous review result at: $PREVIOUS_ABS , and the Primary's fix delta at: $DELTA_ABS . Re-check each relevant finding from the previous review, inspect regressions introduced by the fixes, and return the complete review contract. Do not ask questions; finish with the evidence available." \
      "$STATE_DIR" --resume "$SESSION_ID"); then
      :
    else
      resume_rc=$?
      if [[ -f "$ROUND/run_exit_code" ]]; then
        cp "$ROUND/run_exit_code" "$STATE_DIR/run_exit_code"
      else
        printf '%s\n' "$resume_rc" > "$STATE_DIR/run_exit_code"
      fi
      if [[ "$(cat "$ROUND/stage" 2>/dev/null || true)" == blocked ]]; then
        printf 'network\n' > "$ROUND/blocked_reason"
        printf 'network\n' > "$STATE_DIR/blocked_reason"
        printf 'blocked\n' > "$STATE_DIR/stage"
      else
        printf 'failed\n' > "$ROUND/stage"
        printf 'failed\n' > "$STATE_DIR/stage"
      fi
      exit "$resume_rc"
    fi
    cp "$ROUND/result.txt" "$STATE_DIR/result.txt"
    cp "$ROUND/run_exit_code" "$STATE_DIR/run_exit_code"
    rm -f "$STATE_DIR/blocked_reason"
    printf 'done\n' > "$STATE_DIR/stage"
    show_result "$STATE_DIR"
    ;;

  dual-start)
    require_claude
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    PACKET="$1"
    GROUP="${2:-$(luna_primary_engineer_runtime_dir)-dual-review}"
    [[ -f "$PACKET" ]] || { echo "ERROR: packet not found: $PACKET" >&2; exit 2; }
    luna_primary_engineer_require_fresh_state_tree "$GROUP" || exit $?
    mkdir -p "$GROUP/seed" "$GROUP/reviewer-1" "$GROUP/reviewer-2"
    cp "$PACKET" "$GROUP/review-packet.md"
    PACKET_ABS="$(cd "$GROUP" && pwd)/review-packet.md"
    printf '%s\n' "$PWD" > "$GROUP/cwd"
    printf 'dual-review\n' > "$GROUP/kind"
    printf 'seed_running\n' > "$GROUP/stage"
    printf 'running\n' > "$GROUP/seed/stage"
    printf '%s\n' "$PACKET_ABS" > "$GROUP/seed/packet_path"
    if run_foreground "$GROUP/seed/result.txt" "$GROUP/seed/run_exit_code" "$GROUP" \
      "LUNA_PRIMARY_ENGINEER_SHARED_SEED_MODE. This is a foreground factual-context load. Read the review packet at: $PACKET_ABS . Load it as shared factual context only. Do not evaluate correctness, identify defects, rank risks, or propose fixes. Do not ask questions. Reply exactly SEED_READY when loaded." --no-session-persistence; then
      :
    else
      printf 'failed\n' > "$GROUP/seed/stage"
      printf 'failed\n' > "$GROUP/stage"
      cat "$GROUP/seed/result.txt" >&2 || true
      exit "$(cat "$GROUP/seed/run_exit_code")"
    fi
    if ! grep -Fq 'SEED_READY' "$GROUP/seed/result.txt"; then
      printf 'failed\n' > "$GROUP/seed/stage"
      printf 'failed\n' > "$GROUP/stage"
      echo "ERROR: foreground seed did not return SEED_READY." >&2
      cat "$GROUP/seed/result.txt" >&2 || true
      exit 18
    fi
    printf 'done\n' > "$GROUP/seed/stage"
    printf 'seed_done\n' > "$GROUP/stage"
    printf 'SEED_READY\nGROUP_DIR=%s\nNEXT=run dual-advance for the two foreground reviewers\n' "$GROUP"
    ;;

  dual-status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$1"
    [[ -d "$GROUP" ]] || { echo "ERROR: invalid dual group: $GROUP" >&2; exit 2; }
    echo "STAGE=$(cat "$GROUP/stage" 2>/dev/null || echo unknown)"
    echo "[seed]"
    luna_primary_engineer_print_state_dir "$GROUP/seed" || true
    for n in 1 2; do
      if [[ -d "$GROUP/reviewer-$n" ]]; then
        echo "[reviewer-$n]"
        luna_primary_engineer_print_state_dir "$GROUP/reviewer-$n" || true
      fi
    done
    ;;

  dual-advance)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$1"
    [[ -f "$GROUP/seed/result.txt" && "$(cat "$GROUP/stage" 2>/dev/null || true)" == "seed_done" ]] || {
      echo "ERROR: foreground seed is not complete: $GROUP" >&2
      exit 10
    }
    if [[ -f "$GROUP/reviewer-1/result.txt" || -f "$GROUP/reviewer-2/result.txt" ]]; then
      if [[ ! -f "$GROUP/reviewer-1/result.txt" || ! -f "$GROUP/reviewer-2/result.txt" ]]; then
        echo "ERROR: dual review is partially complete; inspect results before rerunning." >&2
        exit 15
      fi
      echo "INFO: both foreground reviewers already ran; no action taken."
      exit 0
    fi
    PACKET_ABS="$(cat "$GROUP/seed/packet_path")"
    SEED_ABS="$(cd "$GROUP/seed" && pwd)/result.txt"
    FAIL=0
    for n in 1 2; do
      D="$GROUP/reviewer-$n"
      printf '%s\n' "$PACKET_ABS" > "$D/packet_path"
      printf 'running\n' > "$D/stage"
      if run_foreground "$D/result.txt" "$D/run_exit_code" "$GROUP" \
        "You are Reviewer $n, an independent foreground reviewer. Read the factual review packet at: $PACKET_ABS and the neutral seed result at: $SEED_ABS . Analyze the change independently from your role. Do not seek consensus with a hypothetical peer. Do not ask questions; record uncertainty and finish. Return the complete review contract from your system instructions." --no-session-persistence; then
        if luna_primary_engineer_review_contract_complete "$D/result.txt"; then
          printf 'done\n' > "$D/stage"
          cp "$D/result.txt" "$D/initial-result.txt"
        else
          printf 'failed\n' > "$D/stage"
          echo "ERROR: reviewer-$n did not return the complete review contract." >&2
          FAIL=18
        fi
      else
        printf 'failed\n' > "$D/stage"
        echo "ERROR: reviewer-$n foreground Claude call failed." >&2
        FAIL="$(cat "$D/run_exit_code")"
      fi
    done
    if (( FAIL != 0 )); then
      printf 'failed\n' > "$GROUP/stage"
      exit "$FAIL"
    fi
    printf 'done\n' > "$GROUP/stage"
    "$0" dual-collect "$GROUP"
    ;;

  dual-collect)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$1"
    [[ -f "$GROUP/reviewer-1/result.txt" && -f "$GROUP/reviewer-2/result.txt" ]] || {
      echo "ERROR: both foreground reviewers must finish before collection." >&2
      exit 10
    }
    for n in 1 2; do
      if ! luna_primary_engineer_review_contract_complete "$GROUP/reviewer-$n/result.txt"; then
        echo "ERROR: reviewer-$n result lacks the complete review contract." >&2
        exit 18
      fi
    done
    printf 'reviewer\tstate\tresult\n' > "$GROUP/manifest.tsv"
    printf 'reviewer-1\tdone\t%s\n' "$GROUP/reviewer-1/result.txt" >> "$GROUP/manifest.tsv"
    printf 'reviewer-2\tdone\t%s\n' "$GROUP/reviewer-2/result.txt" >> "$GROUP/manifest.tsv"
    cat "$GROUP/manifest.tsv"
    echo "--- Reviewer 1 ---"; cat "$GROUP/reviewer-1/result.txt"
    echo "--- Reviewer 2 ---"; cat "$GROUP/reviewer-2/result.txt"
    ;;

  *) usage >&2; exit 2 ;;
esac
