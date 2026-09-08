#!/usr/bin/env bash
set -euo pipefail

CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
SKILL_DEST="${HOME}/.agents/skills/luna-primary-engineer"
AGENT_DEST="${CODEX_DIR}/agents"
PRIVATE_DATA="${CODEX_DIR}/luna-primary-engineer"

rm -rf "$SKILL_DEST" "$PRIVATE_DATA"
for f in luna_worker.toml luna_reviewer.toml sol_advisor.toml astra_expert.toml luna_explorer.toml; do
  rm -f "$AGENT_DEST/$f"
done

echo "Removed Luna Primary Engineer v6.6, custom agents, runtime/session metadata, obsolete explorer, and private Ponytail dependency."
echo "No Codex config.toml, AGENTS.md, Claude Code installation/authentication, or separately installed Ponytail plugin was modified."
