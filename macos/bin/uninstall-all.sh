#!/usr/bin/env bash
# uninstall-all.sh - reverse install-all.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DAEMON_LABEL="com.claude-restorer.daemon"
RESTORE_LABEL="com.claude-restorer.restore"

KEEP_SHIM=0
KEEP_STATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-shim)  KEEP_SHIM=1 ;;
    --keep-state) KEEP_STATE=1 ;;
    -h|--help)
      grep '^#' "$0" | head -10 | sed 's/^# *//'
      echo
      echo "Flags:"
      echo "  --keep-shim    leave the alias in ~/.zshrc et al."
      echo "  --keep-state   preserve ~/.claude-restorer/"
      exit 0
      ;;
    *) echo "uninstall-all: unknown flag '$1'" >&2; exit 64 ;;
  esac
  shift
done

# ---------- bootout LaunchAgents ----------
unload_agent() {
  local label="$1"
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    echo "  unloaded $label"
  else
    echo "  $label was not loaded"
  fi
  local plist="$LAUNCH_AGENTS/$label.plist"
  if [[ -f "$plist" ]]; then
    rm -f "$plist"
    echo "  removed $plist"
  fi
}

unload_agent "$RESTORE_LABEL"
unload_agent "$DAEMON_LABEL"

# ---------- alias ----------
if (( KEEP_SHIM == 0 )); then
  if [[ -x "$SCRIPT_DIR/uninstall-shim.sh" ]]; then
    bash "$SCRIPT_DIR/uninstall-shim.sh"
  else
    echo "  WARNING: uninstall-shim.sh missing or not executable" >&2
  fi
else
  echo "  kept claude alias (--keep-shim)"
fi

# ---------- state dir ----------
if (( KEEP_STATE == 0 )) && [[ -d "$HOME/.claude-restorer" ]]; then
  rm -rf "$HOME/.claude-restorer"
  echo "  removed $HOME/.claude-restorer"
elif (( KEEP_STATE == 1 )); then
  echo "  kept $HOME/.claude-restorer (--keep-state)"
fi

echo
echo "Uninstall complete."
