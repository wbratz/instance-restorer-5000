#!/usr/bin/env bash
# install-shim.sh - macOS shim installer for instance-restorer-5000.
#
# Appends an `alias claude=...` block to the user's shell rc files.
# Idempotent via marker comments - re-running replaces the existing
# block.
#
# Touches:
#   - ~/.zshrc          (always; created if missing - default Mac shell)
#   - ~/.bashrc         (only if it already exists)
#   - ~/.bash_profile   (only if it already exists; Mac bash login shell
#                        convention)
#
# We don't create bash rc files unless they already exist - creating
# ~/.bash_profile on a pure-zsh setup could surprise the user later.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/claude-shim.sh"

if [[ ! -f "$SHIM" ]]; then
  echo "install-shim: cannot find $SHIM" >&2
  exit 1
fi

# Make executable in case the user cloned without preserving the bit.
chmod +x "$SHIM"

MARKER_BEGIN="# >>> instance-restorer-5000 >>>"
MARKER_END="# <<< instance-restorer-5000 <<<"

install_into() {
  local rcfile="$1"
  local create_if_missing="$2"

  if [[ ! -f "$rcfile" ]]; then
    if [[ "$create_if_missing" != "yes" ]]; then
      echo "  $rcfile: not present, skipping (use bash? touch $rcfile then re-run)"
      return
    fi
    touch "$rcfile"
    echo "  $rcfile: created"
  fi

  # Strip any existing block in-place.
  if grep -qF "$MARKER_BEGIN" "$rcfile"; then
    local tmp
    tmp="$(mktemp)"
    awk -v B="$MARKER_BEGIN" -v E="$MARKER_END" '
      $0 == B { skipping = 1; next }
      $0 == E { skipping = 0; next }
      !skipping
    ' "$rcfile" > "$tmp"
    mv "$tmp" "$rcfile"
    echo "  $rcfile: removed previous block"
  fi

  {
    printf '\n%s\n' "$MARKER_BEGIN"
    printf '# Routes `claude` through the launch recorder.\n'
    printf 'alias claude=%q\n' "$SHIM"
    printf '%s\n' "$MARKER_END"
  } >> "$rcfile"
  echo "  $rcfile: installed alias"
}

echo "Installing claude shim from: $SHIM"
echo

install_into "$HOME/.zshrc"        yes
install_into "$HOME/.bashrc"       no
install_into "$HOME/.bash_profile" no

echo
echo "Done. Open a NEW terminal and run:"
echo "  type claude"
echo "It should report:  claude is an alias for $SHIM"
echo
echo "If you use a shell other than zsh/bash (fish, nu), you'll need to wire"
echo "the alias yourself. Point it at: $SHIM"
