#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/luna-orch-self-test.XXXXXX")"
CONTRACT_FILE="$(mktemp "${TMPDIR:-/tmp}/luna-orch-self-contract.XXXXXX")"
STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-orch-self-state.XXXXXX")"
cleanup() {
  rm -f "$JSON_FILE" "$CONTRACT_FILE" "$STATE_DIR/launch.txt"
  rmdir "$STATE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

printf '%s\n' '[{"state":"working","status":"idle","sessionId":"wrong-session"},{"id":"abc12345","state":"done","status":"idle","sessionId":"actual-session"}]' > "$JSON_FILE"

[[ "$(luna_orch_bg_record_from_json "$JSON_FILE" abc12345)" == $'done\tidle' ]]
[[ "$(luna_orch_bg_session_id_from_json "$JSON_FILE" abc12345)" == "actual-session" ]]
[[ -z "$(luna_orch_bg_session_id_from_json "$JSON_FILE" deadbeef)" ]]
[[ -z "$(luna_orch_bg_session_id_from_json "$JSON_FILE" "")" ]]

printf '%s\n' 'VERDICT: PASS' 'BLOCKERS:' 'NONBLOCKING:' 'TEST_GAPS:' 'PREVIOUS_FINDINGS:' > "$CONTRACT_FILE"
luna_orch_review_contract_complete "$CONTRACT_FILE"
printf '%s\n' 'VERDICT: PASS' > "$CONTRACT_FILE"
if luna_orch_review_contract_complete "$CONTRACT_FILE"; then
  echo "FAIL: incomplete review contract was accepted" >&2
  exit 1
fi

luna_orch_require_fresh_state_dir "$STATE_DIR"
touch "$STATE_DIR/launch.txt"
if luna_orch_require_fresh_state_dir "$STATE_DIR" 2>/dev/null; then
  echo "FAIL: launch evidence was not rejected" >&2
  exit 1
fi

echo "PASS: Claude ID matching and fresh-state guards"
