#!/usr/bin/env bash
# claude-shim.sh - macOS launch recorder for instance-restorer-5000.
#
# Wired in via an `alias claude=...` line in the user's ~/.zshrc and/or
# ~/.bashrc. Each `claude` invocation runs through this script first:
# detect the host terminal, write a JSON record to ~/.claude-restorer/
# sessions/, then `exec` into the real claude binary so the recorded PID
# matches the live process.
#
# Cleanup on clean exit: not needed at the shim layer. exec replaces this
# shell with claude (same PID); when claude exits, the daemon prunes the
# record on its next tick via PID liveness check.
#
# See ../../shared/record-schema.md for the record format contract.
# See ../../CLAUDE.md for project-wide conventions.

set -u

# ---------- state directory ----------
STATE_DIR="${HOME}/.claude-restorer/sessions"
mkdir -p "$STATE_DIR" 2>/dev/null || {
  echo "claude-shim: cannot create $STATE_DIR" >&2
  # Don't block claude on shim failure - fall through to exec below.
}

# ---------- detect host ----------
detect_host() {
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) printf 'terminal' ;;
    iTerm.app)      printf 'iterm' ;;
    WarpTerminal)   printf 'warp' ;;
    ghostty)        printf 'ghostty' ;;
    vscode)
      # Cursor sets TERM_PROGRAM=vscode too. Same disambiguation as the
      # Windows shim.
      if [[ -n "${CURSOR_TRACE_ID:-}" ]] \
         || [[ "${TERM_PROGRAM_VERSION:-}" == *cursor* ]] \
         || [[ "${VSCODE_GIT_ASKPASS_NODE:-}" == *[Cc]ursor* ]]; then
        printf 'cursor'
      else
        printf 'vscode'
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

HOST="$(detect_host)"

# ---------- resolve real claude binary (skip self) ----------
SELF_REAL=""
if command -v realpath >/dev/null 2>&1; then
  SELF_REAL="$(realpath "$0" 2>/dev/null || true)"
fi

REAL_CLAUDE=""
while IFS= read -r candidate; do
  [[ -z "$candidate" ]] && continue
  cand_real="$candidate"
  if [[ -n "$SELF_REAL" ]] && command -v realpath >/dev/null 2>&1; then
    cand_real="$(realpath "$candidate" 2>/dev/null || echo "$candidate")"
    [[ "$cand_real" == "$SELF_REAL" ]] && continue
  else
    # Without realpath, skip anything literally named claude-shim.sh.
    [[ "$candidate" == *claude-shim.sh ]] && continue
  fi
  REAL_CLAUDE="$candidate"
  break
done < <(type -ap claude 2>/dev/null)

if [[ -z "$REAL_CLAUDE" ]]; then
  echo "claude-shim: real claude binary not found in PATH (after excluding shim)" >&2
  exit 127
fi

# ---------- record fields ----------
PID=$$
CWD="$PWD"
# UTC ISO-8601. macOS `date` accepts -u and the same format string as GNU
# for output (it's input parsing where they differ).
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST_SAFE="${HOST//[:\/]/_}"
RECORD="$STATE_DIR/${PID}-${HOST_SAFE}.json"
ITERM_SESSION="${ITERM_SESSION_ID:-}"

# ---------- JSON encoding ----------
# Best-effort manual escaping for the small set of strings we emit.
# Paths on macOS don't contain backslashes, but quotes and control chars
# are theoretically possible (rare in real usage).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

build_args_json() {
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '['
  local first=1
  for a in "$@"; do
    if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
    printf '"%s"' "$(json_escape "$a")"
  done
  printf ']'
}

ARGS_JSON="$(build_args_json "$@")"

# ---------- write record ----------
# Best-effort - never block claude launch on a failed write.
{
  cat > "$RECORD" <<EOF
{
  "pid": $PID,
  "host": "$(json_escape "$HOST")",
  "wrapper": "exec",
  "cwd": "$(json_escape "$CWD")",
  "wt_session": "$(json_escape "$ITERM_SESSION")",
  "started_at": "$STARTED_AT",
  "session_id": null,
  "real_claude": "$(json_escape "$REAL_CLAUDE")",
  "args": $ARGS_JSON
}
EOF
} 2>/dev/null || echo "claude-shim: failed to write $RECORD" >&2

# ---------- hand off ----------
# exec replaces this shell with claude. Same PID. The daemon prunes the
# record via PID liveness when claude eventually exits.
exec "$REAL_CLAUDE" "$@"
