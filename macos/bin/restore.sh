#!/usr/bin/env bash
# restore.sh - macOS port of restore.ps1.
#
# Reads the state dir, prompts the user via osascript, then relaunches
# each surviving Claude session in its original host terminal.
#
# Triggered automatically at logon by a launchd LaunchAgent (see M4).
# Manual invocation:
#   bash macos/bin/restore.sh           # normal: prompts, then launches
#   bash macos/bin/restore.sh --dry-run # print plan; no launches, no deletes
#   bash macos/bin/restore.sh --no-prompt
#
# See ../../shared/record-schema.md for the record contract.
# See ../../docs/macos-port-spec.md for per-terminal restore decisions.

set -u

STATE_DIR="${STATE_DIR:-${HOME}/.claude-restorer/sessions}"
LOG_FILE="${LOG_FILE:-${HOME}/.claude-restorer/restore.log}"
LAUNCH_DELAY_MS=400
DRY_RUN=0
NO_PROMPT=0

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1 ;;
    --no-prompt)       NO_PROMPT=1 ;;
    --launch-delay-ms) shift; LAUNCH_DELAY_MS="$1" ;;
    --state-dir)       shift; STATE_DIR="$1" ;;
    --log-file)        shift; LOG_FILE="$1" ;;
    -h|--help)
      grep '^#' "$0" | head -20 | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "restore: unknown flag '$1'" >&2
      exit 64
      ;;
  esac
  shift
done

# ---------- early exits ----------
if ! command -v jq >/dev/null 2>&1; then
  echo "restore: jq is required but not installed." >&2
  echo "  Install via:  brew install jq" >&2
  exit 2
fi

if [[ ! -d "$STATE_DIR" ]]; then
  echo "instance-restorer-5000: nothing to restore (state dir missing)."
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ---------- helpers ----------
log_line() {
  local stamp; stamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s  %s\n' "$stamp" "$*" >> "$LOG_FILE"
  if (( DRY_RUN == 1 )) || [[ -n "${RESTORE_VERBOSE:-}" ]]; then
    printf '%s  %s\n' "$stamp" "$*"
  fi
}

# Escape a string for inclusion in an AppleScript string literal.
# AppleScript uses double quotes; escape backslashes then quotes.
applescript_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# ---------- per-host launchers ----------

# Terminal.app — new window via osascript do script.
launch_terminal_app() {
  local cwd="$1" sid="$2"
  local cmd="cd \"$(applescript_escape "$cwd")\" && claude --resume $sid"
  log_line "terminal: $cmd"
  if (( DRY_RUN == 0 )); then
    osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Terminal"
  activate
  do script "$(applescript_escape "$cmd")"
end tell
APPLESCRIPT
  fi
}

# iTerm2 — new tab in current window if one exists; else new window.
launch_iterm() {
  local cwd="$1" sid="$2"
  local cmd="cd \"$(applescript_escape "$cwd")\" && claude --resume $sid"
  log_line "iterm: $cmd"
  if (( DRY_RUN == 0 )); then
    osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "iTerm"
  activate
  if (count of windows) = 0 then
    create window with default profile
  end if
  tell current window
    create tab with default profile
    tell current session to write text "$(applescript_escape "$cmd")"
  end tell
end tell
APPLESCRIPT
  fi
}

# Warp — open Warp at the cwd; no native command-on-launch in v1.
# Resume command goes into the editor-summary dialog at the end.
launch_warp() {
  local cwd="$1" sid="$2"
  local cmd="claude --resume $sid"
  log_line "warp: opening $cwd; deferred cmd='$cmd'"
  EDITOR_HOSTS+=("warp|$cwd|$cmd")
  if (( DRY_RUN == 0 )); then
    open -a "Warp" "$cwd" 2>/dev/null || \
      log_line "warp: 'open -a Warp $cwd' failed (Warp installed?)"
  fi
}

# Ghostty — has a CLI that supports --working-directory; command-on-launch
# support varies by version. v1: open at cwd, defer command to summary.
launch_ghostty() {
  local cwd="$1" sid="$2"
  local cmd="claude --resume $sid"
  log_line "ghostty: opening $cwd; deferred cmd='$cmd'"
  EDITOR_HOSTS+=("ghostty|$cwd|$cmd")
  if (( DRY_RUN == 0 )); then
    if command -v ghostty >/dev/null 2>&1; then
      ghostty --working-directory="$cwd" >/dev/null 2>&1 &
    else
      open -na "Ghostty" --args --working-directory="$cwd" 2>/dev/null || \
        log_line "ghostty: open failed (Ghostty installed?)"
    fi
  fi
}

# VS Code / Cursor — open folder; show resume cmd in summary.
launch_editor() {
  local app="$1" cwd="$2" sid="$3"
  local cli; cli="$([[ "$app" == "vscode" ]] && echo "code" || echo "cursor")"
  local cmd="claude --resume $sid"
  log_line "$app: opening $cwd; deferred cmd='$cmd'"
  EDITOR_HOSTS+=("$app|$cwd|$cmd")
  if (( DRY_RUN == 0 )); then
    "$cli" "$cwd" 2>/dev/null || \
      log_line "$app: '$cli $cwd' failed (CLI installed? See: code --version)"
  fi
}

# Unknown / fallback — open Terminal.app at cwd, print resume command.
launch_unknown() {
  local cwd="$1" sid="$2"
  log_line "unknown: opening Terminal at $cwd; printing resume cmd"
  if (( DRY_RUN == 0 )); then
    osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Terminal"
  activate
  do script "cd \"$(applescript_escape "$cwd")\" && echo 'instance-restorer-5000: please run: claude --resume $sid'"
end tell
APPLESCRIPT
  fi
}

invoke_restore() {
  local host="$1" cwd="$2" sid="$3"
  case "$host" in
    terminal) launch_terminal_app "$cwd" "$sid" ;;
    iterm)    launch_iterm        "$cwd" "$sid" ;;
    warp)     launch_warp         "$cwd" "$sid" ;;
    ghostty)  launch_ghostty      "$cwd" "$sid" ;;
    vscode)   launch_editor vscode "$cwd" "$sid" ;;
    cursor)   launch_editor cursor "$cwd" "$sid" ;;
    *)        launch_unknown      "$cwd" "$sid" ;;
  esac
}

# ---------- collect records ----------
declare -a RESTORABLE=()       # "<host>|<cwd>|<sid>|<file>"
declare -a SKIPPED_NO_SID=()   # "<host>|<cwd>"
declare -a EDITOR_HOSTS=()     # "<host>|<cwd>|<cmd>" — populated during launch

shopt -s nullglob
for record_file in "$STATE_DIR"/*.json; do
  if ! record_json="$(jq '.' "$record_file" 2>/dev/null)"; then
    log_line "skipping corrupt $(basename "$record_file")"
    continue
  fi
  host="$(printf '%s' "$record_json" | jq -r '.host // "unknown"')"
  cwd="$(printf '%s' "$record_json" | jq -r '.cwd // empty')"
  sid="$(printf '%s' "$record_json" | jq -r '.session_id // empty')"
  if [[ -z "$cwd" ]]; then
    log_line "record $(basename "$record_file") missing cwd - skipping"
    continue
  fi
  if [[ -z "$sid" || "$sid" == "null" ]]; then
    SKIPPED_NO_SID+=("$host|$cwd")
  else
    RESTORABLE+=("$host|$cwd|$sid|$record_file")
  fi
done
shopt -u nullglob

restorable_count=${#RESTORABLE[@]}
skipped_count=${#SKIPPED_NO_SID[@]}

if (( restorable_count == 0 && skipped_count == 0 )); then
  echo "instance-restorer-5000: nothing to restore."
  exit 0
fi

# ---------- build summary ----------
build_summary() {
  printf 'Restore %d Claude session(s)?\n\n' "$restorable_count"
  local entry host cwd sid_short
  for entry in "${RESTORABLE[@]}"; do
    IFS='|' read -r host cwd sid _file <<< "$entry"
    sid_short="${sid:0:8}"
    printf '  %-10s %-50s [%s]\n' "$host" "$cwd" "$sid_short"
  done
  if (( skipped_count > 0 )); then
    printf '\n(%d record(s) without session_id will be skipped:\n' "$skipped_count"
    for entry in "${SKIPPED_NO_SID[@]}"; do
      IFS='|' read -r host cwd <<< "$entry"
      printf '  %-10s %s\n' "$host" "$cwd"
    done
    printf "Use 'claude --resume' in those folders to pick from the session list.)\n"
  fi
}

summary="$(build_summary)"

# ---------- prompt ----------
should_proceed=0
if (( NO_PROMPT == 1 || DRY_RUN == 1 )); then
  should_proceed=1
  if (( DRY_RUN == 1 )); then
    printf '%s\n[DryRun: would proceed without prompting]\n' "$summary"
  fi
elif (( restorable_count == 0 )); then
  # Only no-session-id records to talk about; print and exit (no prompt).
  printf '%s\n' "$summary"
  exit 0
else
  # osascript dialog. Returns "button returned:Yes" on Yes, error on cancel.
  answer="$(osascript 2>/dev/null <<APPLESCRIPT
display dialog "$(applescript_escape "$summary")" \
  with title "instance-restorer-5000" \
  buttons {"No","Yes"} default button "Yes"
APPLESCRIPT
)" || answer=""

  if [[ "$answer" == *"Yes"* ]]; then
    should_proceed=1
  fi
fi

if (( should_proceed == 0 )); then
  log_line "user declined restore of $restorable_count record(s)"
  echo "Restore declined. Records left in place; rerun any time."
  exit 0
fi

# ---------- launch + cleanup ----------
launched=0
for entry in "${RESTORABLE[@]}"; do
  IFS='|' read -r host cwd sid record_file <<< "$entry"
  invoke_restore "$host" "$cwd" "$sid"
  launched=$(( launched + 1 ))
  if (( DRY_RUN == 0 )); then
    rm -f "$record_file"
    # Pause between launches so the windowing system has time to settle.
    sleep_seconds="$(awk "BEGIN { print $LAUNCH_DELAY_MS / 1000 }")"
    sleep "$sleep_seconds"
  fi
done

log_line "restored $launched session(s) (skipped $skipped_count without session_id)"
echo "Restored $launched session(s)."
if (( skipped_count > 0 )); then
  echo "$skipped_count record(s) without session_id were left in place."
fi

# ---------- editor follow-up dialog ----------
# Editor records (vscode/cursor/warp/ghostty) opened the folder but can't
# auto-run a terminal command. Show all the resume commands at once so
# the user can copy each into the right editor terminal.
if (( ${#EDITOR_HOSTS[@]} > 0 )); then
  followup="These editors opened, but ${#EDITOR_HOSTS[@]} need a manual 'claude --resume' (paste in each editor's terminal):"$'\n\n'
  for entry in "${EDITOR_HOSTS[@]}"; do
    IFS='|' read -r ehost ecwd ecmd <<< "$entry"
    followup+="$ehost  $ecwd"$'\n'"  $ecmd"$'\n\n'
  done
  printf '%s' "$followup"
  if (( DRY_RUN == 0 && NO_PROMPT == 0 )); then
    osascript >/dev/null 2>&1 <<APPLESCRIPT
display dialog "$(applescript_escape "$followup")" \
  with title "instance-restorer-5000 — editor sessions" \
  buttons {"OK"} default button "OK"
APPLESCRIPT
  fi
fi