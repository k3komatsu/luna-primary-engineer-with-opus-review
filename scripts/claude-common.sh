#!/usr/bin/env bash
# Shared helpers for Luna Primary Engineer Claude integration.

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
  echo "INFO: every Claude review or re-review consumes Claude usage; retries are explicit only." >&2
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

# The review workspace is deliberately derived from the repository containing
# the current working directory. It never follows a worktree tmp symlink.
luna_primary_engineer_worktree_root() {
  local root
  root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ERROR: current working directory is not inside a Git worktree." >&2
    return 2
  }
  (cd "$root" && pwd -P)
}

luna_primary_engineer_tmp_leaf() {
  printf 'tmp'
}

luna_primary_engineer_is_forbidden_temp_path() {
  local path="$1" tmp_leaf private_prefix var_prefix
  tmp_leaf="$(luna_primary_engineer_tmp_leaf)"
  private_prefix="/$(printf private)/$tmp_leaf"
  var_prefix="/$(printf var)/$tmp_leaf"
  case "$path" in
    "/$tmp_leaf"|"/$tmp_leaf/"*|"$private_prefix"|"$private_prefix/"*|"$var_prefix"|"$var_prefix/"*)
      return 0
      ;;
  esac
  return 1
}

luna_primary_engineer_review_workspace() {
  local root tmp_leaf worktree_tmp skill_root review_root real path
  root="$(luna_primary_engineer_worktree_root)" || return
  tmp_leaf="$(luna_primary_engineer_tmp_leaf)"
  worktree_tmp="$root/$tmp_leaf"
  skill_root="$worktree_tmp/luna-primary-engineer"
  review_root="$skill_root/reviews"

  if [[ -L "$worktree_tmp" ]]; then
    echo "ERROR: worktree temporary directory is a symlink: $worktree_tmp" >&2
    return 2
  fi
  if [[ -e "$worktree_tmp" && ! -d "$worktree_tmp" ]]; then
    echo "ERROR: worktree temporary path is not a directory: $worktree_tmp" >&2
    return 2
  fi
  for path in "$skill_root" "$review_root"; do
    if [[ -L "$path" ]]; then
      echo "ERROR: review workspace component is a symlink: $path" >&2
      return 2
    fi
    if [[ -e "$path" && ! -d "$path" ]]; then
      echo "ERROR: review workspace component is not a directory: $path" >&2
      return 2
    fi
  done
  mkdir -p "$review_root"
  for path in "$worktree_tmp" "$skill_root" "$review_root"; do
    if [[ -L "$path" ]]; then
      echo "ERROR: review workspace component is a symlink: $path" >&2
      return 2
    fi
  done
  real="$(cd "$review_root" && pwd -P)"
  if luna_primary_engineer_is_forbidden_temp_path "$real"; then
    echo "ERROR: review workspace resolves to a system temporary directory: $real" >&2
    return 2
  fi
  if [[ "$real" != "$root/$tmp_leaf/luna-primary-engineer/reviews" ]]; then
    echo "ERROR: review workspace resolves outside the worktree: $real" >&2
    return 2
  fi
  printf '%s\n' "$real"
}

luna_primary_engineer_validate_review_dir() {
  local candidate="$1" review_root resolved relative cursor part
  local -a parts
  review_root="$(luna_primary_engineer_review_workspace)" || return
  [[ -d "$candidate" ]] || {
    echo "ERROR: review directory not found: $candidate" >&2
    return 2
  }
  [[ ! -L "$candidate" ]] || {
    echo "ERROR: review directory must not be a symlink: $candidate" >&2
    return 2
  }
  resolved="$(cd "$candidate" && pwd -P)" || return 2
  [[ "$resolved" != "$review_root" && "$resolved" == "$review_root/"* ]] || {
    echo "ERROR: review directory must be directly below the worktree review workspace: $candidate" >&2
    return 2
  }
  if luna_primary_engineer_is_forbidden_temp_path "$resolved"; then
    echo "ERROR: review directory resolves to a system temporary directory: $resolved" >&2
    return 2
  fi
  relative="${resolved#"$review_root/"}"
  cursor="$review_root"
  IFS='/' read -r -a parts <<< "$relative"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    cursor="$cursor/$part"
    [[ ! -L "$cursor" ]] || {
      echo "ERROR: review path contains a symlink: $cursor" >&2
      return 2
    }
  done
  printf '%s\n' "$resolved"
}

luna_primary_engineer_new_review_dir() {
  local review_root candidate stamp nonce
  review_root="$(luna_primary_engineer_review_workspace)" || return
  for _ in {1..32}; do
    stamp="$(date '+%Y%m%d-%H%M%S')"
    nonce="${RANDOM:-0}-$$"
    candidate="$review_root/$stamp-$nonce"
    if (umask 077 && mkdir "$candidate" 2>/dev/null); then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "ERROR: could not allocate a unique review directory below $review_root." >&2
  return 1
}

# An explicit path is accepted only as one direct child of the worktree review
# workspace. Existing contents are never removed or recursively replaced.
luna_primary_engineer_prepare_review_dir() {
  local input="${1:-}" review_root candidate parent name resolved
  if [[ -z "$input" ]]; then
    luna_primary_engineer_new_review_dir
    return
  fi
  review_root="$(luna_primary_engineer_review_workspace)" || return
  if [[ "$input" == /* ]]; then
    candidate="$input"
  else
    candidate="$PWD/$input"
  fi
  parent="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || {
    echo "ERROR: cannot resolve review directory parent: $input" >&2
    return 2
  }
  name="$(basename "$candidate")"
  [[ -n "$name" && "$name" != . && "$name" != .. && "$name" != */* ]] || {
    echo "ERROR: review directory must be a single directory name below the review workspace: $input" >&2
    return 2
  }
  [[ "$parent" == "$review_root" ]] || {
    echo "ERROR: review directory must be below $review_root: $input" >&2
    return 2
  }
  candidate="$review_root/$name"
  if [[ -e "$candidate" && ! -d "$candidate" ]]; then
    echo "ERROR: review path is not a directory: $candidate" >&2
    return 2
  fi
  if [[ ! -e "$candidate" ]]; then
    (umask 077 && mkdir "$candidate") || {
      echo "ERROR: cannot create review directory without overwriting it: $candidate" >&2
      return 2
    }
  fi
  resolved="$(luna_primary_engineer_validate_review_dir "$candidate")" || return
  printf '%s\n' "$resolved"
}

luna_primary_engineer_resolve_existing_review_dir() {
  local input="$1"
  [[ -n "$input" ]] || { echo "ERROR: review directory is required." >&2; return 2; }
  if [[ "$input" != /* ]]; then input="$PWD/$input"; fi
  luna_primary_engineer_validate_review_dir "$input"
}

luna_primary_engineer_validate_review_descendant_dir() {
  local root="$1" candidate="$2" root_resolved candidate_resolved
  root_resolved="$(luna_primary_engineer_validate_review_dir "$root")" || return
  [[ -d "$candidate" && ! -L "$candidate" ]] || {
    echo "ERROR: review descendant directory is invalid: $candidate" >&2
    return 2
  }
  candidate_resolved="$(cd "$candidate" && pwd -P)" || return 2
  [[ "$candidate_resolved" == "$root_resolved/"* ]] || {
    echo "ERROR: review descendant is outside its review state: $candidate" >&2
    return 2
  }
  if luna_primary_engineer_is_forbidden_temp_path "$candidate_resolved"; then
    echo "ERROR: review descendant resolves to a system temporary directory: $candidate_resolved" >&2
    return 2
  fi
  printf '%s\n' "$candidate_resolved"
}

luna_primary_engineer_require_fresh_state_dir() {
  local state_dir="$1" evidence
  if [[ ! -e "$state_dir" ]]; then return 0; fi
  [[ -d "$state_dir" ]] || {
    echo "ERROR: state path is not a directory: $state_dir" >&2
    return 2
  }
  evidence="$(find "$state_dir" -mindepth 1 -print -quit 2>/dev/null || true)"
  if [[ -n "$evidence" ]]; then
    echo "ERROR: state directory is not empty; existing review data will not be removed or overwritten: $evidence" >&2
    return 2
  fi
}

luna_primary_engineer_require_fresh_state_tree() {
  local root="$1" evidence
  if [[ ! -e "$root" ]]; then return 0; fi
  [[ -d "$root" ]] || {
    echo "ERROR: state tree path is not a directory: $root" >&2
    return 2
  }
  evidence="$(find "$root" -mindepth 1 -print -quit 2>/dev/null || true)"
  if [[ -n "$evidence" ]]; then
    echo "ERROR: state tree is not empty; existing review data will not be removed or overwritten: $evidence" >&2
    return 2
  fi
}

# Run Claude in the foreground and persist separate diagnostics and exit code.
# The result file is intentionally not stdout. In `file` mode Claude is given a
# path-scoped Write permission; in `stdout` mode the caller uses a framed,
# validated handoff because generic Write/Edit/Bash is not enabled.
luna_primary_engineer_run_foreground() {
  local result_file="$1" stdout_file="$2" stderr_file="$3" exit_file="$4" handoff_mode="$5" rc=0
  local api_timeout_ms="${API_TIMEOUT_MS:-600000}"
  local idle_timeout_ms="${CLAUDE_STREAM_IDLE_TIMEOUT_MS:-600000}"
  local byte_idle_timeout_ms="${CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS:-$idle_timeout_ms}"
  local first_byte_timeout_ms="${CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS:-600000}"
  shift 5
  [[ "$handoff_mode" == file || "$handoff_mode" == stdout ]] || {
    echo "ERROR: unknown Claude result handoff mode: $handoff_mode" >&2
    return 2
  }
  if [[ ! "$api_timeout_ms" =~ ^[1-9][0-9]*$ || ! "$idle_timeout_ms" =~ ^[1-9][0-9]*$ || ! "$byte_idle_timeout_ms" =~ ^[1-9][0-9]*$ || ! "$first_byte_timeout_ms" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Claude timeout variables must be positive integers in milliseconds." >&2
    return 2
  fi
  if API_TIMEOUT_MS="$api_timeout_ms" \
    CLAUDE_STREAM_IDLE_TIMEOUT_MS="$idle_timeout_ms" \
    CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS="$byte_idle_timeout_ms" \
    CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS="$first_byte_timeout_ms" \
    LUNA_PRIMARY_ENGINEER_REVIEW_RESULT_PATH="$result_file" \
    claude "$@" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$rc" > "$exit_file"
  return "$rc"
}

luna_primary_engineer_result_handoff_mode() {
  local requested="${LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF:-auto}" help
  case "$requested" in
    file|stdout)
      printf '%s\n' "$requested"
      return 0
      ;;
    auto) ;;
    *)
      echo "ERROR: LUNA_PRIMARY_ENGINEER_CLAUDE_RESULT_HANDOFF must be auto, file, or stdout." >&2
      return 2
      ;;
  esac
  if ! command -v claude >/dev/null 2>&1; then
    printf 'stdout\n'
    return 0
  fi
  help="$(claude --help 2>&1 || true)"
  # Current Claude Code exposes path-scoped permission rules through
  # --allowedTools. If that interface is absent, use the framed safe handoff
  # and do not enable any generic write-capable tool.
  if grep -q -- '--allowedTools' <<< "$help" && grep -q -- '--tools' <<< "$help" && grep -q -- '--disallowedTools' <<< "$help"; then
    printf 'file\n'
  else
    printf 'stdout\n'
  fi
}

luna_primary_engineer_materialize_stdout_result() {
  local stdout_file="$1" result_file="$2"
  [[ -s "$stdout_file" ]] || return 1
  awk '
    $0 == "LUNA_RESULT_BEGIN" { inside=1; found=1; next }
    $0 == "LUNA_RESULT_END" { inside=0; ended=1; next }
    inside { print }
    END { if (!found || !ended) exit 1 }
  ' "$stdout_file" > "$result_file" || return 1
  [[ -s "$result_file" ]]
}

luna_primary_engineer_adopt_result() {
  local source="$1" destination="$2"
  [[ -f "$source" ]] || return 1
  [[ -s "$source" ]] || return 1
  cp -- "$source" "$destination"
}

luna_primary_engineer_review_contract_complete() {
  local file="$1" heading
  [[ -f "$file" && -s "$file" ]] || return 1
  for heading in VERDICT BLOCKERS NONBLOCKING TEST_GAPS PREVIOUS_FINDINGS; do
    grep -Eq "^${heading}:" "$file" || return 1
  done
}

luna_primary_engineer_review_network_failure() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    if grep -Eiq \
      'Request timed out|api\.anthropic\.com|NODE_EXTRA_CA_CERTS|proxy[^[:space:]]*[[:space:]]+intercept|ECONNRESET|ETIMEDOUT|ENETUNREACH|EAI_AGAIN' \
      "$file"; then
      return 0
    fi
  done
  return 1
}

luna_primary_engineer_capture_repo_scope() {
  local cwd="$1" output="$2" tmp_leaf
  tmp_leaf="$(luna_primary_engineer_tmp_leaf)"
  git -C "$cwd" status --porcelain=v1 --untracked-files=all 2>/dev/null | \
    awk -v ignored_prefix="$tmp_leaf/" 'substr($0, 4, length(ignored_prefix)) != ignored_prefix { print }' > "$output"
}

luna_primary_engineer_report_technical_failure() {
  local state_dir="$1" attempt_dir="$2" result_file="$3" stdout_file="$4" stderr_file="$5" exit_file="$6" reason="$7"
  echo "ERROR: Claude review failed to produce a valid designated result file ($reason)." >&2
  echo "ERROR: STATE_DIR=$state_dir" >&2
  echo "ERROR: RESULT_FILE=$result_file" >&2
  echo "ERROR: EXIT_CODE=$(cat "$exit_file" 2>/dev/null || printf 'unknown')" >&2
  echo "ERROR: STAGE=$(cat "$state_dir/stage" 2>/dev/null || printf 'unknown')" >&2
  echo "ERROR: stdout diagnostic: $stdout_file" >&2
  if [[ -s "$stdout_file" ]]; then tail -n 120 "$stdout_file" >&2; else echo "(stdout empty)" >&2; fi
  echo "ERROR: stderr diagnostic: $stderr_file" >&2
  if [[ -s "$stderr_file" ]]; then tail -n 120 "$stderr_file" >&2; else echo "(stderr empty)" >&2; fi
  echo "ERROR: attempt directory: $attempt_dir" >&2
}

luna_primary_engineer_print_state_dir() {
  local state_dir="$1" stage rc reason pid
  [[ -d "$state_dir" ]] || { echo "ERROR: missing state directory: $state_dir" >&2; return 2; }
  stage="$(cat "$state_dir/stage" 2>/dev/null || printf 'unknown')"
  rc="$(cat "$state_dir/run_exit_code" 2>/dev/null || printf '')"
  reason="$(cat "$state_dir/blocked_reason" 2>/dev/null || printf '')"
  pid="$(cat "$state_dir/background_pid" 2>/dev/null || printf '')"
  printf 'STATE=%s\nEXIT_CODE=%s\nBLOCKED_REASON=%s\nBACKGROUND_PID=%s\nSTATE_DIR=%s\n' "$stage" "$rc" "$reason" "$pid" "$state_dir"
  if [[ "$stage" == running || "$stage" == queued ]] && [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    if kill -0 "$pid" 2>/dev/null; then printf 'BACKGROUND_ALIVE=1\n'; else printf 'BACKGROUND_ALIVE=0\n'; fi
  fi
  case "$stage" in
    done) return 0 ;;
    running|queued|seed_running|branches_running) return 10 ;;
    blocked) return 11 ;;
    failed) return 12 ;;
    *) return 14 ;;
  esac
}
