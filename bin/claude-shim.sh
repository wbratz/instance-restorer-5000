#!/usr/bin/env bash
# claude-shim.sh — instance-restorer-5000 launch recorder.
#
# Runs in place of `claude`. Detects the host environment, writes a JSON
# launch record to the state dir, then `exec`s the real claude binary so
# the recorded PID matches the live process. Cleanup of the record on
# clean exit is handled by the snapshot daemon (Phase 2) via PID liveness
# checks — exec replaces this shell, so we cannot rely on shell traps.

set -u

# ---------- locate state dir (universal, accessible from Git Bash + WSL) ----------
detect_state_dir() {
  if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    # WSL: use /mnt/c path. Resolve %USERPROFILE% via cmd.exe once.
    local userprofile
    userprofile="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')"
    # Convert C:\Users\foo -> /mnt/c/Users/foo
    local drive="${userprofile:0:1}"
    drive="${drive,,}"
    local rest="${userprofile:2}"
    rest="${rest//\\//}"
    printf '/mnt/%s%s/.claude-restorer/sessions' "$drive" "$rest"
  else
    # Git Bash / MSYS: $USERPROFILE is set, in C:\... form
    local up="${USERPROFILE:-$HOME}"
    # Convert via cygpath if available
    if command -v cygpath >/dev/null 2>&1; then
      cygpath -u "$up" | sed 's:$:/.claude-restorer/sessions:'
    else
      printf '%s/.claude-restorer/sessions' "${up//\\//}"
    fi
  fi
}

STATE_DIR="$(detect_state_dir)"
mkdir -p "$STATE_DIR" 2>/dev/null || {
  echo "claude-shim: cannot create state dir $STATE_DIR" >&2
  # Don't block claude launch on shim failure — fall through to exec below.
}

# ---------- detect host ----------
detect_host() {
  if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    printf 'wsl:%s' "$WSL_DISTRO_NAME"
  elif [[ "${TERM_PROGRAM:-}" == "vscode" ]]; then
    # Cursor sets TERM_PROGRAM=vscode too. Distinguish via version string
    # or CURSOR_TRACE_ID env var (set by Cursor's terminal integration).
    if [[ -n "${CURSOR_TRACE_ID:-}" ]] \
       || [[ "${TERM_PROGRAM_VERSION:-}" == *cursor* ]] \
       || [[ "${VSCODE_GIT_ASKPASS_NODE:-}" == *[Cc]ursor* ]]; then
      printf 'cursor'
    else
      printf 'vscode'
    fi
  elif [[ -n "${WT_SESSION:-}" ]]; then
    printf 'wt'
  else
    printf 'unknown'
  fi
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
    # Fallback: skip anything literally named claude-shim.sh
    [[ "$candidate" == *claude-shim.sh ]] && continue
  fi
  REAL_CLAUDE="$candidate"
  break
done < <(type -ap claude 2>/dev/null)

if [[ -z "$REAL_CLAUDE" ]]; then
  echo "claude-shim: real claude binary not found in PATH (after excluding shim)" >&2
  exit 127
fi

# ---------- compute cwd in a portable form ----------
CWD="$PWD"
if [[ "$HOST" != wsl:* ]] && command -v cygpath >/dev/null 2>&1; then
  # Normalize to Windows-style for non-WSL hosts (wt --startingDirectory
  # wants C:\... form).
  CWD="$(cygpath -w "$PWD" 2>/dev/null || echo "$PWD")"
fi

# ---------- write record ----------
PID=$$
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST_SAFE="${HOST//[:\/]/_}"
RECORD="$STATE_DIR/${PID}-${HOST_SAFE}.json"

# JSON-escape a string: backslashes, quotes, control chars.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Build args array as JSON
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

# Best-effort write — never block claude launch on this.
{
  cat > "$RECORD" <<EOF
{
  "pid": $PID,
  "host": "$(json_escape "$HOST")",
  "wrapper": "exec",
  "cwd": "$(json_escape "$CWD")",
  "wt_session": "$(json_escape "${WT_SESSION:-}")",
  "started_at": "$STARTED_AT",
  "session_id": null,
  "real_claude": "$(json_escape "$REAL_CLAUDE")",
  "args": $ARGS_JSON
}
EOF
} 2>/dev/null || echo "claude-shim: failed to write $RECORD" >&2

# ---------- hand off ----------
# exec replaces the shell with claude — same PID, same TTY, no orphan
# wrapper process sitting around. Daemon prunes the record when this PID
# is no longer alive.
exec "$REAL_CLAUDE" "$@"
