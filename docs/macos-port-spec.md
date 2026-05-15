# macOS port spec

Design doc for bringing instance-restorer-5000 to macOS. Status: **proposed,
not yet implemented**. The Windows side is shipping; this doc captures the
decisions and structure needed before Mac code lands.

## Goals

1. Same user experience: forced shutdown, sign back in, dialog asks "restore
   N Claude sessions?", click Yes, terminals reopen with conversations
   resumed.
2. Per-user install. No `sudo`, no Homebrew packages required, no language
   runtimes beyond what ships with macOS (bash, zsh, AppleScript, launchd).
3. One install command: `./macos/bin/install-all.sh`.

## Non-goals

- Single cross-platform runtime (Python/Node). Each OS uses its native
  scheduler and dialog primitives. Worth the duplication; the alternative
  is asking every user to install a runtime.
- iCloud sync of records across machines. Out of scope.
- WSL-equivalent on Mac. There's nothing to port there.
- GUI configuration UI. Defaults work; advanced users edit shell scripts.

## Architecture choice: parallel native, shared schema

```
                    +----------------------+
                    | shared/              |
                    |   record-schema.md   |  one canonical JSON shape
                    |   cwd-encoding.md    |  one rule (non-alphanumeric -> "-")
                    +----------------------+
                       |                |
        +--------------+                +-----------------+
        v                                                 v
+----------------+                              +-------------------+
| windows/bin/   |                              | macos/bin/        |
| - PowerShell   |                              | - bash/zsh        |
| - WinForms     |                              | - AppleScript     |
| - Task Sched.  |                              | - launchd         |
| - wt.exe       |                              | - AppleScript per |
|                |                              |   terminal app    |
+----------------+                              +-------------------+
```

Records on disk are interchangeable in shape; in practice each side reads
its own state dir.

## Repo layout (proposed when porting)

```
instance-restorer-5000/
├── README.md                    # one-pager linking to per-OS docs
├── LICENSE
├── docs/
│   ├── architecture.md          # cross-platform overview (lift from this doc)
│   ├── install-windows.md       # current README content split out
│   ├── install-macos.md
│   └── macos-port-spec.md       # this file
├── windows/
│   └── bin/                     # current bin/ moves here
├── macos/
│   └── bin/
│       ├── claude-shim.sh
│       ├── install-shim.sh
│       ├── uninstall-shim.sh
│       ├── snapshot-daemon.sh
│       ├── restore.sh
│       ├── install-all.sh
│       ├── uninstall-all.sh
│       └── plists/
│           ├── daemon.plist.template
│           └── restore.plist.template
└── shared/
    └── record-schema.md
```

## Shared contracts (must stay identical Windows ↔ macOS)

### Record schema

Same fields and types as today. The `host` enum widens (see below) and
`wrapper` gains no new values — Mac uses `"exec"` exclusively (no
PowerShell-style "wait" case).

### State directory

`~/.claude-restorer/sessions/<pid>-<host>.json`

Same layout, same per-record file. On Mac, `~` resolves via `$HOME`.

### cwd-to-project-key encoding

`[^a-zA-Z0-9-]` → `-`. Same rule as Windows. Empirically confirmed against
Claude Code's `~/.claude/projects/` directory naming.

### Session-id backfill

`~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` — same as Windows.
Take the newest jsonl whose mtime is `>= started_at`.

## Mac component design

### Recorder: `macos/bin/claude-shim.sh`

Mostly the same as `windows/bin/claude-shim.sh`. Differences:

- **State dir resolution:** drop the `cmd.exe` / `cygpath` branches.
  Always `${HOME}/.claude-restorer/sessions`.
- **cwd:** stays POSIX. No path translation needed.
- **Host detection** widens (see table below).
- **`exec`** into the real `claude` binary, same pattern. Daemon prunes
  via PID liveness when the bash process is gone.

Host detection:

| `$TERM_PROGRAM` | `host` value |
|-----------------|--------------|
| `Apple_Terminal` | `terminal` |
| `iTerm.app` | `iterm` |
| `WarpTerminal` | `warp` |
| `ghostty` | `ghostty` |
| `vscode` (no Cursor markers) | `vscode` |
| `vscode` + `CURSOR_TRACE_ID` set, **or** `TERM_PROGRAM_VERSION` contains `cursor` | `cursor` |
| anything else | `unknown` |

iTerm2 also exposes `$ITERM_SESSION_ID` per tab — record it as
`iterm_session_id` (analogous to Windows' `wt_session`) for future
fine-grained restore.

### Daemon: `macos/bin/snapshot-daemon.sh`

Bash port of the PowerShell daemon. One pass per invocation; launchd
schedules it every 60s.

PID liveness on macOS:

```bash
test_pid_alive() {
  local pid="$1"
  local expected_name="$2"   # e.g. "claude" or "bash" — empty for any
  local recorded_started_iso="$3"

  # Liveness
  kill -0 "$pid" 2>/dev/null || return 1

  # Process name check
  if [[ -n "$expected_name" ]]; then
    local name
    name="$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename)"
    [[ "$name" == "$expected_name" ]] || return 1
  fi

  # Start-time check (PID reuse detection)
  # `ps -o lstart=` gives e.g. "Thu May 15 09:15:11 2026"
  local proc_start_iso
  proc_start_iso="$(ps -p "$pid" -o lstart= 2>/dev/null | \
    xargs -I{} date -j -f "%a %b %e %T %Y" "{}" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)"
  [[ -z "$proc_start_iso" ]] && return 0   # can't tell — assume alive

  # If process started AFTER our record (with 5s slack), PID was reused
  local proc_epoch recorded_epoch
  proc_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$proc_start_iso" "+%s")"
  recorded_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$recorded_started_iso" "+%s")"
  (( proc_epoch > recorded_epoch + 5 )) && return 1

  return 0
}
```

Notes:
- macOS `date` is BSD; flag is `-j -f` (parse), not GNU `-d`. Check for
  GNU coreutils only if needed for testing.
- `ps -o comm=` returns just the executable name (no path).
- Skip the WSL branch entirely — no equivalent on Mac.

Backfill logic:
```bash
backfill_session_id() {
  local cwd="$1" started_iso="$2"
  local key
  key="$(printf '%s' "$cwd" | sed 's/[^a-zA-Z0-9-]/-/g')"
  local dir="${HOME}/.claude/projects/${key}"
  [[ -d "$dir" ]] || return 1

  # Newest jsonl with mtime >= started_at
  local started_epoch
  started_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_iso" "+%s")"

  local newest_uuid="" newest_mtime=0
  for f in "$dir"/*.jsonl; do
    [[ -e "$f" ]] || continue
    local m
    m="$(stat -f %m "$f")"
    if (( m >= started_epoch - 5 && m > newest_mtime )); then
      newest_mtime="$m"
      newest_uuid="$(basename "$f" .jsonl)"
    fi
  done
  [[ -n "$newest_uuid" ]] && printf '%s' "$newest_uuid"
}
```

JSON read/write: use `jq` if available (almost always installed on dev
Macs), fall back to a tiny inline parser (or just sed for known fields).
Decision: **require `jq`**. It's installed by default on many Macs and
trivially `brew install jq` otherwise — worth not reinventing.

### Restore: `macos/bin/restore.sh`

Three responsibilities, same as the .ps1:

1. Read records, classify, prompt user.
2. Spawn the right thing per host.
3. Delete consumed records.

**Prompt — AppleScript dialog:**

```bash
summary="Restore $count Claude session(s)?

  terminal   ~/projects/foo     [a400d7a5]
  iterm      ~/work/api         [b1234567]
"

answer="$(osascript <<EOF
display dialog "$summary" \
  with title "instance-restorer-5000" \
  buttons {"No","Yes"} default button "Yes"
EOF
)"

if [[ "$answer" == *"Yes"* ]]; then
  # proceed
fi
```

This is one-line and built into macOS. No dependency.

**Per-host relaunch matrix:**

| `host` | Approach |
|--------|----------|
| `terminal` | `osascript -e 'tell app "Terminal" to do script "cd \"<cwd>\" && claude --resume <id>"'` — opens new window or tab in the frontmost Terminal |
| `iterm` | `osascript` against iTerm's richer API — `create window with default profile command "..."` for iTerm2 |
| `warp` | Warp's CLI is limited for command-on-launch. **v1: open the app at the cwd via `open -a Warp <cwd>`, append the resume command to the editor-summary dialog at the end of restore.** |
| `ghostty` | `ghostty +new-window --working-directory=<cwd> --command='zsh -ic "claude --resume <id>; exec zsh"'` (verify exact CLI flags during implementation) |
| `vscode` | `code <cwd>`, append resume command to summary dialog (same as Windows) |
| `cursor` | `cursor <cwd>`, append resume command to summary dialog |
| `unknown` | Open Terminal.app at cwd, print resume command in the new window |

The AppleScript snippets need careful quoting — single-quoting bash
inside an `osascript -e` arg means escaping single quotes. Use heredoc
form (`osascript <<EOF`) to avoid the worst of it.

**iTerm2 specific (it's the most common dev terminal on Mac):**
```applescript
tell application "iTerm"
    create window with default profile
    tell current session of current window
        write text "cd '<cwd>' && claude --resume <id>"
    end tell
end tell
```
The `write text` form works inside an existing session and auto-runs the
command. Cleaner than Terminal.app's `do script`.

### Scheduler: launchd LaunchAgents

Two `.plist` files in `~/Library/LaunchAgents/`. Generated from templates
during install (the installer substitutes `@INSTALL_DIR@` and `@USER@`).

**`com.claude-restorer.daemon.plist`:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-restorer.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>@INSTALL_DIR@/macos/bin/snapshot-daemon.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/Users/@USER@/.claude-restorer/launchd-daemon.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/@USER@/.claude-restorer/launchd-daemon.err</string>
</dict>
</plist>
```

`StartInterval=60` fires every 60 seconds while the user session is active.
launchd auto-starts the agent at user login.

**`com.claude-restorer.restore.plist`:**

```xml
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-restorer.restore</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>sleep 30 && exec @INSTALL_DIR@/macos/bin/restore.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

`RunAtLoad=true` means the agent fires once when launchd loads it — that
happens at user login. The inline `sleep 30` gives the desktop session
time to settle (Dock, Finder, terminal apps) before the dialog appears.
launchd doesn't have a "delay after RunAtLoad" key; the wrapped sleep is
the standard workaround.

**Loading the agents (installer does this):**

```bash
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.claude-restorer.daemon.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.claude-restorer.restore.plist"
```

`bootstrap` is the modern verb (replaced `load` in macOS 10.10+).
`gui/$(id -u)` targets the user's GUI session domain so dialogs can
appear.

**Unloading (uninstaller):**

```bash
launchctl bootout "gui/$(id -u)/com.claude-restorer.daemon"
launchctl bootout "gui/$(id -u)/com.claude-restorer.restore"
rm ~/Library/LaunchAgents/com.claude-restorer.{daemon,restore}.plist
```

**Manual triggers (equivalent to `Start-ScheduledTask`):**

```bash
launchctl kickstart -k "gui/$(id -u)/com.claude-restorer.restore"
launchctl kickstart -k "gui/$(id -u)/com.claude-restorer.daemon"
```

### Installer: `macos/bin/install-all.sh`

Steps:

1. Append the `claude` alias line to `~/.zshrc` and `~/.bashrc` via the
   same marker-block pattern as the bash installer today (calls
   `install-shim.sh`).
2. Read the plist templates from `macos/bin/plists/`, substitute
   `@INSTALL_DIR@` with the absolute path to the repo, and `@USER@` with
   `$(whoami)`. Write to `~/Library/LaunchAgents/`.
3. `launchctl bootstrap` both.
4. Print the same "Install complete" summary as the Windows version,
   adapted for Mac paths.

Idempotent: re-running unloads first via `launchctl bootout` (ignoring
errors), then re-bootstraps.

### Uninstaller: `macos/bin/uninstall-all.sh`

Reverses the above. Default removes state dir; `--keep-state` and
`--keep-shim` flags mirror the Windows uninstaller.

## Differences from Windows that matter

| Concept | Windows | macOS |
|---------|---------|-------|
| Scheduler | Task Scheduler (`Register-ScheduledTask`) | launchd (`~/Library/LaunchAgents/*.plist`) |
| Logon delay | Native (`$trigger.Delay = "PT30S"`) | Wrapper script with `sleep 30` |
| Repeating job | `Trigger.Repetition.Interval=PT1M` | plist `StartInterval=60` |
| Confirm dialog | `[System.Windows.Forms.MessageBox]::Show(...)` | `osascript -e 'display dialog ...'` |
| New terminal tab/window | `wt.exe -w 0 nt --startingDirectory ... -- ...` | AppleScript per terminal app |
| Process info | `Get-Process` (.NET) | `ps -p $pid -o comm=,lstart=` (BSD) |
| PID liveness | `Get-Process -Id` | `kill -0 $pid` |
| Profile/rc file | `$PROFILE` (.ps1, two locations) | `~/.zshrc` + `~/.bashrc` |
| Shell shim | bash + pwsh variants | bash only (zsh sources `~/.zshrc` which inherits the alias) |
| Path-translation cases | Windows ↔ WSL UNC ↔ /mnt | Single POSIX namespace, none needed |
| Hidden window for daemon | `-WindowStyle Hidden` on `powershell.exe` | launchd runs without UI by default |

## Open decisions before implementation

1. **Bundle ID prefix.** Resolved: `com.claude-restorer.*` for plist
   `Label` keys (avoids any personal name in shared tool identifiers).
2. **`jq` requirement.** Yes — assume present. If absent, installer
   prints `brew install jq` and exits. Avoids reimplementing JSON in bash.
3. **Warp / Ghostty support tier.** v1: open-folder + clipboard fallback,
   same as VS Code/Cursor. Native AppleScript automation: deferred to v2
   if users actually use these.
4. **Default shell detection.** Append alias to whichever rc files exist.
   Mac since Catalina defaults to zsh (`~/.zshrc`); older user accounts
   may still have `~/.bash_profile` set up — installer covers all three
   (`~/.zshrc`, `~/.bashrc`, `~/.bash_profile`).
5. **Timezone in `started_at`.** Windows writes UTC. Mac will too (same
   `date -u +%Y-%m-%dT%H:%M:%SZ`). Records remain comparable.
6. **What to do if the user runs the macOS installer on a Linux box.**
   Out of scope. Document Mac-only; the recorder shim happens to also
   work on Linux but the daemon and launchd pieces don't.

## Testing matrix

Mirror the Windows verification suite, mapped to Mac terminals:

| Test | macOS variant |
|------|---------------|
| Recorder writes correct host | Terminal.app, iTerm2, VS Code, Cursor (and Warp/Ghostty if scoped in) |
| Recorder cleanup on `claude /exit` | Same — bash trap on exec'd parent fires |
| Daemon backfills `session_id` | Same — `~/.claude/projects/<encoded>/*.jsonl` lookup |
| Daemon prunes dead PID | `kill -0` says no |
| Daemon prunes PID-reuse | `ps -o lstart=` predates record |
| Restore prompt appears | osascript dialog renders |
| Restore opens correct terminal at correct cwd with correct command | per-host AppleScript verified |
| Editor records show in summary dialog | osascript multi-line dialog |
| `install-all.sh` idempotent | re-running cleans + re-bootstraps |
| `uninstall-all.sh` removes everything | `launchctl print gui/$(id -u)` shows neither label |

Plus a real-crash test: open Claude in two iTerm windows, force-kill iTerm
from Activity Monitor, sign out, sign back in. Verify dialog appears,
restore works.

## Phased build plan (mirrors Windows phases)

| Phase | Scope | Verification |
|------:|-------|--------------|
| M1 | `claude-shim.sh` + `install-shim.sh` for Mac | Records appear in state dir from Terminal/iTerm/VS Code |
| M2 | `snapshot-daemon.sh` (backfill + prune) | Run manually; observe `session_id` get filled, dead PIDs pruned |
| M3 | `restore.sh` with osascript dialog and per-host AppleScript | Manual restore reopens iTerm/Terminal tabs at right cwd, claude resumes |
| M4 | LaunchAgent plists, `install-all.sh`, `uninstall-all.sh` | logout/login cycle triggers restore prompt automatically |

## What changes in the cross-platform repo before any Mac code lands

These prep steps make the Mac port additive rather than disruptive:

1. **Move current `bin/` to `windows/bin/`.** Update `install-all.ps1`'s
   internal `$PSScriptRoot` references (none currently break — they all
   use relative resolution).
2. **Move install path docs from README into `docs/install-windows.md`.**
   Keep README as a one-pager that links per-OS docs and explains the
   shared concept.
3. **Create `shared/record-schema.md`** documenting the JSON shape and
   the `wrapper`/`host`/cwd-encoding contracts that both sides must
   honor.
4. **CI (optional).** A GitHub Actions matrix `[windows-latest, macos-latest]`
   that smoke-tests each side's install/uninstall in a clean runner. Worth
   it once Mac ships; can wait.

## Estimate

Building the four Mac phases, with smoke tests, is roughly the same scope
as building the Windows side was: a half-day to a day of focused work per
phase. Most risk is in the per-terminal AppleScript snippets — Terminal.app
and iTerm2 are easy and well-documented; Warp and Ghostty I'd treat as
v2 and ship the fallback path first.
