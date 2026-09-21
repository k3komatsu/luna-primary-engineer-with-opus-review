#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

usage() {
  cat <<'TXT'
Usage:
  claude-job.sh status  STATE_DIR
  claude-job.sh logs    STATE_DIR [stdout|stderr|result|raw-result]
  claude-job.sh collect STATE_DIR [OUTPUT_FILE]

These commands inspect a worktree review state. A state started with
claude-review.sh start-background or resume-background keeps its wrapper and
Claude process alive independently of the invoking terminal; poll `status`.
Never stop an Opus process after launch. There is no automatic retry, result
reconstruction, or reviewer fallback. If status reports
USER_CONFIRMATION_REQUIRED=1, ask before starting another Opus call.
If status reports review_returned_invalid_format, inspect `logs STATE_DIR
raw-result`: Claude returned review text, but its format prevented adoption.
If status reports an ALIVE value of permission_denied, ps was denied; escalate
execution permission and rerun status before making any review decision. A
different unknown value is also inconclusive and must not trigger a relaunch.
TXT
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
MODE="$1"
STATE_DIR="$(luna_primary_engineer_resolve_existing_review_dir "$2")" || exit $?
shift 2

case "$MODE" in
  status)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    luna_primary_engineer_print_state_dir "$STATE_DIR"
    ;;
  logs)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    selector="${1:-stdout}"
    case "$selector" in
      stdout|stderr)
        attempt_dir="$(luna_primary_engineer_latest_attempt_dir "$STATE_DIR" 2>/dev/null || printf '')"
        [[ -n "$attempt_dir" ]] || { echo "ERROR: no attempt diagnostics found: $STATE_DIR" >&2; exit 2; }
        file="$attempt_dir/$selector.txt"
        ;;
      result) file="$STATE_DIR/result.txt" ;;
      raw-result)
        attempt_dir="$(luna_primary_engineer_latest_attempt_dir "$STATE_DIR" 2>/dev/null || printf '')"
        [[ -n "$attempt_dir" ]] || { echo "ERROR: no review attempt found: $STATE_DIR" >&2; exit 2; }
        file="$attempt_dir/reviewer-result.md"
        ;;
      *) echo "ERROR: logs selector must be stdout, stderr, result, or raw-result." >&2; exit 2 ;;
    esac
    [[ -f "$file" ]] || { echo "ERROR: diagnostic/result file not found: $file" >&2; exit 2; }
    cat "$file"
    ;;
  collect)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    [[ "$(cat "$STATE_DIR/stage" 2>/dev/null || true)" == done ]] || { echo "ERROR: run is not complete: $STATE_DIR" >&2; exit 10; }
    luna_primary_engineer_review_contract_complete "$STATE_DIR/result.txt" || { echo "ERROR: adopted result is not a complete review contract." >&2; exit 18; }
    if [[ $# -eq 0 ]]; then
      cat "$STATE_DIR/result.txt"
    else
      cp -- "$STATE_DIR/result.txt" "$1"
      cat "$1"
    fi
    ;;
  *) usage >&2; exit 2 ;;
esac
