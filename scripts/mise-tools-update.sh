#!/usr/bin/env bash
# Update mise itself + every "live" tool mise manages (node, ripgrep,
# claude-code, codex, ...). Baked into the image (immutable, always the same
# regardless of which volume is mounted) but its target state is entirely on
# the persistent $HOME volume: the mise binary, its installs and its
# config.toml all live under $HOME/.local, not in the container filesystem.
#
# Meant to run as the unprivileged `hermes` user (uid 10000) — the same user
# that owns the mise installs — from a cron/scheduled task. Prints a compact
# report; the caller (agent, watchdog) decides whether anything is worth
# surfacing. No secrets read or written here.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

echo "=== VERSIONI PRIMA ==="
mise ls 2>/dev/null
BEFORE=$(mise ls 2>/dev/null)
MISE_BEFORE=$(mise --version 2>/dev/null)

echo
echo "=== MISE SELF-UPDATE ==="
mise self-update -y 2>&1

echo
echo "=== MISE UPGRADE (tool pinnati a 'latest'/'lts') ==="
mise upgrade -y 2>&1

echo
echo "=== VERSIONI DOPO ==="
mise ls 2>/dev/null
AFTER=$(mise ls 2>/dev/null)
MISE_AFTER=$(mise --version 2>/dev/null)

# The npm backend sometimes skips claude-code's postinstall (native binary
# never downloaded) -> re-run it by hand if the CLI doesn't actually work.
echo
echo "=== FIX POSTINSTALL (claude-code nativo) ==="
if ! mise exec -- claude --version >/dev/null 2>&1; then
  echo "  claude non funzionante, cerco install.cjs..."
  INSTALL_CJS=$(find "$HOME/.local/share/mise/installs/npm-anthropic-ai-claude-code" -iname "install.cjs" 2>/dev/null | head -1)
  if [ -n "$INSTALL_CJS" ]; then
    ( cd "$(dirname "$INSTALL_CJS")" && node install.cjs ) 2>&1
    echo "  postinstall rilanciato da: $INSTALL_CJS"
  else
    echo "  ERRORE: install.cjs non trovato"
  fi
else
  echo "  ok, nessun intervento necessario"
fi

echo
echo "=== VERIFICA FUNZIONALE ==="
mise exec -- claude --version 2>&1 | sed 's/^/  claude: /'
mise exec -- codex --version 2>&1 | sed 's/^/  codex : /'

echo
echo "=== DIFF ==="
if [ "$BEFORE" != "$AFTER" ]; then
  echo "  CAMBIATO:"
  diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/  /'
else
  echo "  nessuna modifica ai tool"
fi
if [ "$MISE_BEFORE" != "$MISE_AFTER" ]; then
  echo "  mise stesso: $MISE_BEFORE -> $MISE_AFTER"
fi
