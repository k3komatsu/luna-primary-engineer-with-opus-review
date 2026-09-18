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
  if [[ "$LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF" == stdout ]]; then
    printf 'LUNA_RESULT_BEGIN\n'
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
export -f claude
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
export MOCK_LOG MOCK_FAIL MOCK_NETWORK_FAIL MOCK_MISSING_RESULT MOCK_EMPTY_RESULT MOCK_INCOMPLETE MOCK_STDOUT_CONTRACT MOCK_PERMISSION_FAIL MOCK_NO_CONVERSATION_FAIL MOCK_STRICT_CLI CONTRACT_TEXT

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

bash "$SCRIPT_DIR/claude-review.sh" resume "$REVIEW_STATE" "$DELTA" >/dev/null
grep -Fq -- '--resume' "$MOCK_LOG"
grep -Fq -- "$REVIEW_SESSION_ID" "$MOCK_LOG"
grep -Fq "$REVIEW_STATE/rereview-1/previous-result.txt" "$MOCK_LOG"
bash "$SCRIPT_DIR/claude-job.sh" status "$REVIEW_STATE" >/dev/null

BACKGROUND_STATE="$(luna_primary_engineer_new_review_dir)"
bash "$SCRIPT_DIR/claude-review.sh" start-background "$PACKET" "$BACKGROUND_STATE" smoke-background >/dev/null
for _ in {1..50}; do
  [[ "$(cat "$BACKGROUND_STATE/stage" 2>/dev/null || true)" == done ]] && break
  sleep 0.02
done
[[ "$(cat "$BACKGROUND_STATE/stage")" == done ]]
luna_primary_engineer_review_contract_complete "$BACKGROUND_STATE/result.txt"

# A CLI without path-scoped permission support uses a framed handoff while
# keeping all write-capable tools disabled.
FALLBACK_STATE="$(luna_primary_engineer_new_review_dir)"
export LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF=stdout
bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$FALLBACK_STATE" smoke-framed >/dev/null
luna_primary_engineer_review_contract_complete "$FALLBACK_STATE/result.txt"
grep -Fq -- '--disallowedTools' "$MOCK_LOG"
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
ROLES_DIR="$(luna_primary_engineer_new_review_dir)"
printf '%s\n' 'role one' > "$ROLES_DIR/one.md"
printf '%s\n' 'role two' > "$ROLES_DIR/two.md"
PANEL_CONTEXT="$TEST_INPUT/context.md"
printf '%s\n' 'context' > "$PANEL_CONTEXT"
PANEL_DIR="$(luna_primary_engineer_new_review_dir)"
bash "$SCRIPT_DIR/claude-panel.sh" start "$PANEL_CONTEXT" "$ROLES_DIR" "$PANEL_DIR" >/dev/null
bash "$SCRIPT_DIR/claude-panel.sh" advance "$PANEL_DIR" >/dev/null
bash "$SCRIPT_DIR/claude-panel.sh" collect "$PANEL_DIR" >/dev/null

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

FALLBACK_AGENT="$SCRIPT_DIR/../codex-agents/luna_reviewer.toml"
for marker in LUNA_CLAUDE_PREFLIGHT_FALLBACK CLAUDE_NOT_LAUNCHED; do
  grep -Fq -- "$marker" "$FALLBACK_AGENT"
done
grep -Fq -- 'never invoke `luna_reviewer`' "$SCRIPT_DIR/../SKILL.md"

echo "PASS: designated-file result, safe handoff, contract failures, workspace paths, sticky review, dual, panel, and static guards"
