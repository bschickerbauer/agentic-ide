#!/usr/bin/env bash
# install.sh — link the 1Password agentic-secrets loader into ~/.config/agentic and hook it into ~/.zshrc.
#
# Idempotent. Safe to re-run. It does NOT touch 1Password, ~/.claude.json, or the legacy
# ~/.config/env/*.env files; the cut-over is a manual step (integration-plan.md, Phase 2).
# Runs on macOS and Linux/WSL2 (bash >= 3.2). Requires: op (1Password CLI), zsh.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTIC_HOME="${AGENTIC_HOME:-$HOME/.config/agentic}"
ZSHRC="${ZSHRC:-$HOME/.zshrc}"
SOURCE_LINE='[ -r "$HOME/.config/agentic/agentic-secrets.zsh" ] && source "$HOME/.config/agentic/agentic-secrets.zsh"'
LEGACY_ENV_FILES=("$HOME/.config/env/anthropic_foundry.env" "$HOME/.config/env/openai_foundry.env")

log() { printf '%s\n' "$*"; }

command -v op >/dev/null 2>&1 || {
  log "1Password CLI (op) not found."
  log "  macOS: brew install 1password-cli   |   WSL2: see integration-plan.md, section Team notes"
  exit 1
}
command -v zsh >/dev/null 2>&1 || { log "zsh not found."; exit 1; }

mkdir -p "$AGENTIC_HOME"
chmod 700 "$AGENTIC_HOME"

# Loader is a symlink so repo updates apply immediately.
ln -sfn "$HERE/zsh/agentic-secrets.zsh" "$AGENTIC_HOME/agentic-secrets.zsh"
log "linked  $AGENTIC_HOME/agentic-secrets.zsh -> $HERE/zsh/agentic-secrets.zsh"

# Env files are copies so vault/item names and the Foundry resource can be edited locally.
for f in secrets.env config.env; do
  if [ ! -e "$AGENTIC_HOME/$f" ]; then
    cp "$HERE/templates/$f" "$AGENTIC_HOME/$f"
    chmod 600 "$AGENTIC_HOME/$f"
    log "created $AGENTIC_HOME/$f (from template; review vault/item names and placeholders)"
  else
    log "kept    $AGENTIC_HOME/$f"
  fi
done

# Migrate NON-secret export lines from legacy env files into config.env (append if key missing).
for legacy in "${LEGACY_ENV_FILES[@]}"; do
  [ -r "$legacy" ] || continue
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*$/\2/p')"
    [ -n "$key" ] || continue
    case "$key" in *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*) continue ;; esac   # secrets never move here
    if ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$AGENTIC_HOME/config.env"; then
      printf '\n# migrated from %s\n%s\n' "$legacy" "$line" >> "$AGENTIC_HOME/config.env"
      log "migrated $key from $(basename "$legacy") -> config.env"
    fi
  done < "$legacy"
done

# Hook into ~/.zshrc once; keep a backup of the original.
touch "$ZSHRC"
if grep -qF 'agentic-secrets.zsh' "$ZSHRC"; then
  log "kept    source line in $ZSHRC"
else
  cp "$ZSHRC" "$ZSHRC.bak-$(date +%Y%m%d-%H%M%S)"
  printf '\n# 1Password-backed secrets for agentic CLIs (AgenticIDE/secrets-management)\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  log "added   source line to $ZSHRC (backup written)"
fi

# Point out what still needs a manual decision.
if grep -nE 'config/env/(anthropic|openai)_foundry\.env' "$HOME/.zshrc" "$HOME/.zprofile" 2>/dev/null; then
  log "NOTE: legacy env sourcing above is still active. Remove it after the cut-over (plan, Phase 2)."
fi
if grep -q '<your-foundry-resource-name>' "$AGENTIC_HOME/config.env" 2>/dev/null; then
  log "NOTE: set ANTHROPIC_FOUNDRY_RESOURCE in $AGENTIC_HOME/config.env"
fi

log ""
log "Done. Open a new shell and run:  secrets-status   then   claude  (and /status inside Claude Code)"
