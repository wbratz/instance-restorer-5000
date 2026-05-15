#!/usr/bin/env bash
# snapshot-daemon.sh - macOS port of snapshot-daemon.ps1.
#
# One pass over every record in the state dir:
#   1. Prune dead/wrong-binary 'exec' records (the Mac default).
#   2. Backfill session_id by scanning ~/.claude/projects/<encoded>/*.jsonl
#      for files modified at-or-after started_at.
#   3. Orphan-prune very old 'wait' records whose wrapper PID is gone or
#      reused (defensive — Mac doesn't normally produce wait records, but
#      keep parity with the Windows daemon).
#
# Invoked every 60s by a launchd LaunchAgent (see M4). Run manually for now:
#   bash macos/bin/snapshot-daemon.sh
#
# Hard dependency: jq. Install via `brew install jq` if missing.
#
# See ../../shared/record-schema.md for the record contract.
# See ../../CLAUDE.md for BSD-vs-GNU command notes.

set -u

STATE_DIR="${STATE_DIR:-${HOME}/.claude-restorer/sessions}"
PROJECTS_DIR="${PROJECTS_DIR:-${HOME}/.claude/projects}"
LOG_FILE="${LOG_FILE:-${HOME}/.claude-restorer/daemon.log}"
WAIT_ORPHAN_HOURS="${WAIT_ORPHAN_HOURS:-72}"

# ---------- early exits ----------
if ! command -v jq >/dev/null 2>&1; then
  echo "snapshot-daemon: jq is required but not installed." >&2
  echo "  Install via:  brew install jq" >&2
  exit 2
fi

if [[ ! -d "$STATE_DIR" ]]; then
  # Nothing to do.
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# ---------- helpers ----------
log_line() {
  local stamp; stamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s  %s\n' "$stamp" "$*" >> "$LOG_FILE"
}

# Parse ISO 8601 UTC string ("2026-05-15T12:00:00Z") to epoch seconds.
# BSD date doesn't accept -d; uses -j -f for parsing.
iso_to_epoch() {
  local s="$1"
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$s" "+%s" 2>/dev/null
}

# Get a process's start time (BSD lstart format) as epoch seconds.
# Returns empty if process is gone OR start time can't be parsed.
process_start_epoch() {
  local pid="$1"
  # `ps -o lstart=` outputs e.g. "Thu May 15 09:15:11 2026" (BSD-only).
  local lstart
  lstart="$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//')"
  [[ -z "$lstart" ]] && return 1
  date -j -f "%a %b %e %T %Y" "$lstart" "+%s" 2>/dev/null
}

# Get a process's executable name without extension (BSD ps).
process_name() {
  local pid="$1"
  ps -p "$pid" -o comm= 2>/dev/null | sed 's|^.*/||;s/^ *//;s/ *$//'
}

# True iff the process at $pid is alive AND (when expected names given)
# its name is in the list AND its start time is at-or-before recorded time.
# Args:  pid  recorded_epoch  expected_names_space_separated_or_empty
test_pid_alive() {
  local pid="$1" recorded_epoch="$2" expected_names="${3:-}"

  kill -0 "$pid" 2>/dev/null || return 1

  if [[ -n "$expected_names" ]]; then
    local name; name="$(process_name "$pid")"
    local found=0 n
    for n in $expected_names; do
      if [[ "$name" == "$n" ]]; then found=1; break; fi
    done
    [[ "$found" -eq 1 ]] || return 1
  fi

  local proc_epoch
  proc_epoch="$(process_start_epoch "$pid" 2>/dev/null)"
  if [[ -z "$proc_epoch" ]]; then
    # Can't read start time (protected? race?) — assume alive rather
    # than risk pruning a real session.
    return 0
  fi

  # 5s slack for clock skew.
  if (( proc_epoch > recorded_epoch + 5 )); then
    return 1
  fi
  return 0
}

# Encode a cwd to the project-key Claude Code uses.
# Replaces every non-alphanumeric (not -) char with '-'.
encode_cwd() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9-]/-/g'
}

# Find newest .jsonl uuid in ~/.claude/projects/<encoded>/ whose mtime is
# at-or-after the recorded started_at (with 5s slack for clock skew).
# Echoes the uuid (filename minus .jsonl) on success; nothing on miss.
find_session_id() {
  local cwd="$1" recorded_epoch="$2"
  local key dir
  key="$(encode_cwd "$cwd")"
  dir="${PROJECTS_DIR}/${key}"
  [[ -d "$dir" ]] || return 1

  local newest_uuid="" newest_mtime=0
  local f m
  for f in "$dir"/*.jsonl; do
    [[ -e "$f" ]] || continue                # nullglob fallback
    m="$(stat -f %m "$f" 2>/dev/null)"        # BSD mtime as epoch
    [[ -z "$m" ]] && continue
    if (( m >= recorded_epoch - 5 )) && (( m > newest_mtime )); then
      newest_mtime="$m"
      newest_uuid="$(basename "$f" .jsonl)"
    fi
  done
  [[ -n "$newest_uuid" ]] && printf '%s' "$newest_uuid"
}

# Atomically replace a record file (write to .tmp, rename).
save_record() {
  local path="$1" content="$2"
  local tmp="${path}.tmp"
  printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$path"
}

# ---------- main loop ----------
now_epoch="$(date -u +%s)"
wait_orphan_epoch_threshold=$(( now_epoch - WAIT_ORPHAN_HOURS * 3600 ))
pruned=0
updated=0
total=0

# Use nullglob so the loop is empty when no files match.
shopt -s nullglob
for record_file in "$STATE_DIR"/*.json; do
  total=$(( total + 1 ))

  # Read + parse. Skip corrupt records (don't delete - might be in-progress write).
  if ! record_json="$(jq '.' "$record_file" 2>/dev/null)"; then
    log_line "skipping corrupt record $(basename "$record_file")"
    continue
  fi

  pid="$(printf '%s' "$record_json" | jq -r '.pid // empty')"
  host="$(printf '%s' "$record_json" | jq -r '.host // "unknown"')"
  wrapper="$(printf '%s' "$record_json" | jq -r '.wrapper // "exec"')"
  cwd="$(printf '%s' "$record_json" | jq -r '.cwd // empty')"
  started_at="$(printf '%s' "$record_json" | jq -r '.started_at // empty')"
  session_id="$(printf '%s' "$record_json" | jq -r '.session_id // empty')"

  if [[ -z "$pid" || -z "$started_at" ]]; then
    log_line "record $(basename "$record_file") missing pid or started_at - skipping"
    continue
  fi

  recorded_epoch="$(iso_to_epoch "$started_at")"
  if [[ -z "$recorded_epoch" ]]; then
    log_line "record $(basename "$record_file") has unparseable started_at='$started_at' - skipping"
    continue
  fi

  # ---------- pruning ----------
  should_prune=0
  prune_reason=""

  case "$wrapper" in
    exec)
      # Mac shim exec'd into claude. PID = claude's PID.
      if test_pid_alive "$pid" "$recorded_epoch" "claude"; then
        :   # alive and our binary
      else
        should_prune=1
        prune_reason="pid $pid is dead, reused, or no longer claude"
      fi
      ;;
    wait)
      # Defensive: Mac doesn't normally produce wait records. Treat
      # like the Windows daemon: only orphan-prune on age + dead/reused.
      if (( recorded_epoch < wait_orphan_epoch_threshold )); then
        if ! test_pid_alive "$pid" "$recorded_epoch" "bash zsh"; then
          should_prune=1
          prune_reason="wait record older than ${WAIT_ORPHAN_HOURS}h; wrapper pid $pid gone or reused"
        fi
      fi
      ;;
    *)
      log_line "record $(basename "$record_file") has unknown wrapper='$wrapper' - leaving alone"
      ;;
  esac

  if (( should_prune == 1 )); then
    rm -f "$record_file"
    log_line "pruned $(basename "$record_file"): $prune_reason"
    pruned=$(( pruned + 1 ))
    continue
  fi

  # ---------- session_id backfill ----------
  if [[ -z "$session_id" || "$session_id" == "null" ]]; then
    sid="$(find_session_id "$cwd" "$recorded_epoch")"
    if [[ -n "$sid" ]]; then
      new_json="$(printf '%s' "$record_json" | jq --arg s "$sid" '.session_id = $s')"
      if save_record "$record_file" "$new_json"; then
        log_line "filled session_id=$sid in $(basename "$record_file")"
        updated=$(( updated + 1 ))
      else
        log_line "failed to save $(basename "$record_file")"
      fi
    fi
  fi
done
shopt -u nullglob

if (( pruned > 0 || updated > 0 )); then
  log_line "tick complete: pruned=$pruned updated=$updated total=$total"
fi