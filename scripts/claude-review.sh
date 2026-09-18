#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/claude-review.sh"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

usage() {
  cat <<'TXT'
Usage:
  claude-review.sh start             REVIEW_PACKET [STATE_DIR] [LABEL]
  claude-review.sh start-background  REVIEW_PACKET [STATE_DIR] [LABEL]
  claude-review.sh status            STATE_DIR
  claude-review.sh collect           STATE_DIR
  claude-review.sh retry             STATE_DIR
  claude-review.sh resume            STATE_DIR FIX_DELTA
  claude-review.sh resume-background STATE_DIR FIX_DELTA

  claude-review.sh dual-start        REVIEW_PACKET [GROUP_DIR]
  claude-review.sh dual-status       GROUP_DIR
  claude-review.sh dual-advance      GROUP_DIR
  claude-review.sh dual-collect      GROUP_DIR

`start` and `resume` are synchronous foreground operations. The explicit
`*-background` forms detach this wrapper, retain the Claude process and state,
and are inspected with `status`; they do not use the Claude daemon. Every
review consumes Claude usage. No retry or duplicate review is automatic.

All review state is below the current Git worktree's tmp/luna-primary-engineer/
reviews directory. An explicit STATE_DIR/GROUP_DIR must be one direct child of
that workspace; existing contents are never recursively removed.
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
HANDOFF_MODE=""

build_base_args() {
  local result_file="$1" handoff_mode="$2"
  local tools="Read,Glob,Grep"
  if [[ "$handoff_mode" == file ]]; then tools="$tools,Write"; fi
  BASE_ARGS=(
    --print
    --model "$MODEL"
    --effort "$EFFORT"
    --permission-mode dontAsk
    --permission-prompts none
    --tools "$tools"
  )
  if [[ "$handoff_mode" == file ]]; then
    # Claude Code's file permission grammar uses Edit(path) to scope all file
    # editing tools, including Write. Keep Write in the tool surface so Claude
    # can create the designated file, but do not expose generic Edit/Bash/MCP.
    BASE_ARGS+=(
      # Claude Code file rules use a doubled leading slash for an absolute
      # filesystem path. result_file is already absolute, so the extra slash
      # is intentional: Edit(//home/.../reviewer-result.md).
      --allowedTools "Edit(/$result_file)"
      --disallowedTools Bash "mcp__*"
    )
  else
    # This mode is used when the installed Claude CLI cannot expose a reliable
    # path-scoped file rule. The framed stdout handoff is parsed by the
    # wrapper; the tool allowlist keeps all write-capable tools unavailable.
    BASE_ARGS+=(--disallowedTools Bash "mcp__*")
  fi
  BASE_ARGS+=(
    --append-system-prompt "$SYSTEM_PROMPT_TEXT"
    --disable-slash-commands
    --no-chrome
  )
}

result_instruction() {
  local result_file="$1" handoff_mode="$2"
  if [[ "$handoff_mode" == file ]]; then
    cat <<EOF
Write the complete review artifact to this exact absolute path: $result_file
This is the only file you may write. Do not edit source/, tests/, docs/, any
configuration, the packet, state metadata, diagnostics, or any other path.
The wrapper will validate this file after Claude exits. stdout may be empty.
EOF
  else
    cat <<'EOF'
The available tools are read-only. Do not edit or create any file. At the very
end emit the complete requested artifact between the exact lines
LUNA_RESULT_BEGIN and LUNA_RESULT_END. The wrapper will validate and adopt
that framed handoff into the designated result file; ordinary stdout is not a
review result.
EOF
  fi
}

run_foreground() {
  local result_file="$1" stdout_file="$2" stderr_file="$3" exit_file="$4"
  local add_dir="$5" prompt="$6"
  shift 6
  build_base_args "$result_file" "$HANDOFF_MODE"
  prompt="$prompt

$(result_instruction "$result_file" "$HANDOFF_MODE")"
  mkdir -p "$(dirname "$result_file")" "$(dirname "$stdout_file")" "$(dirname "$stderr_file")" "$(dirname "$exit_file")"
  luna_primary_engineer_run_foreground \
    "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "$HANDOFF_MODE" \
    "${BASE_ARGS[@]}" "$@" --add-dir "$add_dir" -- "$prompt"
}

next_child_dir() {
  local parent="$1" prefix="$2" n=1 candidate
  while :; do
    candidate="$parent/$prefix-$n"
    if [[ ! -e "$candidate" ]]; then
      (umask 077 && mkdir "$candidate")
      printf '%s\n' "$candidate"
      return 0
    fi
    n=$((n + 1))
  done
}

report_run_failure() {
  local state_dir="$1" attempt_dir="$2" result_file="$3" stdout_file="$4" stderr_file="$5" exit_file="$6" reason="$7"
  luna_primary_engineer_report_technical_failure \
    "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "$reason"
}

run_review() {
  local state_dir="$1" prompt="$2" add_dir="$3" result_kind="$4" review_cwd="$5" rc=0
  local attempt_dir result_file stdout_file stderr_file exit_file before after
  shift 5
  attempt_dir="$(next_child_dir "$state_dir" attempt)"
  result_file="$attempt_dir/reviewer-result.md"
  stdout_file="$attempt_dir/stdout.txt"
  stderr_file="$attempt_dir/stderr.txt"
  exit_file="$attempt_dir/exit_code"
  printf '%s\n' "$attempt_dir" > "$state_dir/last_attempt"
  printf 'running\n' > "$state_dir/stage"
  rm -f "$state_dir/blocked_reason"

  before="$attempt_dir/repository-before.txt"
  after="$attempt_dir/repository-after.txt"
  luna_primary_engineer_capture_repo_scope "$review_cwd" "$before"
  if run_foreground "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "$add_dir" "$prompt" "$@"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$HANDOFF_MODE" == stdout && ! -s "$result_file" ]]; then
    luna_primary_engineer_materialize_stdout_result "$stdout_file" "$result_file" || true
  fi
  luna_primary_engineer_capture_repo_scope "$review_cwd" "$after"
  cp -- "$exit_file" "$state_dir/run_exit_code"

  if ! cmp -s "$before" "$after"; then
    printf 'failed\n' > "$state_dir/stage"
    report_run_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "reviewer write escaped the read-only implementation boundary"
    return 19
  fi

  if (( rc != 0 )); then
    if luna_primary_engineer_review_network_failure "$stdout_file" "$stderr_file"; then
      printf 'blocked\n' > "$state_dir/stage"
      printf 'network\n' > "$state_dir/blocked_reason"
      report_run_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "Claude transport/API failure"
      echo "ERROR: preserve this state; retry only after explicit approval and network recovery." >&2
      return 11
    fi
    printf 'failed\n' > "$state_dir/stage"
    report_run_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "Claude exited non-zero"
    return "$rc"
  fi

  case "$result_kind" in
    review)
      if ! luna_primary_engineer_review_contract_complete "$result_file"; then
        printf 'failed\n' > "$state_dir/stage"
        report_run_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "review contract is missing or incomplete"
        return 18
      fi
      ;;
    seed)
      if ! grep -Fqx 'SEED_READY' "$result_file"; then
        printf 'failed\n' > "$state_dir/stage"
        report_run_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "seed artifact is not exactly SEED_READY"
        return 18
      fi
      ;;
    artifact)
      if [[ ! -s "$result_file" ]]; then
        printf 'failed\n' > "$state_dir/stage"
        report_run_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "panel artifact is empty"
        return 18
      fi
      ;;
    *)
      echo "ERROR: unknown review result kind: $result_kind" >&2
      return 2
      ;;
  esac

  luna_primary_engineer_adopt_result "$result_file" "$state_dir/result.txt" || {
    printf 'failed\n' > "$state_dir/stage"
    report_run_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "designated result could not be adopted"
    return 18
  }
  printf 'done\n' > "$state_dir/stage"
}

show_result() {
  local state_dir="$1"
  [[ -f "$state_dir/result.txt" ]] || { echo "ERROR: missing adopted result: $state_dir/result.txt" >&2; return 2; }
  cat "$state_dir/result.txt"
}

collect_review() {
  local state_dir="$1" stage
  stage="$(cat "$state_dir/stage" 2>/dev/null || true)"
  if [[ "$stage" == blocked ]]; then
    echo "ERROR: review is blocked by the network/API path; use explicit retry on the same state: $state_dir" >&2
    return 11
  fi
  [[ "$stage" == done ]] || { echo "ERROR: review is not complete: $state_dir (stage=${stage:-unknown})" >&2; return 10; }
  if ! luna_primary_engineer_review_contract_complete "$state_dir/result.txt"; then
    echo "ERROR: adopted review result lacks the complete review contract; inspect the stored diagnostics." >&2
    return 18
  fi
  cat "$state_dir/result.txt"
}

initialize_single_review() {
  local packet="$1" requested_state="$2" label="$3"
  [[ -f "$packet" ]] || { echo "ERROR: packet not found: $packet" >&2; return 2; }
  STATE_DIR="$(luna_primary_engineer_prepare_review_dir "$requested_state")" || return
  luna_primary_engineer_require_fresh_state_dir "$STATE_DIR" || return
  SESSION_ID="$(luna_primary_engineer_new_session_id)" || return 1
  HANDOFF_MODE="$(luna_primary_engineer_result_handoff_mode)" || return
  cp -- "$packet" "$STATE_DIR/review-packet.md"
  PACKET_ABS="$(cd "$STATE_DIR" && pwd -P)/review-packet.md"
  printf '%s\n' "$label" > "$STATE_DIR/label"
  printf 'single-review\n' > "$STATE_DIR/kind"
  printf '%s\n' "$(pwd -P)" > "$STATE_DIR/cwd"
  printf '%s\n' "$SESSION_ID" > "$STATE_DIR/session_id"
  printf '%s\n' "$PACKET_ABS" > "$STATE_DIR/packet_path"
  printf '%s\n' "$HANDOFF_MODE" > "$STATE_DIR/handoff_mode"
  printf 'queued\n' > "$STATE_DIR/stage"
}

single_prompt() {
  local packet_abs="$1"
  printf '%s' "This is a synchronous read-only review. Read the review packet at: $packet_abs . Inspect repository files only as needed. Do not ask the Primary Engineer questions; if evidence is incomplete, record the uncertainty and finish with the complete review contract."
}

run_single_review() {
  local state_dir="$1" prompt packet_abs session_id review_cwd
  state_dir="$(luna_primary_engineer_resolve_existing_review_dir "$state_dir")" || return
  packet_abs="$(cat "$state_dir/packet_path" 2>/dev/null || true)"
  session_id="$(cat "$state_dir/session_id" 2>/dev/null || true)"
  review_cwd="$(cat "$state_dir/cwd" 2>/dev/null || true)"
  [[ -f "$packet_abs" && -d "$review_cwd" ]] || { echo "ERROR: review state metadata is incomplete: $state_dir" >&2; return 2; }
  [[ "$session_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { echo "ERROR: invalid Claude session ID in $state_dir" >&2; return 2; }
  HANDOFF_MODE="$(cat "$state_dir/handoff_mode" 2>/dev/null || luna_primary_engineer_result_handoff_mode)" || return
  prompt="$(single_prompt "$packet_abs")"
  (cd "$review_cwd" && run_review "$state_dir" "$prompt" "$state_dir" review "$review_cwd" --session-id "$session_id")
}

launch_background() {
  local state_dir="$1" kind="$2" pid previous_stage
  shift 2
  if [[ -f "$state_dir/background_pid" ]]; then
    local old_pid
    old_pid="$(cat "$state_dir/background_pid" 2>/dev/null || true)"
    if [[ "$old_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$old_pid" 2>/dev/null; then
      echo "ERROR: a background operation is already attached to this state: $state_dir" >&2
      return 15
    fi
  fi
  previous_stage="$(cat "$state_dir/stage" 2>/dev/null || true)"
  printf '%s\n' "$previous_stage" > "$state_dir/background_parent_stage"
  printf '%s\n' "$kind" > "$state_dir/background_kind"
  printf 'queued\n' > "$state_dir/stage"
  nohup bash "$SCRIPT_PATH" "$@" >"$state_dir/background.log" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$state_dir/background_pid"
  printf 'BACKGROUND_PID=%s\nSTATE_DIR=%s\n' "$pid" "$state_dir"
}

retry_initial_review() {
  local state_dir="$1" parent_stage session_id packet_abs review_cwd retry_dir n rc
  parent_stage="$(cat "$state_dir/stage" 2>/dev/null || true)"
  if [[ "$parent_stage" == failed && ! -f "$state_dir/current_round" ]] && \
    luna_primary_engineer_review_network_failure "$state_dir/result.txt" "$state_dir/stdout.txt" "$state_dir/stderr.txt"; then
    printf 'blocked\n' > "$state_dir/stage"
    printf 'network\n' > "$state_dir/blocked_reason"
    parent_stage=blocked
  fi
  [[ "$parent_stage" == blocked && "$(cat "$state_dir/blocked_reason" 2>/dev/null || true)" == network ]] || {
    echo "ERROR: only an explicitly network-blocked initial review can use retry: $state_dir" >&2
    return 10
  }
  [[ ! -f "$state_dir/current_round" ]] || {
    echo "ERROR: this is a blocked re-review; rerun resume with the same fix delta: $state_dir" >&2
    return 10
  }
  session_id="$(cat "$state_dir/session_id" 2>/dev/null || true)"
  packet_abs="$(cat "$state_dir/packet_path" 2>/dev/null || true)"
  review_cwd="$(cat "$state_dir/cwd" 2>/dev/null || true)"
  [[ "$session_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { echo "ERROR: review state has no resumable Claude session ID: $state_dir" >&2; return 2; }
  [[ -f "$packet_abs" && -d "$review_cwd" ]] || { echo "ERROR: original review inputs are unavailable: $state_dir" >&2; return 2; }
  n=1
  while [[ -e "$state_dir/network-retry-$n" ]]; do n=$((n + 1)); done
  retry_dir="$state_dir/network-retry-$n"
  (umask 077 && mkdir "$retry_dir")
  printf '%s\n' "$session_id" > "$retry_dir/session_id"
  printf '%s\n' "$packet_abs" > "$retry_dir/packet_path"
  HANDOFF_MODE="$(cat "$state_dir/handoff_mode" 2>/dev/null || luna_primary_engineer_result_handoff_mode)" || return
  if (cd "$review_cwd" && run_review "$state_dir" \
    "Retry this same read-only review in the existing Claude conversation after the caller explicitly approved a retry. Read the review packet at: $packet_abs . Do not edit repository files; finish with the complete review contract." \
    "$state_dir" review "$review_cwd" --resume "$session_id"); then
    cat "$state_dir/result.txt"
    return 0
  else
    rc=$?
    printf '%s\n' "$rc" > "$retry_dir/run_exit_code"
    return "$rc"
  fi
}

case "$MODE" in
  start)
    require_claude
    [[ $# -ge 1 && $# -le 3 ]] || { usage >&2; exit 2; }
    initialize_single_review "$1" "${2:-}" "${3:-reviewer-1}"
    run_single_review "$STATE_DIR"
    show_result "$STATE_DIR"
    ;;

  start-background)
    require_claude
    [[ $# -ge 1 && $# -le 3 ]] || { usage >&2; exit 2; }
    initialize_single_review "$1" "${2:-}" "${3:-reviewer-1}"
    launch_background "$STATE_DIR" initial background-run "$STATE_DIR"
    ;;

  background-run)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    run_single_review "$1"
    ;;

  status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    STATE_DIR="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    luna_primary_engineer_print_state_dir "$STATE_DIR"
    ;;

  collect)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    STATE_DIR="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    collect_review "$STATE_DIR"
    ;;

  retry)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    STATE_DIR="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    retry_initial_review "$STATE_DIR"
    ;;

  resume|resume-background)
    require_claude
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    STATE_DIR="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    DELTA="$2"
    [[ -f "$DELTA" ]] || { echo "ERROR: delta not found: $DELTA" >&2; exit 2; }
    if [[ "$MODE" == resume-background ]]; then
      launch_background "$STATE_DIR" resume resume "$STATE_DIR" "$DELTA"
      exit 0
    fi
    PARENT_STAGE="$(cat "$STATE_DIR/stage" 2>/dev/null || true)"
    if [[ "$PARENT_STAGE" == queued && "$(cat "$STATE_DIR/background_kind" 2>/dev/null || true)" == resume ]]; then
      PARENT_STAGE="$(cat "$STATE_DIR/background_parent_stage" 2>/dev/null || true)"
    fi
    LEGACY_ROUND="$(cat "$STATE_DIR/current_round" 2>/dev/null || true)"
    if [[ "$PARENT_STAGE" == failed && "$LEGACY_ROUND" == rereview-* ]] && \
      luna_primary_engineer_review_network_failure "$STATE_DIR/$LEGACY_ROUND/result.txt" "$STATE_DIR/$LEGACY_ROUND/attempt-1/stdout.txt" "$STATE_DIR/$LEGACY_ROUND/attempt-1/stderr.txt"; then
      printf 'blocked\n' > "$STATE_DIR/stage"
      printf 'network\n' > "$STATE_DIR/blocked_reason"
      printf 'blocked\n' > "$STATE_DIR/$LEGACY_ROUND/stage"
      printf 'network\n' > "$STATE_DIR/$LEGACY_ROUND/blocked_reason"
      PARENT_STAGE=blocked
    fi
    [[ -f "$STATE_DIR/result.txt" && ( "$PARENT_STAGE" == done || "$PARENT_STAGE" == failed || "$PARENT_STAGE" == blocked ) ]] || {
      echo "ERROR: completed review or retryable blocked review not found: $STATE_DIR" >&2
      exit 10
    }
    if [[ "$PARENT_STAGE" == failed ]]; then
      FAILED_ROUND="$(cat "$STATE_DIR/current_round" 2>/dev/null || true)"
      [[ "$FAILED_ROUND" == rereview-* && "$(cat "$STATE_DIR/$FAILED_ROUND/stage" 2>/dev/null || true)" == failed ]] || {
        echo "ERROR: failed re-review state is not retryable: $STATE_DIR" >&2
        exit 10
      }
    fi
    if [[ "$PARENT_STAGE" == blocked ]]; then
      BLOCKED_ROUND="$(cat "$STATE_DIR/current_round" 2>/dev/null || true)"
      [[ "$BLOCKED_ROUND" == rereview-* && "$(cat "$STATE_DIR/$BLOCKED_ROUND/stage" 2>/dev/null || true)" == blocked && "$(cat "$STATE_DIR/$BLOCKED_ROUND/blocked_reason" 2>/dev/null || true)" == network ]] || {
        echo "ERROR: blocked initial review must use retry; blocked re-review state is not retryable: $STATE_DIR" >&2
        exit 10
      }
    fi
    PACKET_ABS="$(cat "$STATE_DIR/packet_path" 2>/dev/null || true)"
    SESSION_ID="$(cat "$STATE_DIR/session_id" 2>/dev/null || true)"
    REVIEW_CWD="$(cat "$STATE_DIR/cwd" 2>/dev/null || true)"
    [[ -f "$PACKET_ABS" && -d "$REVIEW_CWD" ]] || { echo "ERROR: original review inputs are unavailable: $STATE_DIR" >&2; exit 2; }
    [[ "$SESSION_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { echo "ERROR: review state has no resumable Claude session ID: $STATE_DIR" >&2; exit 2; }
    HANDOFF_MODE="$(cat "$STATE_DIR/handoff_mode" 2>/dev/null || luna_primary_engineer_result_handoff_mode)" || exit $?

    if [[ "$PARENT_STAGE" == blocked ]]; then
      N="${BLOCKED_ROUND#rereview-}"
      ROUND="$STATE_DIR/$BLOCKED_ROUND"
      if [[ -f "$ROUND/fix-delta.md" ]] && cmp -s "$DELTA" "$ROUND/fix-delta.md"; then
        DELTA_ABS="$ROUND/fix-delta.md"
      else
        DELTA_ABS="$(next_child_dir "$ROUND" delta)/fix-delta.md"
        cp -- "$DELTA" "$DELTA_ABS"
      fi
    else
      N=1
      while [[ -e "$STATE_DIR/rereview-$N" ]]; do N=$((N + 1)); done
      ROUND="$STATE_DIR/rereview-$N"
      (umask 077 && mkdir "$ROUND")
      cp -- "$DELTA" "$ROUND/fix-delta.md"
      cp -- "$STATE_DIR/result.txt" "$ROUND/previous-result.txt"
      printf '%s\n' "$PACKET_ABS" > "$ROUND/packet_path"
      printf '%s\n' "$SESSION_ID" > "$ROUND/session_id"
      printf 'rereview-%s\n' "$N" > "$STATE_DIR/current_round"
      DELTA_ABS="$ROUND/fix-delta.md"
    fi
    PREVIOUS_ABS="$ROUND/previous-result.txt"
    printf 'running\n' > "$STATE_DIR/stage"
    if (cd "$REVIEW_CWD" && run_review "$ROUND" \
      "This is a sticky synchronous re-review in the same Claude conversation. Read the original review packet at: $PACKET_ABS , the previous review result at: $PREVIOUS_ABS , and the Primary's fix delta at: $DELTA_ABS . Re-check each relevant finding, inspect regressions introduced by the fixes, and finish with the complete review contract. Do not ask questions or edit files." \
      "$STATE_DIR" review "$REVIEW_CWD" --resume "$SESSION_ID"); then
      cp -- "$ROUND/result.txt" "$STATE_DIR/result.txt"
      cp -- "$ROUND/run_exit_code" "$STATE_DIR/run_exit_code"
      rm -f "$STATE_DIR/blocked_reason"
      printf 'done\n' > "$STATE_DIR/stage"
      show_result "$STATE_DIR"
    else
      resume_rc=$?
      cp -- "$ROUND/run_exit_code" "$STATE_DIR/run_exit_code" 2>/dev/null || printf '%s\n' "$resume_rc" > "$STATE_DIR/run_exit_code"
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
    ;;

  dual-start)
    require_claude
    [[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
    PACKET="$1"
    [[ -f "$PACKET" ]] || { echo "ERROR: packet not found: $PACKET" >&2; exit 2; }
    GROUP="$(luna_primary_engineer_prepare_review_dir "${2:-}")" || exit $?
    luna_primary_engineer_require_fresh_state_tree "$GROUP" || exit $?
    HANDOFF_MODE="$(luna_primary_engineer_result_handoff_mode)" || exit $?
    (umask 077 && mkdir "$GROUP/seed" "$GROUP/reviewer-1" "$GROUP/reviewer-2")
    cp -- "$PACKET" "$GROUP/review-packet.md"
    PACKET_ABS="$(cd "$GROUP" && pwd -P)/review-packet.md"
    printf '%s\n' "$(pwd -P)" > "$GROUP/cwd"
    printf 'dual-review\n' > "$GROUP/kind"
    printf '%s\n' "$HANDOFF_MODE" > "$GROUP/handoff_mode"
    printf 'seed_running\n' > "$GROUP/stage"
    printf '%s\n' "$PACKET_ABS" > "$GROUP/seed/packet_path"
    if run_review "$GROUP/seed" \
      "LUNA_PRIMARY_ENGINEER_SHARED_SEED_MODE. This is a foreground factual-context load. Read the review packet at: $PACKET_ABS . Load it as shared factual context only. Do not evaluate correctness or propose fixes. Write exactly SEED_READY to the designated result file." \
      "$GROUP" seed "$(pwd -P)" --no-session-persistence; then
      :
    else
      seed_rc=$?
      printf 'failed\n' > "$GROUP/stage"
      exit "$seed_rc"
    fi
    printf 'seed_done\n' > "$GROUP/stage"
    printf 'SEED_READY\nGROUP_DIR=%s\nNEXT=run dual-advance for the two foreground reviewers\n' "$GROUP"
    ;;

  dual-status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    echo "STAGE=$(cat "$GROUP/stage" 2>/dev/null || echo unknown)"
    echo "[seed]"; luna_primary_engineer_print_state_dir "$GROUP/seed" || true
    for n in 1 2; do
      if [[ -d "$GROUP/reviewer-$n" ]]; then
        echo "[reviewer-$n]"; luna_primary_engineer_print_state_dir "$GROUP/reviewer-$n" || true
      fi
    done
    ;;

  dual-advance)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    [[ -f "$GROUP/seed/result.txt" && "$(cat "$GROUP/stage" 2>/dev/null || true)" == seed_done ]] || { echo "ERROR: foreground seed is not complete: $GROUP" >&2; exit 10; }
    if [[ -f "$GROUP/reviewer-1/result.txt" || -f "$GROUP/reviewer-2/result.txt" ]]; then
      [[ -f "$GROUP/reviewer-1/result.txt" && -f "$GROUP/reviewer-2/result.txt" ]] || { echo "ERROR: dual review is partially complete; inspect results before rerunning." >&2; exit 15; }
      echo "INFO: both foreground reviewers already ran; no action taken."; exit 0
    fi
    PACKET_ABS="$(cat "$GROUP/seed/packet_path")"
    SEED_ABS="$GROUP/seed/result.txt"
    HANDOFF_MODE="$(cat "$GROUP/handoff_mode")"
    FAIL=0
    printf 'branches_running\n' > "$GROUP/stage"
    for n in 1 2; do
      D="$GROUP/reviewer-$n"
      printf '%s\n' "$PACKET_ABS" > "$D/packet_path"
      if run_review "$D" \
        "You are Reviewer $n, an independent foreground reviewer. Read the factual review packet at: $PACKET_ABS and the neutral seed result at: $SEED_ABS . Analyze the change independently. Do not seek consensus or edit files; finish with the complete review contract." \
        "$GROUP" review "$(cat "$GROUP/cwd")" --no-session-persistence; then
        cp -- "$D/result.txt" "$D/initial-result.txt"
      else
        code=$?
        (( FAIL == 0 )) && FAIL="$code"
      fi
    done
    if (( FAIL != 0 )); then printf 'failed\n' > "$GROUP/stage"; exit "$FAIL"; fi
    printf 'done\n' > "$GROUP/stage"
    "$0" dual-collect "$GROUP"
    ;;

  dual-collect)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    GROUP="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    [[ -f "$GROUP/reviewer-1/result.txt" && -f "$GROUP/reviewer-2/result.txt" ]] || { echo "ERROR: both foreground reviewers must finish before collection." >&2; exit 10; }
    for n in 1 2; do
      luna_primary_engineer_review_contract_complete "$GROUP/reviewer-$n/result.txt" || { echo "ERROR: reviewer-$n result lacks the complete review contract." >&2; exit 18; }
    done
    printf 'reviewer\tstate\tresult\n' > "$GROUP/manifest.tsv"
    printf 'reviewer-1\tdone\t%s\n' "$GROUP/reviewer-1/result.txt" >> "$GROUP/manifest.tsv"
    printf 'reviewer-2\tdone\t%s\n' "$GROUP/reviewer-2/result.txt" >> "$GROUP/manifest.tsv"
    cat "$GROUP/manifest.tsv"
    echo '--- Reviewer 1 ---'; cat "$GROUP/reviewer-1/result.txt"
    echo '--- Reviewer 2 ---'; cat "$GROUP/reviewer-2/result.txt"
    ;;

  *) usage >&2; exit 2 ;;
esac
