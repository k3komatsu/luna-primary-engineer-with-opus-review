#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

usage() {
  cat <<'TXT'
Usage:
  claude-job.sh status  STATE_DIR
  claude-job.sh logs    STATE_DIR
  claude-job.sh collect STATE_DIR [OUTPUT_FILE]

Claude runs are foreground-only. These commands inspect a completed result
directory; stop/attach/agent lifecycle operations are intentionally absent.
Use Ctrl-C in the invoking terminal to interrupt a live foreground run.
TXT
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
MODE="$1"
STATE_DIR="$2"
shift 2

[[ -d "$STATE_DIR" ]] || { echo "ERROR: missing state directory: $STATE_DIR" >&2; exit 2; }
if [[ -f "$STATE_DIR/job_id" ]]; then
  echo "ERROR: this is a legacy asynchronous state directory; rerun the operation in a new directory." >&2
  exit 2
fi

case "$MODE" in
  status)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    luna_primary_engineer_print_state_dir "$STATE_DIR"
    ;;
  logs)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    [[ -f "$STATE_DIR/result.txt" ]] || { echo "ERROR: no foreground result exists: $STATE_DIR/result.txt" >&2; exit 2; }
    cat "$STATE_DIR/result.txt"
    ;;
  collect)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    [[ "$(cat "$STATE_DIR/stage" 2>/dev/null || true)" == "done" ]] || {
      echo "ERROR: foreground run is not complete: $STATE_DIR" >&2
      exit 10
    }
    if [[ $# -eq 0 ]]; then
      cat "$STATE_DIR/result.txt"
    else
      cp "$STATE_DIR/result.txt" "$1"
      cat "$1"
    fi
    ;;
  stop)
    echo "ERROR: foreground runs have no asynchronous stop operation; press Ctrl-C in the invoking terminal." >&2
    exit 2
    ;;
  *) usage >&2; exit 2 ;;
esac
