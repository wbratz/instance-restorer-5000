#!/usr/bin/env bash
# install-shim.sh — wire the claude-shim into the user's shells.
#
# Adds an `alias claude=<shim>` line to ~/.bashrc, idempotently. Run from
# Git Bash to install for Git Bash + VS Code/Cursor terminals (which use
# Git Bash by default on Windows). Run again from inside each WSL distro
# you use, to install for WSL too.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/claude-shim.sh"

if [[ ! -x "$SHIM" ]]; then
  chmod +x "$SHIM"
fi

if [[ ! -f "$SHIM" ]]; then
  echo "install-shim: cannot find $SHIM" >&2
  exit 1
fi

MARKER_BEGIN="# >>> instance-restorer-5000 >>>"
MARKER_END="# <<< instance-restorer-5000 <<<"

install_into() {
  local rcfile="$1"
  touch "$rcfile"
  if grep -qF "$MARKER_BEGIN" "$rcfile"; then
    # Replace existing block in-place.
    local tmp
    tmp="$(mktemp)"
    awk -v B="$MARKER_BEGIN" -v E="$MARKER_END" '
      $0 == B { skipping = 1; next }
      $0 == E { skipping = 0; next }
      !skipping
    ' "$rcfile" > "$tmp"
    mv "$tmp" "$rcfile"
    echo "  removed previous block from $rcfile"
  fi
  {
    printf '\n%s\n' "$MARKER_BEGIN"
    printf '# Routes `claude` through the launch recorder.\n'
    printf 'alias claude=%q\n' "$SHIM"
    printf '%s\n' "$MARKER_END"
  } >> "$rcfile"
  echo "  installed alias into $rcfile"
}

# Determine which rcfile(s) to touch.
RCFILES=()
if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
  echo "Detected WSL distro: $WSL_DISTRO_NAME"
  RCFILES+=("$HOME/.bashrc")
else
  echo "Detected Git Bash / native Windows bash"
  RCFILES+=("$HOME/.bashrc")
  # VS Code and Cursor terminals on Windows default to Git Bash if
  # configured, so the same .bashrc covers them.
fi

for rc in "${RCFILES[@]}"; do
  install_into "$rc"
done

echo
echo "Done. Open a NEW terminal and run:"
echo "  type claude"
echo "It should report:  claude is aliased to \`$SHIM'"
echo
echo "Reminder: re-run this installer from inside each WSL distro you use."
