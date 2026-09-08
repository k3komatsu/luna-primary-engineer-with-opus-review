#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luna-primary-engineer-self-state.XXXXXX")"
cleanup() {
  rm -rf "$STATE_DIR"
}
trap cleanup EXIT

CONTRACT_FILE="$STATE_DIR/contract.txt"
printf '%s\n' 'VERDICT: PASS' 'BLOCKERS:' 'NONBLOCKING:' 'TEST_GAPS:' 'PREVIOUS_FINDINGS:' > "$CONTRACT_FILE"
luna_primary_engineer_review_contract_complete "$CONTRACT_FILE"

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
printf 'done\n' > "$STATE_DIR/stage"
printf '0\n' > "$STATE_DIR/run_exit_code"
luna_primary_engineer_print_state_dir "$STATE_DIR" >/dev/null

echo "PASS: foreground result, contract, and fresh-state guards"
