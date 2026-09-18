#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

usage() {
  cat <<'TXT'
Usage:
  claude-job.sh status  STATE_DIR
  claude-job.sh logs    STATE_DIR [stdout|stderr|result]
  claude-job.sh collect STATE_DIR [OUTPUT_FILE]

These commands inspect a worktree review state. A state started with
claude-review.sh start-background or resume-background keeps its wrapper and
Claude process alive independently of the invoking terminal; poll `status`.
There is no automatic retry, result reconstruction, or reviewer fallback.
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
      stdout) file="$STATE_DIR/$(cat "$STATE_DIR/last_attempt" 2>/dev/null || printf '')/stdout.txt" ;;
      stderr) file="$STATE_DIR/$(cat "$STATE_DIR/last_attempt" 2>/dev/null || printf '')/stderr.txt" ;;
      result) file="$STATE_DIR/result.txt" ;;
      *) echo "ERROR: logs selector must be stdout, stderr, or result." >&2; exit 2 ;;
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
