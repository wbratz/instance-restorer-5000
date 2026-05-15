#!/usr/bin/env bash
# uninstall-shim.sh — remove the alias block from rc files.

set -euo pipefail

MARKER_BEGIN="# >>> instance-restorer-5000 >>>"
MARKER_END="# <<< instance-restorer-5000 <<<"

remove_from() {
  local rcfile="$1"
  [[ -f "$rcfile" ]] || { echo "  $rcfile: not present, skipping"; return; }
  if ! grep -qF "$MARKER_BEGIN" "$rcfile"; then
    echo "  $rcfile: no marker block, skipping"
    return
  fi
  local tmp
  tmp="$(mktemp)"
  awk -v B="$MARKER_BEGIN" -v E="$MARKER_END" '
    $0 == B { skipping = 1; next }
    $0 == E { skipping = 0; next }
    !skipping
  ' "$rcfile" > "$tmp"
  mv "$tmp" "$rcfile"
  echo "  $rcfile: removed block"
}

remove_from "$HOME/.bashrc"

echo
echo "Done. Open a new terminal — \`claude\` will resolve to the real binary again."
