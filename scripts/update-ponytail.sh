#!/usr/bin/env bash
set -euo pipefail

CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
PONYTAIL_DEST="${CODEX_DIR}/luna-orchestrator/deps/ponytail"
SKILL_DEST="${HOME}/.agents/skills/luna-orchestrator"
PONYTAIL_SKILL="$PONYTAIL_DEST/skills/ponytail/SKILL.md"

if [[ ! -d "$PONYTAIL_DEST/.git" ]]; then
  echo "ERROR: $PONYTAIL_DEST is not a git checkout." >&2
  echo "Re-run scripts/install.sh, or update your local dependency source manually." >&2
  exit 1
fi

git -C "$PONYTAIL_DEST" pull --ff-only
if [[ ! -f "$PONYTAIL_SKILL" ]]; then
  echo "ERROR: upstream Ponytail SKILL.md missing after update" >&2
  exit 1
fi
mkdir -p "$SKILL_DEST/references/ponytail"
cp "$PONYTAIL_SKILL" "$SKILL_DEST/references/ponytail/SKILL.md"
printf 'Ponytail updated: '
git -C "$PONYTAIL_DEST" rev-parse --short HEAD
echo "Primary reference refreshed. Restart Codex Desktop / start a new session to pick it up reliably."
