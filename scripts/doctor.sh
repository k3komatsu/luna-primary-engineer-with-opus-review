#!/usr/bin/env bash
set -euo pipefail

CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
SKILL="${HOME}/.agents/skills/luna-primary-engineer/SKILL.md"
ROOT_PONYTAIL="${HOME}/.agents/skills/luna-primary-engineer/references/ponytail/SKILL.md"
PRIVATE_PONYTAIL="${CODEX_DIR}/luna-primary-engineer/deps/ponytail/skills/ponytail/SKILL.md"
AGENTS="${CODEX_DIR}/agents"
FAIL=0

check_file() {
  if [[ -f "$1" ]]; then printf 'OK   %s\n' "$1"; else printf 'MISS %s\n' "$1"; FAIL=1; fi
}

check_file "$SKILL"
check_file "$ROOT_PONYTAIL"
check_file "$PRIVATE_PONYTAIL"
for f in claude-common.sh claude-job.sh claude-review.sh claude-panel.sh self-test.sh; do
  check_file "${HOME}/.agents/skills/luna-primary-engineer/scripts/$f"
done
if [[ -f "${HOME}/.agents/skills/luna-primary-engineer/scripts/self-test.sh" ]] && bash "${HOME}/.agents/skills/luna-primary-engineer/scripts/self-test.sh" >/dev/null 2>&1; then
  echo "OK   Claude helper self-test"
else
  echo "FAIL Claude helper self-test"; FAIL=1
fi
for f in luna_worker luna_reviewer sol_advisor astra_expert; do check_file "$AGENTS/$f.toml"; done

if [[ -f "$AGENTS/luna_explorer.toml" ]]; then echo "FAIL obsolete luna_explorer still installed"; FAIL=1; else echo "OK   obsolete luna_explorer absent"; fi

if [[ -f "$AGENTS/luna_worker.toml" ]] && grep -Fq "$PRIVATE_PONYTAIL" "$AGENTS/luna_worker.toml"; then
  echo "OK   luna_worker points to private Ponytail skill"
else
  echo "FAIL luna_worker does not point to private Ponytail skill"; FAIL=1
fi

for f in luna_reviewer sol_advisor astra_expert; do
  if [[ -f "$AGENTS/$f.toml" ]] && grep -Fqi '[[skills.config]]' "$AGENTS/$f.toml"; then
    echo "FAIL $f unexpectedly has an explicit skill attachment"; FAIL=1
  else
    echo "OK   $f has no explicit Ponytail skill attachment"
  fi
done

for f in luna_worker luna_reviewer; do
  if [[ -f "$AGENTS/$f.toml" ]] && grep -Fq 'model_reasoning_effort = "max"' "$AGENTS/$f.toml"; then
    echo "OK   $f uses max reasoning"
  else
    echo "FAIL $f is not max reasoning"; FAIL=1
  fi
done

if grep -Rqs 'model_reasoning_effort = "medium"' "$AGENTS"/luna_*.toml 2>/dev/null; then
  echo "FAIL a Luna custom agent still uses medium reasoning"; FAIL=1
else
  echo "OK   no installed Luna custom agent uses medium reasoning"
fi

if command -v claude >/dev/null 2>&1; then
  echo "OK   claude command found: $(command -v claude)"
  VER="$(claude --version 2>/dev/null | head -n1 || true)"
  [[ -n "$VER" ]] && echo "INFO Claude Code version: $VER"
  if claude auth status >/dev/null 2>&1; then
    echo "OK   Claude Code auth status succeeds"
  else
    echo "WARN Claude Code installed but auth status failed; fallback Luna review will be used in auto mode"
  fi
  HELP="$(claude --help 2>&1 || true)"
  for flag in --print --effort --tools --disallowedTools --append-system-prompt --disable-slash-commands --no-chrome; do
    if grep -q -- "$flag" <<<"$HELP"; then
      echo "OK   Claude Code supports $flag"
    else
      echo "FAIL Claude Code lacks $flag; foreground review cannot run"
      FAIL=1
    fi
  done
  if grep -q -- '--permission-prompts' <<<"$HELP"; then echo "OK   Claude Code supports --permission-prompts"; else echo "WARN Claude Code lacks --permission-prompts; read-only reviews may pause for approval"; fi
  if grep -q -- 'dontAsk' <<<"$HELP"; then echo "OK   Claude Code supports dontAsk permission mode"; else echo "WARN Claude Code lacks dontAsk permission mode; read-only reviews may enter plan mode"; fi
  if grep -q -- '--session-id' <<<"$HELP"; then echo "OK   Claude Code supports explicit session IDs"; else echo "FAIL Claude Code lacks --session-id; sticky re-review cannot start"; FAIL=1; fi
  if grep -q -- '--resume' <<<"$HELP"; then echo "OK   Claude Code supports session resume"; else echo "FAIL Claude Code lacks --resume; sticky re-review cannot continue"; FAIL=1; fi
  if grep -q -- '--no-session-persistence' <<<"$HELP"; then echo "OK   Claude Code supports non-persistent foreground sessions"; else echo "WARN Claude Code lacks --no-session-persistence; foreground runs may leave session state"; fi
else
  echo "WARN Claude Code not installed; fallback Luna review will be used"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then echo "WARN ANTHROPIC_API_KEY is set; verify whether Claude usage is API-billed"; fi
if [[ "${DISABLE_PROMPT_CACHING:-0}" == "1" || "${DISABLE_PROMPT_CACHING_OPUS:-0}" == "1" ]]; then
  echo "WARN Opus prompt caching is disabled; seed-and-fork still works functionally but loses its main cache-cost benefit"
fi
if [[ -n "${LUNA_PRIMARY_ENGINEER_CLAUDE_MAX_TURNS_REVIEW:-}" || -n "${LUNA_PRIMARY_ENGINEER_CLAUDE_MAX_TURNS_PANEL:-}" ]]; then
  echo "INFO legacy max-turn environment variables are set but the foreground helpers do not use them"
fi
if [[ -f "${HOME}/.config/ponytail/config.json" ]] && grep -Eqi '"defaultMode"[[:space:]]*:[[:space:]]*"(lite|full|ultra)"' "${HOME}/.config/ponytail/config.json"; then
  echo "WARN global Ponytail default appears active; it may reduce reviewer/advisor independence"
fi

if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
  case "$PWD/" in
    "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*)
      echo "WARN current repository is under a macOS privacy-sensitive folder; Claude foreground sessions may be unable to read it"
      ;;
  esac
fi

exit "$FAIL"
