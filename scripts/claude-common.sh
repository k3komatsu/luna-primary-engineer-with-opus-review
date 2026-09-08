#!/usr/bin/env bash
# Shared helpers for Luna Orchestrator v6.6 Claude Code background integration.

luna_orch_claude_mode() {
  printf '%s' "${LUNA_ORCH_CLAUDE:-auto}"
}

luna_orch_claude_available() {
  local mode
  mode="$(luna_orch_claude_mode)"
  [[ "$mode" != "off" ]] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  if [[ "$mode" == "on" ]]; then
    return 0
  fi
  claude auth status >/dev/null 2>&1
}

luna_orch_warn_billing() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "WARN: ANTHROPIC_API_KEY is set; Claude Code may be using API-billed authentication." >&2
  fi
}

luna_orch_require_fresh_state_dir() {
  local state_dir="$1"
  if [[ -e "$state_dir/job_id" || -e "$state_dir/session_id" || -e "$state_dir/launch.txt" || -e "$state_dir/launch_exit_code" ]]; then
    echo "ERROR: state directory already contains Claude identity/launch evidence: $state_dir. Use a new state directory, or use status/collect/resume for the existing review." >&2
    return 2
  fi
}

luna_orch_require_fresh_state_tree() {
  local root="$1" marker
  [[ -d "$root" ]] || return 0
  marker="$(find "$root" -type f \( -name job_id -o -name session_id -o -name launch.txt -o -name launch_exit_code \) -print -quit 2>/dev/null || true)"
  if [[ -n "$marker" ]]; then
    echo "ERROR: state tree already contains Claude identity/launch evidence: $marker. Use a new output directory, or inspect the existing run first." >&2
    return 2
  fi
}

luna_orch_runtime_dir() {
  local codex_dir repo_key stamp
  codex_dir="${CODEX_HOME:-${HOME}/.codex}"
  if command -v shasum >/dev/null 2>&1; then
    repo_key="$(printf '%s' "$PWD" | shasum | awk '{print substr($1,1,12)}')"
  elif command -v sha1sum >/dev/null 2>&1; then
    repo_key="$(printf '%s' "$PWD" | sha1sum | awk '{print substr($1,1,12)}')"
  else
    repo_key="repo"
  fi
  stamp="$(date '+%Y%m%d-%H%M%S')"
  printf '%s/luna-orchestrator/runtime/%s/%s' "$codex_dir" "$repo_key" "$stamp"
}

# Parse the short background job/session ID printed by `claude --bg`.
# Current Claude Code prints e.g. `backgrounded · 7c5dcf5d · name`.
luna_orch_extract_bg_id() {
  local file="$1" id
  id="$(sed -n 's/.*backgrounded[^0-9a-fA-F]*\([0-9a-fA-F]\{8\}\).*/\1/p' "$file" | head -n 1)"
  if [[ -z "$id" ]]; then
    id="$(grep -Eo '[0-9a-fA-F]{8}' "$file" 2>/dev/null | head -n 1 || true)"
  fi
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# Print: state<TAB>status for one background ID from `claude agents --json --all`.
# Uses jq, Python, Node, or JXA (macOS) in that order.
luna_orch_bg_record_from_json() {
  local json_file="$1" wanted="$2"
  [[ -n "$wanted" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg id "$wanted" '
      first(.[] | (.id // "") as $rid | select($rid != "" and ($rid == $id or ($rid | startswith($id)) or ($id | startswith($rid)))))
      | [(.state // "unknown"), (.status // "")] | @tsv
    ' "$json_file" 2>/dev/null || true
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$json_file" "$wanted" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    rows = json.load(f)
wanted = sys.argv[2]
for row in rows:
    rid = str(row.get('id', ''))
    if rid and (rid == wanted or rid.startswith(wanted) or wanted.startswith(rid)):
        status = row.get('status', '')
        if not isinstance(status, str):
            status = json.dumps(status, ensure_ascii=False)
        print(f"{row.get('state', 'unknown')}\t{status}")
        break
PY
    return
  fi
  if command -v node >/dev/null 2>&1; then
    node - "$json_file" "$wanted" <<'JS'
const fs = require('fs');
const rows = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const wanted = process.argv[3];
for (const row of rows) {
  const id = String(row.id || '');
  if (id && (id === wanted || id.startsWith(wanted) || wanted.startsWith(id))) {
    const status = typeof row.status === 'string' ? row.status : JSON.stringify(row.status || '');
    process.stdout.write(`${row.state || 'unknown'}\t${status}\n`);
    break;
  }
}
JS
    return
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript -l JavaScript - "$json_file" "$wanted" <<'JXA'
ObjC.import('Foundation');
const args = $.NSProcessInfo.processInfo.arguments.js.slice(4);
const path = args[0], wanted = args[1];
const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
const rows = JSON.parse(text);
for (const row of rows) {
  const id = String(row.id || '');
  if (id && (id === wanted || id.startsWith(wanted) || wanted.startsWith(id))) {
    const status = typeof row.status === 'string' ? row.status : JSON.stringify(row.status || '');
    console.log(`${row.state || 'unknown'}\t${status}`);
    break;
  }
}
JXA
    return
  fi
  echo "ERROR: need jq, python3, node, or osascript to parse 'claude agents --json'." >&2
  return 2
}

# Query one background job. Prints state<TAB>status. If the job is absent, prints unknown.
luna_orch_bg_record() {
  local id="$1" tmp rec
  tmp="$(mktemp "${TMPDIR:-/tmp}/luna-orch-agents.XXXXXX")"
  if ! claude agents --json --all >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "ERROR: 'claude agents --json --all' failed." >&2
    return 2
  fi
  rec="$(luna_orch_bg_record_from_json "$tmp" "$id")"
  rm -f "$tmp"
  if [[ -z "$rec" ]]; then
    printf 'unknown\t\n'
  else
    printf '%s\n' "$rec"
  fi
}


# Resolve the full Claude conversation sessionId for one background job ID.
# `claude agents --json --all` exposes both a short background `id` (for
# attach/logs/stop) and a full `sessionId` (for `claude --resume`). Keep them
# distinct: v6.6 uses sessionId for sticky same-conversation follow-ups.
luna_orch_bg_session_id_from_json() {
  local json_file="$1" wanted="$2"
  [[ -n "$wanted" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg id "$wanted" '
      first(.[] | (.id // "") as $rid | select($rid != "" and ($rid == $id or ($rid | startswith($id)) or ($id | startswith($rid)))))
      | (.sessionId // "")
    ' "$json_file" 2>/dev/null || true
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$json_file" "$wanted" <<'PY2'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    rows = json.load(f)
wanted = sys.argv[2]
for row in rows:
    rid = str(row.get('id', ''))
    if rid and (rid == wanted or rid.startswith(wanted) or wanted.startswith(rid)):
        print(str(row.get('sessionId', '') or ''))
        break
PY2
    return
  fi
  if command -v node >/dev/null 2>&1; then
    node - "$json_file" "$wanted" <<'JS2'
const fs = require('fs');
const rows = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const wanted = process.argv[3];
for (const row of rows) {
  const id = String(row.id || '');
  if (id && (id === wanted || id.startsWith(wanted) || wanted.startsWith(id))) {
    process.stdout.write(String(row.sessionId || '') + '\n');
    break;
  }
}
JS2
    return
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript -l JavaScript - "$json_file" "$wanted" <<'JXA2'
ObjC.import('Foundation');
const args = $.NSProcessInfo.processInfo.arguments.js.slice(4);
const path = args[0], wanted = args[1];
const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
const rows = JSON.parse(text);
for (const row of rows) {
  const id = String(row.id || '');
  if (id && (id === wanted || id.startsWith(wanted) || wanted.startsWith(id))) {
    console.log(String(row.sessionId || ''));
    break;
  }
}
JXA2
    return
  fi
  echo "ERROR: need jq, python3, node, or osascript to parse 'claude agents --json'." >&2
  return 2
}

luna_orch_bg_session_id() {
  local id="$1" tmp sid
  tmp="$(mktemp "${TMPDIR:-/tmp}/luna-orch-agents.XXXXXX")"
  if ! claude agents --json --all >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "ERROR: 'claude agents --json --all' failed." >&2
    return 2
  fi
  sid="$(luna_orch_bg_session_id_from_json "$tmp" "$id")"
  rm -f "$tmp"
  [[ -n "$sid" ]] || return 1
  printf '%s' "$sid"
}

# Save a background job's conversation sessionId into a state directory when
# available. Safe to call repeatedly.
luna_orch_store_session_id() {
  local state_dir="$1" id sid
  [[ -f "$state_dir/job_id" ]] || return 1
  id="$(cat "$state_dir/job_id")"
  sid="$(luna_orch_bg_session_id "$id" 2>/dev/null || true)"
  if [[ -n "$sid" ]]; then
    printf '%s\n' "$sid" > "$state_dir/session_id"
    printf '%s' "$sid"
    return 0
  fi
  return 1
}

luna_orch_bg_state() {
  local id="$1" rec
  rec="$(luna_orch_bg_record "$id")" || return
  printf '%s' "${rec%%$'\t'*}"
}

luna_orch_bg_logs() {
  local id="$1" out="$2"
  claude logs "$id" >"$out"
}

luna_orch_review_contract_complete() {
  local file="$1" heading
  [[ -f "$file" ]] || return 1
  for heading in VERDICT BLOCKERS NONBLOCKING TEST_GAPS PREVIOUS_FINDINGS; do
    grep -Fq "$heading" "$file" || return 1
  done
}

# Exit codes used by status/collect helpers:
#   0 done
#  10 still working/idle
#  11 blocked / needs input
#  12 failed
#  13 stopped
#  14 unknown/not listed
#  18 completed output is missing the review contract
luna_orch_bg_state_code() {
  case "$1" in
    done|completed) return 0 ;;
    working|idle) return 10 ;;
    blocked|needs_input|needs-input) return 11 ;;
    failed) return 12 ;;
    stopped) return 13 ;;
    *) return 14 ;;
  esac
}

luna_orch_print_state_dir() {
  local state_dir="$1" id rec state status
  [[ -f "$state_dir/job_id" ]] || { echo "ERROR: missing $state_dir/job_id" >&2; return 2; }
  id="$(cat "$state_dir/job_id")"
  rec="$(luna_orch_bg_record "$id")" || return
  state="${rec%%$'\t'*}"
  status="${rec#*$'\t'}"
  local sid
  sid="$(cat "$state_dir/session_id" 2>/dev/null || true)"
  if [[ -z "$sid" ]]; then sid="$(luna_orch_bg_session_id "$id" 2>/dev/null || true)"; fi
  printf 'JOB_ID=%s\nSESSION_ID=%s\nSTATE=%s\nSTATUS=%s\nSTATE_DIR=%s\n' "$id" "$sid" "$state" "$status" "$state_dir"
  luna_orch_bg_state_code "$state"
}
