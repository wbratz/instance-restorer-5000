#!/usr/bin/env bash
# install-all.sh - one-shot macOS installer for instance-restorer-5000.
#
# Per-user install, no sudo:
#   1. Calls install-shim.sh to wire the `claude` alias into ~/.zshrc
#      (and ~/.bashrc / ~/.bash_profile if they exist).
#   2. Generates two LaunchAgent plists in ~/Library/LaunchAgents/ from
#      templates in plists/, substituting absolute paths.
#   3. launchctl bootstrap both agents into the user's GUI session.
#
# Idempotent: re-running unloads first via launchctl bootout (ignoring
# any "not loaded" errors), then re-bootstraps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root = two levels up from this script's directory (macos/bin -> repo root).
INSTALL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
USERNAME="$(whoami)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
DAEMON_LABEL="com.claude-restorer.daemon"
RESTORE_LABEL="com.claude-restorer.restore"

shim_installer="$SCRIPT_DIR/install-shim.sh"
daemon_template="$SCRIPT_DIR/plists/daemon.plist.template"
restore_template="$SCRIPT_DIR/plists/restore.plist.template"

for f in "$shim_installer" "$daemon_template" "$restore_template" \
         "$SCRIPT_DIR/snapshot-daemon.sh" "$SCRIPT_DIR/restore.sh"; do
  if [[ ! -f "$f" ]]; then
    echo "install-all: missing component: $f" >&2
    exit 1
  fi
done

# ---------- jq pre-flight ----------
if ! command -v jq >/dev/null 2>&1; then
  echo "install-all: jq is required by snapshot-daemon.sh and restore.sh." >&2
  echo "  Install via:  brew install jq" >&2
  echo "  Then re-run this installer." >&2
  exit 2
fi

# ---------- pwsh shim NOT relevant on Mac; alias install via shim installer ----------
echo "[1/3] Installing claude alias..."
bash "$shim_installer"

# ---------- generate plists from templates ----------
mkdir -p "$LAUNCH_AGENTS"
mkdir -p "$HOME/.claude-restorer"   # for launchd's StandardOutPath/Err

generate_plist() {
  local template="$1" dest="$2"
  # Use a delimiter unlikely to appear in paths. macOS paths can include
  # / and ., but not | in normal usage; use | as sed delimiter.
  sed \
    -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
    -e "s|@USER@|$USERNAME|g" \
    "$template" > "$dest"
}

daemon_plist="$LAUNCH_AGENTS/$DAEMON_LABEL.plist"
restore_plist="$LAUNCH_AGENTS/$RESTORE_LABEL.plist"

echo "[2/3] Writing LaunchAgent plists..."
generate_plist "$daemon_template" "$daemon_plist"
echo "  wrote $daemon_plist"
generate_plist "$restore_template" "$restore_plist"
echo "  wrote $restore_plist"

# ---------- (re)bootstrap into the GUI session ----------
load_agent() {
  local label="$1" plist="$2"
  # bootout first; ignore failures (it may not be loaded yet).
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$plist"; then
    echo "  bootstrapped $label"
  else
    echo "  WARNING: bootstrap failed for $label" >&2
    echo "  Try:  launchctl print gui/$(id -u)/$label" >&2
    return 1
  fi
}

echo "[3/3] Loading LaunchAgents..."
load_agent "$DAEMON_LABEL" "$daemon_plist"
load_agent "$RESTORE_LABEL" "$restore_plist"

echo
echo "Install complete."
echo "  - Restore prompts at logon (30s after sign-in) if any sessions survived."
echo "  - Daemon backfills session_ids and prunes stale records every 60s."
echo
echo "Manual triggers any time:"
echo "  launchctl kickstart -k \"gui/\$(id -u)/$RESTORE_LABEL\""
echo "  launchctl kickstart -k \"gui/\$(id -u)/$DAEMON_LABEL\""
echo
echo "Inspect agent state:"
echo "  launchctl print \"gui/\$(id -u)/$DAEMON_LABEL\""
echo
echo "Logs:"
echo "  ~/.claude-restorer/daemon.log"
echo "  ~/.claude-restorer/restore.log"
echo "  ~/.claude-restorer/launchd-{daemon,restore}.{log,err}"
echo
echo "Uninstall:  bash $SCRIPT_DIR/uninstall-all.sh"
