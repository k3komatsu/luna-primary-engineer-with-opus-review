#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

WORKSPACE="$(luna_primary_engineer_review_workspace)"
TEST_INPUT="$(luna_primary_engineer_new_review_dir)"
COMMON_STATE="$(luna_primary_engineer_new_review_dir)"
SMOKE_DIR="$(luna_primary_engineer_new_review_dir)"

CONTRACT_LINES=(
  'VERDICT: PASS'
  'BLOCKERS:'
  'NONBLOCKING:'
  'TEST_GAPS:'
  'PREVIOUS_FINDINGS:'
)
CONTRACT_TEXT=$'VERDICT: PASS\nBLOCKERS:\nNONBLOCKING:\nTEST_GAPS:\nPREVIOUS_FINDINGS:'

printf '%s\n' "${CONTRACT_LINES[@]}" > "$COMMON_STATE/contract.txt"
luna_primary_engineer_review_contract_complete "$COMMON_STATE/contract.txt"

printf '%s\n' 'This prose mentions VERDICT BLOCKERS NONBLOCKING TEST_GAPS PREVIOUS_FINDINGS.' > "$COMMON_STATE/contract.txt"
if luna_primary_engineer_review_contract_complete "$COMMON_STATE/contract.txt"; then
  echo "FAIL: incidental contract mentions were accepted as headings" >&2
  exit 1
fi

SESSION_ID="$(luna_primary_engineer_new_session_id)"
[[ "$SESSION_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { echo "FAIL: invalid session UUID" >&2; exit 1; }

printf '%s\n' 'VERDICT: PASS' > "$COMMON_STATE/contract.txt"
if luna_primary_engineer_review_contract_complete "$COMMON_STATE/contract.txt"; then
  echo "FAIL: incomplete contract was accepted" >&2
  exit 1
fi

luna_primary_engineer_require_fresh_state_dir "$SMOKE_DIR"
touch "$SMOKE_DIR/result.txt"
if luna_primary_engineer_require_fresh_state_dir "$SMOKE_DIR" 2>/dev/null; then
  echo "FAIL: non-empty state directory was not rejected" >&2
  exit 1
fi
rm -f "$SMOKE_DIR/result.txt"

if luna_primary_engineer_resolve_existing_review_dir "$PWD/.." >/dev/null 2>&1; then
  echo "FAIL: review directory outside worktree tmp was accepted" >&2
  exit 1
fi
for forbidden in \
  "/$(luna_primary_engineer_tmp_leaf)/probe" \
  "/$(printf private)/$(luna_primary_engineer_tmp_leaf)/probe" \
  "/$(printf var)/$(luna_primary_engineer_tmp_leaf)/probe"; do
  luna_primary_engineer_is_forbidden_temp_path "$forbidden" || {
    echo "FAIL: system temporary path was not rejected: $forbidden" >&2
    exit 1
  }
done

# Fake Claude writes the designated result file and deliberately emits no
# stdout. This is the regression case that used to lose a completed review.
claude() {
  if [[ "${1:-}" == auth && "${2:-}" == status ]]; then return 0; fi
  if [[ "${1:-}" == --help ]]; then
    printf '%s\n' '--allowedTools --tools --disallowedTools'
    return 0
  fi
  printf '%s\n' \
    "api-timeout=${API_TIMEOUT_MS:-unset}" \
    "idle-timeout=${CLAUDE_STREAM_IDLE_TIMEOUT_MS:-unset}" \
    "byte-idle-timeout=${CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS:-unset}" \
    "first-byte-timeout=${CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS:-unset}" \
    "$@" >> "$MOCK_LOG"
  if [[ "${MOCK_STRICT_CLI:-0}" == 1 ]]; then
    local arg
    for arg in "$@"; do
      case "$arg" in
        MultiEdit|NotebookEdit)
          printf '%s\n' "Permission deny rule \"$arg\" matches no known tool" >&2
          return 2
          ;;
        Write\(/*)
          printf '%s\n' "Permission allow rule $arg is not matched; use Edit(path)" >&2
          return 2
          ;;
      esac
    done
    if [[ "$LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF" != stdout ]] && \
      ! printf '%s\n' "$@" | grep -Eq '^Edit\(//'; then
      printf '%s\n' 'Permission allow rule must use an absolute Edit(//path) rule' >&2
      return 2
    fi
  fi
  if [[ "${MOCK_FAIL:-0}" == 1 ]]; then return 7; fi
  if [[ "${MOCK_PERMISSION_FAIL:-0}" == 1 ]]; then
    printf '%s\n' 'Request timed out'
    printf '%s\n' 'Permission deny rule "MultiEdit" matches no known tool' >&2
    return 1
  fi
  if [[ "${MOCK_NO_CONVERSATION_FAIL:-0}" == 1 ]]; then
    printf '%s\n' 'No conversation found with session ID: smoke-session' >&2
    return 1
  fi
  if [[ "${MOCK_NETWORK_FAIL:-0}" == 1 ]]; then
    printf '%s\n' 'Request timed out' >&2
    return 1
  fi
  if [[ "${MOCK_DELAY:-0}" != 0 ]]; then sleep "$MOCK_DELAY"; fi
  if [[ "$LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF" == stdout ]]; then
    printf 'LUNA_RESULT_BEGIN\n'
    if [[ "${MOCK_TRUNCATED:-0}" == 1 ]]; then
      printf '%s\n' "$CONTRACT_TEXT"
      return 0
    fi
    if [[ "${MOCK_INCOMPLETE:-0}" == 1 ]]; then
      printf '%s\n' 'VERDICT: PASS'
    else
      printf '%s\n' "$CONTRACT_TEXT"
    fi
    printf 'LUNA_RESULT_END\n'
    return 0
  fi
  if [[ "${MOCK_MISSING_RESULT:-0}" == 1 ]]; then
    if [[ "${MOCK_STDOUT_CONTRACT:-0}" == 1 ]]; then printf '%s\n' "$CONTRACT_TEXT"; fi
    return 0
  fi
  if [[ "${MOCK_EMPTY_RESULT:-0}" == 1 ]]; then : > "$LUNA_PRIMARY_ENGINEER_REVIEW_RESULT_PATH"; return 0; fi
  if [[ "${MOCK_INCOMPLETE:-0}" == 1 ]]; then
    printf '%s\n' 'VERDICT: PASS' > "$LUNA_PRIMARY_ENGINEER_REVIEW_RESULT_PATH"
    return 0
  fi
  if printf '%s\n' "$@" | grep -Fq 'Write exactly SEED_READY'; then
    printf 'SEED_READY\n' > "$LUNA_PRIMARY_ENGINEER_REVIEW_RESULT_PATH"
  else
    printf '%s\n' "$CONTRACT_TEXT" > "$LUNA_PRIMARY_ENGINEER_REVIEW_RESULT_PATH"
  fi
}

# Keep process-list tests deterministic even when the enclosing Codex sandbox
# denies the real ps command. Reserved high PIDs represent vanished processes.
ps() {
  if [[ "${MOCK_PS_DENIED:-0}" == 1 ]]; then
    printf 'ps: operation not permitted\n' >&2
    return 1
  fi
  if [[ "${MOCK_PS_UNKNOWN:-0}" == 1 ]]; then
    printf 'ps: unexpected process-list failure\n' >&2
    return 2
  fi
  if [[ "${1:-}" == -p && "${2:-}" =~ ^99999999[12]$ ]]; then return 1; fi
  if [[ "${1:-}" == -p && "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
    if [[ " ${MOCK_ALIVE_PIDS:-} " == *" $2 "* ]]; then
      printf '%s\n' "$2"
      return 0
    fi
    return 1
  fi
  command ps "$@"
}
export -f claude ps
export LUNA_PRIMARY_ENGINEER_CLAUDE=on
export LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF=file
MOCK_LOG="$SMOKE_DIR/claude-args.log"
MOCK_FAIL=0
MOCK_NETWORK_FAIL=0
MOCK_MISSING_RESULT=0
MOCK_EMPTY_RESULT=0
MOCK_INCOMPLETE=0
MOCK_STDOUT_CONTRACT=0
MOCK_PERMISSION_FAIL=0
MOCK_NO_CONVERSATION_FAIL=0
MOCK_STRICT_CLI=1
MOCK_DELAY=0
MOCK_PS_DENIED=0
MOCK_PS_UNKNOWN=0
MOCK_TRUNCATED=0
MOCK_ALIVE_PIDS=""
export MOCK_LOG MOCK_FAIL MOCK_NETWORK_FAIL MOCK_MISSING_RESULT MOCK_EMPTY_RESULT MOCK_INCOMPLETE MOCK_STDOUT_CONTRACT MOCK_PERMISSION_FAIL MOCK_NO_CONVERSATION_FAIL MOCK_STRICT_CLI MOCK_DELAY MOCK_PS_DENIED MOCK_PS_UNKNOWN MOCK_TRUNCATED MOCK_ALIVE_PIDS CONTRACT_TEXT

PACKET="$TEST_INPUT/packet.md"
DELTA="$TEST_INPUT/delta.md"
printf '%s\n' '# smoke packet' > "$PACKET"
printf '%s\n' '# smoke delta' > "$DELTA"
REVIEW_STATE="$(luna_primary_engineer_new_review_dir)"
bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$REVIEW_STATE" smoke >/dev/null
REVIEW_SESSION_ID="$(cat "$REVIEW_STATE/session_id")"
grep -Fq -- 'idle-timeout=' "$MOCK_LOG"
grep -Fq -- '--session-id' "$MOCK_LOG"
grep -Fq -- "$REVIEW_SESSION_ID" "$MOCK_LOG"
grep -Fq -- '--allowedTools' "$MOCK_LOG"
grep -Fq -- "Edit(/$REVIEW_STATE/attempt-1/reviewer-result.md)" "$MOCK_LOG"
grep -Fq -- '--tools' "$MOCK_LOG"
grep -Fq -- 'Read,Glob,Grep,Write' "$MOCK_LOG"
! grep -Fq -- 'Write(/' "$MOCK_LOG"
! grep -Fq -- 'MultiEdit' "$MOCK_LOG"
! grep -Fq -- 'NotebookEdit' "$MOCK_LOG"
[[ ! -s "$REVIEW_STATE/attempt-1/stdout.txt" ]]
luna_primary_engineer_review_contract_complete "$REVIEW_STATE/result.txt"
[[ "$(cat "$REVIEW_STATE/attempt-1/runner_pid")" =~ ^[1-9][0-9]*$ ]]
[[ "$(cat "$REVIEW_STATE/attempt-1/claude_pid")" =~ ^[1-9][0-9]*$ ]]
REVIEW_STATUS="$(bash "$SCRIPT_DIR/claude-review.sh" status "$REVIEW_STATE")"
grep -Eq '^RUNNER_PID=[1-9][0-9]*$' <<< "$REVIEW_STATUS"
grep -Eq '^CLAUDE_PID=[1-9][0-9]*$' <<< "$REVIEW_STATUS"

bash "$SCRIPT_DIR/claude-review.sh" resume "$REVIEW_STATE" "$DELTA" >/dev/null
[[ ! -e "$REVIEW_STATE/user_confirmation_required" ]]
grep -Fq -- '--resume' "$MOCK_LOG"
grep -Fq -- "$REVIEW_SESSION_ID" "$MOCK_LOG"
grep -Fq "$REVIEW_STATE/rereview-1/previous-result.txt" "$MOCK_LOG"
bash "$SCRIPT_DIR/claude-job.sh" status "$REVIEW_STATE" >/dev/null
bash "$SCRIPT_DIR/claude-job.sh" logs "$REVIEW_STATE" stdout >/dev/null
bash "$SCRIPT_DIR/claude-job.sh" logs "$REVIEW_STATE" stderr >/dev/null

BACKGROUND_STATE="$(luna_primary_engineer_new_review_dir)"
MOCK_DELAY=0.5
export MOCK_DELAY
bash "$SCRIPT_DIR/claude-review.sh" start-background "$PACKET" "$BACKGROUND_STATE" smoke-background >/dev/null
for _ in {1..50}; do
  [[ -s "$BACKGROUND_STATE/attempt-1/claude_pid" ]] && break
  sleep 0.01
done
MOCK_ALIVE_PIDS="$(cat "$BACKGROUND_STATE/attempt-1/runner_pid") $(cat "$BACKGROUND_STATE/attempt-1/claude_pid")"
export MOCK_ALIVE_PIDS
BACKGROUND_STATUS="$(bash "$SCRIPT_DIR/claude-review.sh" status "$BACKGROUND_STATE" || true)"
grep -Fq 'RUNNER_ALIVE=1' <<< "$BACKGROUND_STATUS"
grep -Fq 'CLAUDE_ALIVE=1' <<< "$BACKGROUND_STATUS"
MOCK_ALIVE_PIDS=""
export MOCK_ALIVE_PIDS
MOCK_DELAY=0
export MOCK_DELAY
for _ in {1..50}; do
  [[ "$(cat "$BACKGROUND_STATE/stage" 2>/dev/null || true)" == done ]] && break
  sleep 0.02
done
[[ "$(cat "$BACKGROUND_STATE/stage")" == done ]]
luna_primary_engineer_review_contract_complete "$BACKGROUND_STATE/result.txt"

# A tracked run whose runner and Claude process both disappeared without an
# adopted result becomes a failed state that requires user confirmation.
LOST_STATE="$(luna_primary_engineer_new_review_dir)"
mkdir "$LOST_STATE/attempt-1"
printf 'running\n' > "$LOST_STATE/stage"
printf '%s\n' "$LOST_STATE/attempt-1" > "$LOST_STATE/last_attempt"
printf '999999991\n' > "$LOST_STATE/attempt-1/runner_pid"
printf '999999992\n' > "$LOST_STATE/attempt-1/claude_pid"
if LOST_STATUS="$(bash "$SCRIPT_DIR/claude-review.sh" status "$LOST_STATE" 2>&1)"; then
  echo "FAIL: vanished processes without a result were not reported as failed" >&2
  exit 1
else
  LOST_RC=$?
fi
[[ "$LOST_RC" == 12 ]]
[[ "$(cat "$LOST_STATE/stage")" == failed ]]
[[ "$(cat "$LOST_STATE/failure_reason")" == process_gone_without_result ]]
[[ "$(cat "$LOST_STATE/user_confirmation_required")" == 1 ]]
grep -Fq 'USER_CONFIRMATION_REQUIRED=1' <<< "$LOST_STATUS"
grep -Fq 'RUNNER_ALIVE=0' <<< "$LOST_STATUS"
grep -Fq 'CLAUDE_ALIVE=0' <<< "$LOST_STATUS"

# Permission-denied process-list access is unknown, not proof of disappearance.
UNKNOWN_STATE="$(luna_primary_engineer_new_review_dir)"
mkdir "$UNKNOWN_STATE/attempt-1"
printf 'running\n' > "$UNKNOWN_STATE/stage"
printf '%s\n' "$UNKNOWN_STATE/attempt-1" > "$UNKNOWN_STATE/last_attempt"
printf '12341\n' > "$UNKNOWN_STATE/attempt-1/runner_pid"
printf '12342\n' > "$UNKNOWN_STATE/attempt-1/claude_pid"
MOCK_PS_DENIED=1
export MOCK_PS_DENIED
if UNKNOWN_STATUS="$(bash "$SCRIPT_DIR/claude-review.sh" status "$UNKNOWN_STATE" 2>&1)"; then
  echo "FAIL: a running state with unknown process-list access returned success" >&2
  exit 1
else
  UNKNOWN_RC=$?
fi
MOCK_PS_DENIED=0
export MOCK_PS_DENIED
[[ "$UNKNOWN_RC" == 10 ]]
[[ "$(cat "$UNKNOWN_STATE/stage")" == running ]]
grep -Fq 'RUNNER_ALIVE=unknown' <<< "$UNKNOWN_STATUS"
grep -Fq 'CLAUDE_ALIVE=unknown' <<< "$UNKNOWN_STATUS"
grep -Fq 'PROCESS_LIST_PERMISSION_REQUIRED=1' <<< "$UNKNOWN_STATUS"

# Any other ps failure is also unknown, not proof that both processes died.
MOCK_PS_UNKNOWN=1
export MOCK_PS_UNKNOWN
if UNKNOWN_STATUS_2="$(bash "$SCRIPT_DIR/claude-review.sh" status "$UNKNOWN_STATE" 2>&1)"; then
  echo "FAIL: an unrecognized process-list failure returned success" >&2
  exit 1
else
  UNKNOWN_RC_2=$?
fi
MOCK_PS_UNKNOWN=0
export MOCK_PS_UNKNOWN
[[ "$UNKNOWN_RC_2" == 10 ]]
[[ "$(cat "$UNKNOWN_STATE/stage")" == running ]]
grep -Fq 'RUNNER_ALIVE=unknown' <<< "$UNKNOWN_STATUS_2"

# A queued resume must not rewrite the already-completed previous round when
# its detached wrapper disappears before creating the next round.
QUEUED_STATE="$(luna_primary_engineer_new_review_dir)"
mkdir "$QUEUED_STATE/rereview-1"
printf 'queued\n' > "$QUEUED_STATE/stage"
printf 'resume\n' > "$QUEUED_STATE/background_kind"
printf 'done\n' > "$QUEUED_STATE/background_parent_stage"
printf 'rereview-1\n' > "$QUEUED_STATE/current_round"
printf 'done\n' > "$QUEUED_STATE/rereview-1/stage"
printf '%s\n' "$CONTRACT_TEXT" > "$QUEUED_STATE/result.txt"
printf '999999991\n' > "$QUEUED_STATE/background_pid"
for metadata in packet_path session_id cwd handoff_mode; do cp "$REVIEW_STATE/$metadata" "$QUEUED_STATE/$metadata"; done
if QUEUED_STATUS="$(bash "$SCRIPT_DIR/claude-review.sh" status "$QUEUED_STATE" 2>&1)"; then
  echo "FAIL: disappeared queued resume unexpectedly returned success" >&2
  exit 1
else
  QUEUED_RC=$?
fi
[[ "$QUEUED_RC" == 12 ]]
[[ "$(cat "$QUEUED_STATE/stage")" == failed ]]
[[ "$(cat "$QUEUED_STATE/rereview-1/stage")" == done ]]
[[ "$(cat "$QUEUED_STATE/failure_reason")" == process_gone_without_result ]]
bash "$SCRIPT_DIR/claude-review.sh" resume "$QUEUED_STATE" "$DELTA" >/dev/null
[[ "$(cat "$QUEUED_STATE/stage")" == done ]]
[[ "$(cat "$QUEUED_STATE/current_round")" == rereview-2 ]]

# A lost run in the small round-creation window must still be reconciled.
RACE_STATE="$(luna_primary_engineer_new_review_dir)"
mkdir "$RACE_STATE/rereview-1" "$RACE_STATE/rereview-1/attempt-1"
printf 'running\n' > "$RACE_STATE/stage"
printf 'rereview-1\n' > "$RACE_STATE/current_round"
printf '%s\n' "$RACE_STATE/rereview-1/attempt-1" > "$RACE_STATE/rereview-1/last_attempt"
printf '999999991\n' > "$RACE_STATE/rereview-1/attempt-1/runner_pid"
printf '999999992\n' > "$RACE_STATE/rereview-1/attempt-1/claude_pid"
if RACE_STATUS="$(bash "$SCRIPT_DIR/claude-review.sh" status "$RACE_STATE" 2>&1)"; then
  echo "FAIL: round-creation race unexpectedly returned success" >&2
  exit 1
else
  RACE_RC=$?
fi
[[ "$RACE_RC" == 12 ]]
[[ "$(cat "$RACE_STATE/stage")" == failed ]]
[[ "$(cat "$RACE_STATE/rereview-1/stage")" == failed ]]

# Unknown liveness must also prevent a background relaunch.
RELAUNCH_STATE="$(luna_primary_engineer_new_review_dir)"
printf 'done\n' > "$RELAUNCH_STATE/stage"
printf '12341\n' > "$RELAUNCH_STATE/background_pid"
MOCK_PS_DENIED=1
export MOCK_PS_DENIED
if bash "$SCRIPT_DIR/claude-review.sh" resume-background "$RELAUNCH_STATE" "$DELTA" >/dev/null 2>&1; then
  echo "FAIL: unknown background liveness allowed a relaunch" >&2
  exit 1
else
  RELAUNCH_RC=$?
fi
MOCK_PS_DENIED=0
export MOCK_PS_DENIED
[[ "$RELAUNCH_RC" == 15 ]]
[[ "$(cat "$RELAUNCH_STATE/stage")" == done ]]
[[ ! -e "$RELAUNCH_STATE/background.log" ]]

# A CLI without path-scoped permission support uses a framed handoff while
# keeping all write-capable tools disabled.
FALLBACK_STATE="$(luna_primary_engineer_new_review_dir)"
export LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF=stdout
bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$FALLBACK_STATE" smoke-framed >/dev/null
luna_primary_engineer_review_contract_complete "$FALLBACK_STATE/result.txt"
grep -Fq -- '--disallowedTools' "$MOCK_LOG"
TRUNCATED_STATE="$(luna_primary_engineer_new_review_dir)"
MOCK_TRUNCATED=1
export MOCK_TRUNCATED
if bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$TRUNCATED_STATE" smoke-truncated >/dev/null 2>&1; then
  echo "FAIL: truncated stdout frame unexpectedly succeeded" >&2
  exit 1
else
  TRUNCATED_RC=$?
fi
MOCK_TRUNCATED=0
export MOCK_TRUNCATED
[[ "$TRUNCATED_RC" == 18 ]]
[[ ! -s "$TRUNCATED_STATE/attempt-1/reviewer-result.md" ]]
export LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF=file

run_expected_invalid_result() {
  local state="$1" variable="$2" expected_rc=18 rc error_file="$TEST_INPUT/$2-error.log"
  export MOCK_MISSING_RESULT=0 MOCK_EMPTY_RESULT=0 MOCK_INCOMPLETE=0
  case "$variable" in
    missing) MOCK_MISSING_RESULT=1 ;;
    empty) MOCK_EMPTY_RESULT=1 ;;
    incomplete) MOCK_INCOMPLETE=1 ;;
  esac
  export MOCK_MISSING_RESULT MOCK_EMPTY_RESULT MOCK_INCOMPLETE
  if bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$state" "invalid-$variable" >/dev/null 2>"$error_file"; then
    echo "FAIL: $variable result unexpectedly succeeded" >&2
    exit 1
  else
    rc=$?
  fi
  [[ "$rc" == "$expected_rc" ]]
  [[ "$(cat "$state/stage")" == failed ]]
  [[ "$(cat "$state/user_confirmation_required")" == 1 ]]
  grep -Fq -- 'stdout diagnostic' "$error_file"
  grep -Fq -- 'stderr diagnostic' "$error_file"
}

run_expected_invalid_result "$(luna_primary_engineer_new_review_dir)" missing
run_expected_invalid_result "$(luna_primary_engineer_new_review_dir)" empty
run_expected_invalid_result "$(luna_primary_engineer_new_review_dir)" incomplete
export MOCK_MISSING_RESULT=0 MOCK_EMPTY_RESULT=0 MOCK_INCOMPLETE=0
STDOUT_ONLY_STATE="$(luna_primary_engineer_new_review_dir)"
MOCK_MISSING_RESULT=1 MOCK_STDOUT_CONTRACT=1
export MOCK_MISSING_RESULT MOCK_STDOUT_CONTRACT
if bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$STDOUT_ONLY_STATE" stdout-only >/dev/null 2>"$TEST_INPUT/stdout-only-error.log"; then
  echo "FAIL: stdout-only contract was incorrectly adopted" >&2
  exit 1
else
  STDOUT_ONLY_RC=$?
fi
[[ "$STDOUT_ONLY_RC" == 18 ]]
grep -Fq -- 'reviewer-result.md' "$TEST_INPUT/stdout-only-error.log"
MOCK_MISSING_RESULT=0 MOCK_STDOUT_CONTRACT=0
export MOCK_MISSING_RESULT MOCK_STDOUT_CONTRACT

NETWORK_STATE="$(luna_primary_engineer_new_review_dir)"
MOCK_NETWORK_FAIL=1
export MOCK_NETWORK_FAIL
if bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$NETWORK_STATE" smoke-network >/dev/null 2>&1; then
  echo "FAIL: network-blocked review unexpectedly succeeded" >&2
  exit 1
else
  NETWORK_RC=$?
fi
[[ "$NETWORK_RC" == 11 ]]
[[ "$(cat "$NETWORK_STATE/stage")" == blocked ]]
[[ "$(cat "$NETWORK_STATE/blocked_reason")" == network ]]
[[ "$(cat "$NETWORK_STATE/user_confirmation_required")" == 1 ]]
MOCK_NETWORK_FAIL=0
export MOCK_NETWORK_FAIL
bash "$SCRIPT_DIR/claude-review.sh" retry "$NETWORK_STATE" >/dev/null
[[ "$(cat "$NETWORK_STATE/stage")" == done ]]
grep -Fq -- '--resume' "$MOCK_LOG"

NO_CONVERSATION_STATE="$(luna_primary_engineer_new_review_dir)"
MOCK_NETWORK_FAIL=1
export MOCK_NETWORK_FAIL
if bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$NO_CONVERSATION_STATE" smoke-no-conversation >/dev/null 2>&1; then
  echo "FAIL: network setup unexpectedly succeeded" >&2
  exit 1
fi
[[ "$(cat "$NO_CONVERSATION_STATE/stage")" == blocked ]]
MOCK_NETWORK_FAIL=0
MOCK_NO_CONVERSATION_FAIL=1
export MOCK_NETWORK_FAIL MOCK_NO_CONVERSATION_FAIL
if bash "$SCRIPT_DIR/claude-review.sh" retry "$NO_CONVERSATION_STATE" >/dev/null 2>&1; then
  echo "FAIL: missing conversation unexpectedly succeeded" >&2
  exit 1
fi
[[ "$(cat "$NO_CONVERSATION_STATE/stage")" == failed ]]
MOCK_NO_CONVERSATION_FAIL=0
export MOCK_NO_CONVERSATION_FAIL

PERMISSION_STATE="$(luna_primary_engineer_new_review_dir)"
MOCK_PERMISSION_FAIL=1
export MOCK_PERMISSION_FAIL
if bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$PERMISSION_STATE" smoke-permission-error >/dev/null 2>&1; then
  echo "FAIL: permission error unexpectedly succeeded" >&2
  exit 1
fi
[[ "$(cat "$PERMISSION_STATE/stage")" == failed ]]
[[ ! -e "$PERMISSION_STATE/blocked_reason" ]]
MOCK_PERMISSION_FAIL=0
export MOCK_PERMISSION_FAIL

FAIL_STATE="$(luna_primary_engineer_new_review_dir)"
bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$FAIL_STATE" smoke-failure >/dev/null
MOCK_FAIL=1
export MOCK_FAIL
if bash "$SCRIPT_DIR/claude-review.sh" resume "$FAIL_STATE" "$DELTA" >/dev/null 2>&1; then
  echo "FAIL: failed re-review unexpectedly succeeded" >&2
  exit 1
else
  RESUME_RC=$?
fi
[[ "$RESUME_RC" == 7 ]]
[[ "$(cat "$FAIL_STATE/stage")" == failed ]]
MOCK_FAIL=0
export MOCK_FAIL
bash "$SCRIPT_DIR/claude-review.sh" resume "$FAIL_STATE" "$DELTA" >/dev/null
[[ "$(cat "$FAIL_STATE/stage")" == done ]]
[[ "$(cat "$FAIL_STATE/current_round")" == rereview-2 ]]
bash "$SCRIPT_DIR/claude-review.sh" resume-background "$FAIL_STATE" "$DELTA" >/dev/null
for _ in {1..50}; do
  [[ "$(cat "$FAIL_STATE/stage" 2>/dev/null || true)" == done ]] && break
  sleep 0.02
done
[[ "$(cat "$FAIL_STATE/stage")" == done ]]
[[ "$(cat "$FAIL_STATE/current_round")" == rereview-3 ]]

# Verify dual result handoff and panel result handoff use the same workspace.
DUAL_GROUP="$(luna_primary_engineer_new_review_dir)"
bash "$SCRIPT_DIR/claude-review.sh" dual-start "$PACKET" "$DUAL_GROUP" >/dev/null
bash "$SCRIPT_DIR/claude-review.sh" dual-advance "$DUAL_GROUP" >/dev/null
bash "$SCRIPT_DIR/claude-review.sh" dual-collect "$DUAL_GROUP" >/dev/null
DUAL_NETWORK_GROUP="$(luna_primary_engineer_new_review_dir)"
bash "$SCRIPT_DIR/claude-review.sh" dual-start "$PACKET" "$DUAL_NETWORK_GROUP" >/dev/null
MOCK_NETWORK_FAIL=1
export MOCK_NETWORK_FAIL
if bash "$SCRIPT_DIR/claude-review.sh" dual-advance "$DUAL_NETWORK_GROUP" >/dev/null 2>&1; then
  echo "FAIL: dual network failure unexpectedly succeeded" >&2
  exit 1
else
  DUAL_NETWORK_RC=$?
fi
MOCK_NETWORK_FAIL=0
export MOCK_NETWORK_FAIL
[[ "$DUAL_NETWORK_RC" == 11 ]]
[[ -f "$DUAL_NETWORK_GROUP/reviewer-1/last_attempt" ]]
[[ ! -e "$DUAL_NETWORK_GROUP/reviewer-2/last_attempt" ]]
ROLES_DIR="$(luna_primary_engineer_new_review_dir)"
printf '%s\n' 'role one' > "$ROLES_DIR/one.md"
printf '%s\n' 'role two' > "$ROLES_DIR/two.md"
PANEL_CONTEXT="$TEST_INPUT/context.md"
printf '%s\n' 'context' > "$PANEL_CONTEXT"
PANEL_DIR="$(luna_primary_engineer_new_review_dir)"
bash "$SCRIPT_DIR/claude-panel.sh" start "$PANEL_CONTEXT" "$ROLES_DIR" "$PANEL_DIR" >/dev/null
bash "$SCRIPT_DIR/claude-panel.sh" advance "$PANEL_DIR" >/dev/null
bash "$SCRIPT_DIR/claude-panel.sh" collect "$PANEL_DIR" >/dev/null
PANEL_NETWORK_DIR="$(luna_primary_engineer_new_review_dir)"
bash "$SCRIPT_DIR/claude-panel.sh" start "$PANEL_CONTEXT" "$ROLES_DIR" "$PANEL_NETWORK_DIR" >/dev/null
MOCK_NETWORK_FAIL=1
export MOCK_NETWORK_FAIL
if bash "$SCRIPT_DIR/claude-panel.sh" advance "$PANEL_NETWORK_DIR" >/dev/null 2>&1; then
  echo "FAIL: panel network failure unexpectedly succeeded" >&2
  exit 1
else
  PANEL_NETWORK_RC=$?
fi
MOCK_NETWORK_FAIL=0
export MOCK_NETWORK_FAIL
[[ "$PANEL_NETWORK_RC" == 11 ]]
[[ -f "$PANEL_NETWORK_DIR/one/last_attempt" ]]
[[ ! -e "$PANEL_NETWORK_DIR/two/last_attempt" ]]

STATIC_TARGETS=(
  "$SCRIPT_DIR/claude-common.sh"
  "$SCRIPT_DIR/claude-review.sh"
  "$SCRIPT_DIR/claude-panel.sh"
  "$SCRIPT_DIR/claude-job.sh"
)
if rg -n -S '\$\{TMPDIR|mktemp|/private/|/var/tmp|/tmp/' "${STATIC_TARGETS[@]}"; then
  echo "FAIL: review scripts contain a system-temporary storage path" >&2
  exit 1
fi
for script in "${STATIC_TARGETS[@]}"; do bash -n "$script"; done
if rg -n -S '(^|[^[:alnum:]_])(command[[:space:]]+)?(kill|pkill|killall)([[:space:]]|$)' "${STATIC_TARGETS[@]}"; then
  echo "FAIL: review scripts contain a process-termination command" >&2
  exit 1
fi

FALLBACK_AGENT="$SCRIPT_DIR/../codex-agents/luna_reviewer.toml"
for marker in LUNA_CLAUDE_PREFLIGHT_FALLBACK CLAUDE_NOT_LAUNCHED; do
  grep -Fq -- "$marker" "$FALLBACK_AGENT"
done
grep -Fq -- 'never invoke `luna_reviewer`' "$SCRIPT_DIR/../SKILL.md"

grep -Fq 'allow_implicit_invocation: false' "$SCRIPT_DIR/../agents/openai.yaml"

echo "PASS: designated-file result, PID state, process-loss confirmation, safe handoff, contract failures, sticky review, dual/panel recovery guards, implicit-invocation policy, and static guards"
