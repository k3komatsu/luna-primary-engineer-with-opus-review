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
  claude-job.sh stop    STATE_DIR

This script never retries or resumes a job automatically.
`status=idle` is not completion; inspect lifecycle `state` and collect only at `done`.
The log footer `Worked ... · done` means the latest turn rendered, not necessarily
that the background session is closed. `blocked` means inspect logs / attach if
human input is needed.
TXT
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
MODE="$1"; STATE_DIR="$2"; shift 2
[[ -f "$STATE_DIR/job_id" ]] || { echo "ERROR: missing $STATE_DIR/job_id" >&2; exit 2; }
JOB_ID="$(cat "$STATE_DIR/job_id")"

case "$MODE" in
  status)
    luna_orch_print_state_dir "$STATE_DIR"
    ;;
  logs)
    claude logs "$JOB_ID"
    ;;
  collect)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    OUT="${1:-$STATE_DIR/result.txt}"
    REC="$(luna_orch_bg_record "$JOB_ID")"
    STATE="${REC%%$'\t'*}"
    STATUS="${REC#*$'\t'}"
    case "$STATE" in
      done|completed)
        luna_orch_bg_logs "$JOB_ID" "$OUT"
        cat "$OUT"
        ;;
      blocked|needs_input|needs-input)
        echo "BLOCKED: $STATUS" >&2
        claude logs "$JOB_ID" >&2 || true
        exit 11
        ;;
      working|idle)
        echo "NOT_READY: $STATE - $STATUS" >&2
        exit 10
        ;;
      failed)
        echo "FAILED: $STATUS" >&2
        claude logs "$JOB_ID" >&2 || true
        exit 12
        ;;
      stopped)
        echo "STOPPED: $STATUS" >&2
        claude logs "$JOB_ID" >&2 || true
        exit 13
        ;;
      *)
        echo "UNKNOWN_JOB_STATE: $JOB_ID" >&2
        claude logs "$JOB_ID" >&2 || true
        exit 14
        ;;
    esac
    ;;
  stop)
    claude stop "$JOB_ID"
    ;;
  *) usage >&2; exit 2 ;;
esac
