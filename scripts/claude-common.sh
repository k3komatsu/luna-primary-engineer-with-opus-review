#!/usr/bin/env bash
# Shared helpers for Luna Primary Engineer v6.6 foreground Claude integration.

luna_primary_engineer_claude_mode() {
  printf '%s' "${LUNA_PRIMARY_ENGINEER_CLAUDE:-auto}"
}

luna_primary_engineer_claude_available() {
  local mode
  mode="$(luna_primary_engineer_claude_mode)"
  [[ "$mode" != "off" ]] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  [[ "$mode" == "on" ]] || claude auth status >/dev/null 2>&1
}

luna_primary_engineer_warn_billing() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "WARN: ANTHROPIC_API_KEY is set; Claude Code may be using API-billed authentication." >&2
  fi
}

luna_primary_engineer_new_session_id() {
  local uuid hex
  if command -v uuidgen >/dev/null 2>&1; then
    uuid="$(uuidgen)"
    [[ "$uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || return 1
    printf '%s\n' "$uuid"
    return 0
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    local proc_uuid
    proc_uuid="$(cat /proc/sys/kernel/random/uuid)"
    if [[ "$proc_uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
      printf '%s\n' "$proc_uuid"
      return 0
    fi
  fi
  if command -v od >/dev/null 2>&1 && [[ -r /dev/urandom ]]; then
    hex="$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')"
    [[ "${#hex}" -ge 32 ]] || return 1
    printf '%s-%s-%s-%s-%s\n' \
      "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
    return 0
  fi
  echo "ERROR: cannot generate a UUID for the Claude session." >&2
  return 1
}

luna_primary_engineer_require_fresh_state_dir() {
  local state_dir="$1" marker
  for marker in job_id session_id launch.txt launch_exit_code result.txt run_exit_code; do
    if [[ -e "$state_dir/$marker" ]]; then
      echo "ERROR: state directory already contains run evidence: $state_dir/$marker. Use a new state directory, or inspect the existing foreground run." >&2
      return 2
    fi
  done
}

luna_primary_engineer_require_fresh_state_tree() {
  local root="$1" marker
  [[ -d "$root" ]] || return 0
  marker="$(find "$root" -type f \( -name job_id -o -name session_id -o -name launch.txt -o -name launch_exit_code -o -name result.txt -o -name run_exit_code \) -print -quit 2>/dev/null || true)"
  if [[ -n "$marker" ]]; then
    echo "ERROR: state tree already contains run evidence: $marker. Use a new output directory, or inspect the existing foreground run first." >&2
    return 2
  fi
}

luna_primary_engineer_runtime_dir() {
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
  printf '%s/luna-primary-engineer/runtime/%s/%s' "$codex_dir" "$repo_key" "$stamp"
}

# Run Claude in the foreground and persist its exit code beside the captured output.
# The caller remains responsible for setting the stage and validating the result.
luna_primary_engineer_run_foreground() {
  local output="$1" exit_file="$2" rc=0
  local api_timeout_ms="${API_TIMEOUT_MS:-600000}"
  local idle_timeout_ms="${CLAUDE_STREAM_IDLE_TIMEOUT_MS:-600000}"
  local byte_idle_timeout_ms="${CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS:-$idle_timeout_ms}"
  local first_byte_timeout_ms="${CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS:-600000}"
  shift 2
  if [[ ! "$api_timeout_ms" =~ ^[1-9][0-9]*$ || ! "$idle_timeout_ms" =~ ^[1-9][0-9]*$ || ! "$byte_idle_timeout_ms" =~ ^[1-9][0-9]*$ || ! "$first_byte_timeout_ms" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Claude timeout variables must be positive integers in milliseconds." >&2
    return 2
  fi
  if API_TIMEOUT_MS="$api_timeout_ms" \
    CLAUDE_STREAM_IDLE_TIMEOUT_MS="$idle_timeout_ms" \
    CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS="$byte_idle_timeout_ms" \
    CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS="$first_byte_timeout_ms" \
    claude "$@" >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$rc" > "$exit_file"
  return "$rc"
}

# A foreground Claude process can exit because the caller's network path cannot
# reach Anthropic, even though Claude auth succeeded. Keep this distinct from a
# reviewer finding or a real Claude failure so the caller can retry the same
# state/session after network access is restored.
luna_primary_engineer_review_network_failure() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -Eiq \
    'Request timed out|api\.anthropic\.com|NODE_EXTRA_CA_CERTS|proxy[^[:space:]]*[[:space:]]+intercept|ECONNRESET|ETIMEDOUT|ENETUNREACH|EAI_AGAIN' \
    "$file"
}

luna_primary_engineer_review_contract_complete() {
  local file="$1" heading
  [[ -f "$file" ]] || return 1
  for heading in VERDICT BLOCKERS NONBLOCKING TEST_GAPS PREVIOUS_FINDINGS; do
    grep -Eq "^${heading}:" "$file" || return 1
  done
}

luna_primary_engineer_print_state_dir() {
  local state_dir="$1" stage rc reason
  [[ -d "$state_dir" ]] || { echo "ERROR: missing state directory: $state_dir" >&2; return 2; }
  stage="$(cat "$state_dir/stage" 2>/dev/null || printf 'unknown')"
  rc="$(cat "$state_dir/run_exit_code" 2>/dev/null || printf '')"
  reason="$(cat "$state_dir/blocked_reason" 2>/dev/null || printf '')"
  printf 'STATE=%s\nEXIT_CODE=%s\nBLOCKED_REASON=%s\nSTATE_DIR=%s\n' "$stage" "$rc" "$reason" "$state_dir"
  case "$stage" in
    done) return 0 ;;
    running|seed_running|branches_running) return 10 ;;
    blocked) return 11 ;;
    failed) return 12 ;;
    *) return 14 ;;
  esac
}
