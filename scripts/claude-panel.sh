#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=claude-common.sh
source "$SCRIPT_DIR/claude-common.sh"

usage() {
  cat <<'TXT'
Usage:
  claude-panel.sh start    CONTEXT_FILE ROLES_DIR [OUTPUT_DIR]
  claude-panel.sh status   OUTPUT_DIR
  claude-panel.sh advance  OUTPUT_DIR
  claude-panel.sh collect  OUTPUT_DIR
  claude-panel.sh followup BRANCH_DIR DELTA_FILE

ROLES_DIR contains 2..6 *.md or *.txt role files. Panel state is stored below
the current worktree's tmp/luna-primary-engineer/reviews directory. The panel
seed and roles run sequentially in the foreground. Never stop an Opus process
after launch. There is no automatic retry or duplicate launch, and every role
consumes Claude usage.

A real Opus call from a network-restricted Codex sandbox may require explicit
escalation to network-enabled command execution before launch.
The default model is explicitly `claude-opus-5-5`; set
`LUNA_PRIMARY_ENGINEER_CLAUDE_MODEL` only when an intentional override is
needed.
If status reports process liveness as permission_denied, ps was denied;
escalate execution permission and rerun status without changing the review
state. A different unknown value means process-list inspection failed for an
other reason and also must not trigger a relaunch.
TXT
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
MODE="$1"
shift

require_claude() {
  if ! luna_primary_engineer_claude_available; then
    echo "ERROR: Claude Code is unavailable, unauthenticated, or disabled (LUNA_PRIMARY_ENGINEER_CLAUDE=off)." >&2
    exit 3
  fi
  luna_primary_engineer_warn_billing
}

MODEL="${LUNA_PRIMARY_ENGINEER_CLAUDE_MODEL:-claude-opus-5-5}"
EFFORT="${LUNA_PRIMARY_ENGINEER_CLAUDE_PANEL_EFFORT:-max}"
SYSTEM_PROMPT="$ROOT_DIR/references/claude/panel-system.md"
SYSTEM_PROMPT_TEXT="$(cat "$SYSTEM_PROMPT")"
HANDOFF_MODE=""

build_base_args() {
  local result_file="$1" handoff_mode="$2" tools="Read,Glob,Grep"
  if [[ "$handoff_mode" == file ]]; then tools="$tools,Write"; fi
  BASE_ARGS=(
    --print --model "$MODEL" --effort "$EFFORT"
    --permission-mode dontAsk --permission-prompts none --tools "$tools"
  )
  if [[ "$handoff_mode" == file ]]; then
    # result_file is absolute; the extra slash makes the Edit rule absolute.
    BASE_ARGS+=(--allowedTools "Edit(/$result_file)" --disallowedTools Bash "mcp__*")
  else
    BASE_ARGS+=(--disallowedTools Bash "mcp__*")
  fi
  BASE_ARGS+=(--append-system-prompt "$SYSTEM_PROMPT_TEXT" --disable-slash-commands --no-chrome --no-session-persistence)
}

result_instruction() {
  local result_file="$1" handoff_mode="$2"
  if [[ "$handoff_mode" == file ]]; then
    cat <<EOF
Write the complete panel artifact to this exact absolute path: $result_file
This is the only file you may write. Do not edit the context, role files,
source/, tests/, docs/, configuration, state metadata, or any other path.
stdout may be empty; the wrapper validates the designated file after exit.
EOF
  else
    cat <<'EOF'
The available tools are read-only. Do not create or edit files. Emit the
complete artifact between the exact lines LUNA_RESULT_BEGIN and
LUNA_RESULT_END; the wrapper will adopt that framed handoff into the result
file. Ordinary stdout is not a result.
EOF
  fi
}

run_foreground() {
  local result_file="$1" stdout_file="$2" stderr_file="$3" exit_file="$4"
  local add_dir="$5" prompt="$6"
  shift 6
  build_base_args "$result_file" "$HANDOFF_MODE"
  prompt="$prompt

$(result_instruction "$result_file" "$HANDOFF_MODE")"
  mkdir -p "$(dirname "$result_file")" "$(dirname "$stdout_file")" "$(dirname "$stderr_file")" "$(dirname "$exit_file")"
  luna_primary_engineer_run_foreground \
    "$result_file" "$stdout_file" "$stderr_file" "$exit_file" \
    "$(dirname "$exit_file")/runner_pid" "$(dirname "$exit_file")/claude_pid" "$HANDOFF_MODE" \
    "${BASE_ARGS[@]}" "$@" --add-dir "$add_dir" -- "$prompt"
}

next_child_dir() {
  local parent="$1" prefix="$2" n=1 candidate
  while :; do
    candidate="$parent/$prefix-$n"
    if [[ ! -e "$candidate" ]]; then
      (umask 077 && mkdir "$candidate")
      printf '%s\n' "$candidate"
      return 0
    fi
    n=$((n + 1))
  done
}

run_artifact() {
  local state_dir="$1" prompt="$2" add_dir="$3" kind="$4" review_cwd="$5" rc=0
  local attempt_dir result_file stdout_file stderr_file exit_file before after
  shift 5
  attempt_dir="$(next_child_dir "$state_dir" attempt)"
  result_file="$attempt_dir/reviewer-result.md"
  stdout_file="$attempt_dir/stdout.txt"
  stderr_file="$attempt_dir/stderr.txt"
  exit_file="$attempt_dir/exit_code"
  printf '%s\n' "$attempt_dir" > "$state_dir/last_attempt"
  printf 'running\n' > "$state_dir/stage"
  rm -f "$state_dir/blocked_reason"
  luna_primary_engineer_clear_user_confirmation "$state_dir"
  before="$attempt_dir/repository-before.txt"
  after="$attempt_dir/repository-after.txt"
  luna_primary_engineer_capture_repo_scope "$review_cwd" "$before"
  if run_foreground "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "$add_dir" "$prompt" "$@"; then rc=0; else rc=$?; fi
  if [[ "$HANDOFF_MODE" == stdout && ! -s "$result_file" ]]; then
    luna_primary_engineer_materialize_stdout_result "$stdout_file" "$result_file" || true
  fi
  luna_primary_engineer_capture_repo_scope "$review_cwd" "$after"
  cp -- "$exit_file" "$state_dir/run_exit_code"
  if ! cmp -s "$before" "$after"; then
    printf 'failed\n' > "$state_dir/stage"
    luna_primary_engineer_require_user_confirmation "$state_dir" reviewer_boundary_escape
    luna_primary_engineer_report_technical_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "reviewer write escaped the read-only implementation boundary"
    return 19
  fi
  if (( rc != 0 )); then
    if luna_primary_engineer_review_network_failure "$stdout_file" "$stderr_file"; then
      printf 'blocked\n' > "$state_dir/stage"
      printf 'network\n' > "$state_dir/blocked_reason"
      luna_primary_engineer_require_user_confirmation "$state_dir" network_failure
      luna_primary_engineer_report_technical_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "Claude transport/API failure"
      return 11
    fi
    printf 'failed\n' > "$state_dir/stage"
    luna_primary_engineer_require_user_confirmation "$state_dir" claude_exited_without_valid_result
    luna_primary_engineer_report_technical_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "Claude exited non-zero"
    return "$rc"
  fi
  case "$kind" in
    seed)
      if ! grep -Fqx 'SEED_READY' "$result_file"; then
        printf 'failed\n' > "$state_dir/stage"
        luna_primary_engineer_require_user_confirmation "$state_dir" invalid_seed_result
        luna_primary_engineer_report_technical_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "seed artifact is not exactly SEED_READY"
        return 18
      fi
      ;;
    artifact)
      if [[ ! -s "$result_file" ]]; then
        printf 'failed\n' > "$state_dir/stage"
        luna_primary_engineer_require_user_confirmation "$state_dir" empty_panel_result
        luna_primary_engineer_report_technical_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "panel artifact is empty"
        return 18
      fi
      ;;
    *) echo "ERROR: unknown panel artifact kind: $kind" >&2; return 2 ;;
  esac
  luna_primary_engineer_adopt_result "$result_file" "$state_dir/result.txt" || {
    printf 'failed\n' > "$state_dir/stage"
    luna_primary_engineer_require_user_confirmation "$state_dir" result_adoption_failed
    luna_primary_engineer_report_technical_failure "$state_dir" "$attempt_dir" "$result_file" "$stdout_file" "$stderr_file" "$exit_file" "designated result could not be adopted"
    return 18
  }
  luna_primary_engineer_clear_user_confirmation "$state_dir"
  printf 'done\n' > "$state_dir/stage"
}

case "$MODE" in
  start)
    require_claude
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    CONTEXT="$1"; ROLES_DIR="$2"
    [[ -f "$CONTEXT" ]] || { echo "ERROR: context not found: $CONTEXT" >&2; exit 2; }
    [[ -d "$ROLES_DIR" ]] || { echo "ERROR: roles directory not found: $ROLES_DIR" >&2; exit 2; }
    shopt -s nullglob
    ROLES=("$ROLES_DIR"/*.md "$ROLES_DIR"/*.txt)
    COUNT=${#ROLES[@]}
    (( COUNT >= 2 )) || { echo "ERROR: panel requires at least 2 role files; got $COUNT" >&2; exit 2; }
    (( COUNT <= 6 )) || { echo "ERROR: panel hard limit is 6 role files; got $COUNT" >&2; exit 2; }
    OUTPUT="$(luna_primary_engineer_prepare_review_dir "${3:-}")" || exit $?
    luna_primary_engineer_require_fresh_state_tree "$OUTPUT" || exit $?
    HANDOFF_MODE="$(luna_primary_engineer_result_handoff_mode)" || exit $?
    (umask 077 && mkdir "$OUTPUT/seed" "$OUTPUT/roles")
    cp -- "$CONTEXT" "$OUTPUT/context.md"
    CONTEXT_ABS="$(cd "$OUTPUT" && pwd -P)/context.md"
    printf '%s\n' "$(pwd -P)" > "$OUTPUT/cwd"
    printf 'panel\n' > "$OUTPUT/kind"
    printf '%s\n' "$HANDOFF_MODE" > "$OUTPUT/handoff_mode"
    printf 'seed_running\n' > "$OUTPUT/stage"
    : > "$OUTPUT/role-names.txt"
    for role in "${ROLES[@]}"; do
      base="$(basename "$role")"; stem="${base%.*}"
      cp -- "$role" "$OUTPUT/roles/$stem.md"
      printf '%s\n' "$stem" >> "$OUTPUT/role-names.txt"
      mkdir "$OUTPUT/$stem"
      printf '%s\n' "$OUTPUT" > "$OUTPUT/$stem/panel_root"
    done
    printf 'running\n' > "$OUTPUT/seed/stage"
    if run_artifact "$OUTPUT/seed" \
      "LUNA_PRIMARY_ENGINEER_SHARED_SEED_MODE. This is a foreground factual-context load. Read the shared context at: $CONTEXT_ABS . Do not diagnose or propose a fix. Write exactly SEED_READY to the designated result file." \
      "$OUTPUT" seed "$(pwd -P)"; then
      :
    else
      seed_rc=$?
      printf 'failed\n' > "$OUTPUT/stage"
      exit "$seed_rc"
    fi
    printf 'seed_done\n' > "$OUTPUT/stage"
    echo "SEED_READY"; echo "OUTPUT_DIR=$OUTPUT"; echo "NEXT=run claude-panel.sh advance $OUTPUT"
    ;;

  status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    echo "STAGE=$(cat "$OUTPUT/stage" 2>/dev/null || echo unknown)"
    echo "[seed]"; luna_primary_engineer_print_state_dir "$OUTPUT/seed" || true
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      if [[ -d "$OUTPUT/$stem" ]]; then echo "[$stem]"; luna_primary_engineer_print_state_dir "$OUTPUT/$stem" || true; fi
    done < "$OUTPUT/role-names.txt"
    ;;

  advance)
    require_claude
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    [[ -f "$OUTPUT/seed/result.txt" && "$(cat "$OUTPUT/stage" 2>/dev/null || true)" == seed_done ]] || { echo "ERROR: foreground seed is not complete: $OUTPUT" >&2; exit 10; }
    HAS_ANY=0; MISSING=0
    while IFS= read -r stem; do [[ -n "$stem" ]] || continue; if [[ -f "$OUTPUT/$stem/result.txt" ]]; then HAS_ANY=1; else MISSING=1; fi; done < "$OUTPUT/role-names.txt"
    if (( HAS_ANY == 1 )); then
      (( MISSING == 0 )) || { echo "ERROR: panel is partially complete; inspect results before rerunning." >&2; exit 15; }
      echo "INFO: all panel roles already ran; no action taken."; exit 0
    fi
    CONTEXT_ABS="$(cd "$OUTPUT" && pwd -P)/context.md"; SEED_ABS="$OUTPUT/seed/result.txt"; HANDOFF_MODE="$(cat "$OUTPUT/handoff_mode")"; FAIL=0
    printf 'branches_running\n' > "$OUTPUT/stage"
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      D="$OUTPUT/$stem"; ROLE_ABS="$(cd "$OUTPUT" && pwd -P)/roles/$stem.md"
      if run_artifact "$D" \
        "You are an independent foreground panel expert. Read the shared context at: $CONTEXT_ABS , the neutral seed result at: $SEED_ABS , and your assigned role at: $ROLE_ABS . Analyze strictly from that role. Do not seek consensus or edit files; finish with the compact panel artifact from your system instructions." \
        "$OUTPUT" artifact "$(cat "$OUTPUT/cwd")"; then
        cp -- "$D/result.txt" "$D/initial-result.txt"
      else
        code=$?; (( FAIL == 0 )) && FAIL="$code"
        if [[ -f "$D/failure_reason" ]]; then cp -- "$D/failure_reason" "$OUTPUT/failure_reason"; fi
        if [[ -f "$D/user_confirmation_required" ]]; then cp -- "$D/user_confirmation_required" "$OUTPUT/user_confirmation_required"; fi
        # Do not spend another independent panel turn after any technical
        # failure; inspect the failed role and require an explicit rerun.
        break
      fi
    done < "$OUTPUT/role-names.txt"
    if (( FAIL != 0 )); then printf 'failed\n' > "$OUTPUT/stage"; exit "$FAIL"; fi
    printf 'done\n' > "$OUTPUT/stage"; "$0" collect "$OUTPUT"
    ;;

  collect)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    OUTPUT="$(luna_primary_engineer_resolve_existing_review_dir "$1")" || exit $?
    [[ -f "$OUTPUT/role-names.txt" ]] || { echo "ERROR: invalid panel directory: $OUTPUT" >&2; exit 2; }
    printf 'role\tstate\tresult\n' > "$OUTPUT/manifest.tsv"
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      D="$OUTPUT/$stem"
      [[ "$(cat "$D/stage" 2>/dev/null || true)" == done && -f "$D/result.txt" ]] || { echo "ERROR: panel role $stem is not complete." >&2; exit 10; }
      printf '%s\tdone\t%s\n' "$stem" "$D/result.txt" >> "$OUTPUT/manifest.tsv"
    done < "$OUTPUT/role-names.txt"
    cat "$OUTPUT/manifest.tsv"
    while IFS= read -r stem; do [[ -n "$stem" ]] || continue; echo "--- $stem ---"; cat "$OUTPUT/$stem/result.txt"; done < "$OUTPUT/role-names.txt"
    ;;

  followup)
    require_claude
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    BRANCH="$(luna_primary_engineer_validate_review_descendant_dir "$(cat "$1/panel_root" 2>/dev/null || dirname "$1")" "$1")" || exit $?
    DELTA="$2"
    [[ -f "$BRANCH/result.txt" && "$(cat "$BRANCH/stage" 2>/dev/null || true)" == done ]] || { echo "ERROR: completed foreground branch not found: $BRANCH" >&2; exit 10; }
    [[ -f "$DELTA" ]] || { echo "ERROR: delta not found: $DELTA" >&2; exit 2; }
    PANEL_ROOT="$(cat "$BRANCH/panel_root")"; HANDOFF_MODE="$(cat "$PANEL_ROOT/handoff_mode")"
    ROUND="$(next_child_dir "$BRANCH" followup)"
    cp -- "$DELTA" "$ROUND/followup.md"; cp -- "$BRANCH/result.txt" "$ROUND/previous-result.txt"; printf '%s\n' "$PANEL_ROOT" > "$ROUND/panel_root"
    CHILD_ABS="$(cd "$ROUND" && pwd -P)"
    if run_artifact "$ROUND" \
      "Continue this panel expert's work in a fresh foreground turn. Read the previous result at: $CHILD_ABS/previous-result.txt and the new delta/question at: $CHILD_ABS/followup.md . Stay within the same decision domain, do not ask questions or edit files, and finish with the compact panel artifact from your system instructions." \
      "$PANEL_ROOT" artifact "$(cat "$PANEL_ROOT/cwd")"; then
      cp -- "$ROUND/result.txt" "$BRANCH/result.txt"; cp -- "$ROUND/run_exit_code" "$BRANCH/run_exit_code"
      luna_primary_engineer_clear_user_confirmation "$BRANCH"
      printf 'done\n' > "$BRANCH/stage"; cat "$BRANCH/result.txt"
    else
      code=$?; printf 'failed\n' > "$ROUND/stage"; printf 'failed\n' > "$BRANCH/stage"
      if [[ -f "$ROUND/failure_reason" ]]; then cp -- "$ROUND/failure_reason" "$BRANCH/failure_reason"; fi
      if [[ -f "$ROUND/user_confirmation_required" ]]; then cp -- "$ROUND/user_confirmation_required" "$BRANCH/user_confirmation_required"; fi
      exit "$code"
    fi
    ;;

  *) usage >&2; exit 2 ;;
esac
