#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-primary-engineer-self-state.XXXXXX")"
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-primary-engineer-self-review.XXXXXX")"
cleanup() {
  rm -rf "$STATE_DIR" "$SMOKE_DIR"
}
trap cleanup EXIT

CONTRACT_FILE="$STATE_DIR/contract.txt"
printf '%s\n' 'VERDICT: PASS' 'BLOCKERS:' 'NONBLOCKING:' 'TEST_GAPS:' 'PREVIOUS_FINDINGS:' > "$CONTRACT_FILE"
luna_primary_engineer_review_contract_complete "$CONTRACT_FILE"

printf '%s\n' 'This prose mentions VERDICT BLOCKERS NONBLOCKING TEST_GAPS PREVIOUS_FINDINGS.' > "$CONTRACT_FILE"
if luna_primary_engineer_review_contract_complete "$CONTRACT_FILE"; then
  echo "FAIL: incidental contract mentions were accepted as headings" >&2
  exit 1
fi

SESSION_ID="$(luna_primary_engineer_new_session_id)"
if [[ ! "$SESSION_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  echo "FAIL: generated Claude session ID is not a UUID" >&2
  exit 1
fi

printf '%s\n' 'VERDICT: PASS' > "$CONTRACT_FILE"
if luna_primary_engineer_review_contract_complete "$CONTRACT_FILE"; then
  echo "FAIL: incomplete review contract was accepted" >&2
  exit 1
fi

rm -f "$CONTRACT_FILE"
luna_primary_engineer_require_fresh_state_dir "$STATE_DIR"
touch "$STATE_DIR/result.txt"
if luna_primary_engineer_require_fresh_state_dir "$STATE_DIR" 2>/dev/null; then
  echo "FAIL: completed result was not rejected as a reused state directory" >&2
  exit 1
fi

rm -f "$STATE_DIR/result.txt"
touch "$STATE_DIR/job_id"
if luna_primary_engineer_require_fresh_state_dir "$STATE_DIR" 2>/dev/null; then
  echo "FAIL: legacy asynchronous state was not rejected" >&2
  exit 1
fi

rm -f "$STATE_DIR/job_id"
touch "$STATE_DIR/session_id"
if luna_primary_engineer_require_fresh_state_dir "$STATE_DIR" 2>/dev/null; then
  echo "FAIL: persisted session state was not rejected as a reused state directory" >&2
  exit 1
fi

rm -f "$STATE_DIR/session_id"
printf 'done\n' > "$STATE_DIR/stage"
printf '0\n' > "$STATE_DIR/run_exit_code"
luna_primary_engineer_print_state_dir "$STATE_DIR" >/dev/null

claude() {
  if [[ "${1:-}" == auth && "${2:-}" == status ]]; then
    return 0
  fi
  printf '%s\n' \
    "api-timeout=${API_TIMEOUT_MS:-unset}" \
    "idle-timeout=${CLAUDE_STREAM_IDLE_TIMEOUT_MS:-unset}" \
    "byte-idle-timeout=${CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS:-unset}" \
    "first-byte-timeout=${CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS:-unset}" >> "$MOCK_LOG"
  printf '%s\n' "$@" >> "$MOCK_LOG"
  if [[ "${MOCK_FAIL:-0}" == 1 ]]; then
    return 7
  fi
  if [[ "${MOCK_NETWORK_FAIL:-0}" == 1 ]]; then
    printf '%s\n' 'Request timed out'
    return 1
  fi
  printf '%s\n' \
    'VERDICT: PASS' \
    'BLOCKERS:' \
    'NONBLOCKING:' \
    'TEST_GAPS:' \
    'PREVIOUS_FINDINGS:'
}
export -f claude
export LUNA_PRIMARY_ENGINEER_CLAUDE=on
MOCK_LOG="$SMOKE_DIR/claude-args.log"
MOCK_FAIL=0
MOCK_NETWORK_FAIL=0
EXPECTED_IDLE_TIMEOUT="${CLAUDE_STREAM_IDLE_TIMEOUT_MS:-600000}"
EXPECTED_BYTE_IDLE_TIMEOUT="${CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS:-$EXPECTED_IDLE_TIMEOUT}"
EXPECTED_FIRST_BYTE_TIMEOUT="${CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS:-600000}"
EXPECTED_API_TIMEOUT="${API_TIMEOUT_MS:-600000}"
export MOCK_LOG MOCK_FAIL MOCK_NETWORK_FAIL

PACKET="$SMOKE_DIR/packet.md"
DELTA="$SMOKE_DIR/delta.md"
printf '%s\n' '# smoke packet' > "$PACKET"
printf '%s\n' '# smoke delta' > "$DELTA"
REVIEW_STATE="$SMOKE_DIR/state"
bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$REVIEW_STATE" smoke >/dev/null
REVIEW_SESSION_ID="$(cat "$REVIEW_STATE/session_id")"
grep -Fq -- "idle-timeout=$EXPECTED_IDLE_TIMEOUT" "$MOCK_LOG"
grep -Fq -- "byte-idle-timeout=$EXPECTED_BYTE_IDLE_TIMEOUT" "$MOCK_LOG"
grep -Fq -- "first-byte-timeout=$EXPECTED_FIRST_BYTE_TIMEOUT" "$MOCK_LOG"
grep -Fq -- "api-timeout=$EXPECTED_API_TIMEOUT" "$MOCK_LOG"
grep -Fq -- '--session-id' "$MOCK_LOG"
grep -Fq -- "$REVIEW_SESSION_ID" "$MOCK_LOG"
if grep -Fq -- '--no-session-persistence' "$MOCK_LOG"; then
  echo "FAIL: ordinary review unexpectedly disabled session persistence" >&2
  exit 1
fi

SMOKE_PARENT="$(dirname "$SMOKE_DIR")"
SMOKE_BASE="$(basename "$SMOKE_DIR")"
(
  cd "$SMOKE_PARENT"
  bash "$SCRIPT_DIR/claude-review.sh" resume "$SMOKE_BASE/state" "$SMOKE_BASE/delta.md" >/dev/null
)
grep -Fq -- '--resume' "$MOCK_LOG"
grep -Fq -- "$REVIEW_SESSION_ID" "$MOCK_LOG"
grep -Fq "$REVIEW_STATE/rereview-1/previous-result.txt" "$MOCK_LOG"
bash "$SCRIPT_DIR/claude-job.sh" status "$REVIEW_STATE" >/dev/null

FAIL_STATE="$SMOKE_DIR/failure-state"
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
[[ "$(cat "$FAIL_STATE/run_exit_code")" == 7 ]]
if bash "$SCRIPT_DIR/claude-review.sh" collect "$FAIL_STATE" >/dev/null 2>&1; then
  echo "FAIL: failed re-review was collectable" >&2
  exit 1
fi

MOCK_FAIL=0
export MOCK_FAIL
bash "$SCRIPT_DIR/claude-review.sh" resume "$FAIL_STATE" "$DELTA" >/dev/null
[[ "$(cat "$FAIL_STATE/stage")" == done ]]
[[ "$(cat "$FAIL_STATE/current_round")" == rereview-2 ]]

NETWORK_STATE="$SMOKE_DIR/network-state"
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
# Simulate a state written by the previous helper version, which called this
# same transport error `failed`; retry should migrate it without a new state.
rm -f "$NETWORK_STATE/blocked_reason"
printf 'failed\n' > "$NETWORK_STATE/stage"
MOCK_NETWORK_FAIL=0
export MOCK_NETWORK_FAIL
bash "$SCRIPT_DIR/claude-review.sh" retry "$NETWORK_STATE" >/dev/null
[[ "$(cat "$NETWORK_STATE/stage")" == done ]]
grep -Fq -- '--resume' "$MOCK_LOG"
grep -Fq -- "$(cat "$NETWORK_STATE/session_id")" "$MOCK_LOG"

NETWORK_REREVIEW_STATE="$SMOKE_DIR/network-rereview-state"
MOCK_NETWORK_FAIL=0
export MOCK_NETWORK_FAIL
bash "$SCRIPT_DIR/claude-review.sh" start "$PACKET" "$NETWORK_REREVIEW_STATE" smoke-network-rereview >/dev/null
MOCK_NETWORK_FAIL=1
export MOCK_NETWORK_FAIL
if bash "$SCRIPT_DIR/claude-review.sh" resume "$NETWORK_REREVIEW_STATE" "$DELTA" >/dev/null 2>&1; then
  echo "FAIL: network-blocked re-review unexpectedly succeeded" >&2
  exit 1
else
  NETWORK_REREVIEW_RC=$?
fi
[[ "$NETWORK_REREVIEW_RC" == 11 ]]
[[ "$(cat "$NETWORK_REREVIEW_STATE/stage")" == blocked ]]
[[ "$(cat "$NETWORK_REREVIEW_STATE/current_round")" == rereview-1 ]]
[[ "$(cat "$NETWORK_REREVIEW_STATE/rereview-1/stage")" == blocked ]]
MOCK_NETWORK_FAIL=0
export MOCK_NETWORK_FAIL
bash "$SCRIPT_DIR/claude-review.sh" resume "$NETWORK_REREVIEW_STATE" "$DELTA" >/dev/null
[[ "$(cat "$NETWORK_REREVIEW_STATE/stage")" == done ]]
[[ "$(cat "$NETWORK_REREVIEW_STATE/current_round")" == rereview-1 ]]

FALLBACK_AGENT="$SCRIPT_DIR/../codex-agents/luna_reviewer.toml"
for marker in LUNA_CLAUDE_PREFLIGHT_FALLBACK CLAUDE_NOT_LAUNCHED; do
  if ! grep -Fq -- "$marker" "$FALLBACK_AGENT"; then
    echo "FAIL: fallback reviewer is missing the preflight marker $marker" >&2
    exit 1
  fi
done
if ! grep -Fq -- 'never invoke `luna_reviewer`' "$SCRIPT_DIR/../SKILL.md"; then
  echo "FAIL: skill does not forbid in-flight Luna fallback" >&2
  exit 1
fi

echo "PASS: foreground result, contract, fresh-state, sticky-review, and network-block guards"
