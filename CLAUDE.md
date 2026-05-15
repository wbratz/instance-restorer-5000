# CLAUDE.md

Instructions for Claude Code when running in this repo. Essential read for
**any contributor**, but especially for Mac contributors: the original
author has no Mac and the Mac port is being built blind. Without these
notes you'll re-derive every decision and probably get some wrong.

## What this project is

**instance-restorer-5000** restores Claude Code terminal sessions after a
forced OS restart. Three pieces:

1. A **shim** intercepts every `claude` launch and writes a JSON record
   describing the session (folder, terminal, PID).
2. A **daemon** runs every 60s, backfills each record's `session_id` from
   `~/.claude/projects/` and prunes records whose process is gone.
3. A **restore** script runs at next login, reads surviving records, and
   relaunches each in its original terminal with `claude --resume <id>`.

Per-user install. No admin / sudo / runtime dependencies (PowerShell on
Windows, bash + AppleScript on Mac — both ship with the OS).

## Repo layout

```
instance-restorer-5000/
├── README.md                # User-facing install doc
├── CLAUDE.md                # This file
├── .gitignore .gitattributes
├── bin/                     # Windows scripts (PowerShell + Git Bash)
│   ├── claude-shim.{ps1,sh}      # the launch recorders
│   ├── install-shim.{ps1,sh}     # shim-only installers
│   ├── uninstall-shim.{ps1,sh}
│   ├── snapshot-daemon.ps1       # the reconciler
│   ├── restore.ps1               # the prompt + relauncher
│   ├── install-all.ps1           # one-shot full install (shim + tasks)
│   └── uninstall-all.ps1
├── macos/bin/               # Mac scripts (built; awaits Mac smoke verification)
│   ├── claude-shim.sh            # bash recorder; TERM_PROGRAM-based detection
│   ├── install-shim.{sh}         # alias into ~/.zshrc + ~/.bashrc
│   ├── uninstall-shim.sh
│   ├── snapshot-daemon.sh        # bash port; jq + BSD date/stat/ps
│   ├── restore.sh                # osascript + per-terminal AppleScript
│   ├── install-all.sh            # shim + LaunchAgent registration
│   ├── uninstall-all.sh
│   └── plists/                   # LaunchAgent templates (@INSTALL_DIR@ + @USER@)
├── shared/
│   └── record-schema.md     # Cross-platform JSON contract (single source of truth)
└── docs/
    ├── how-it-works.md      # User-facing explanation, demo material
    └── macos-port-spec.md   # Design doc for the Mac port
```

**Why `bin/` instead of `windows/bin/`?** v1 keeps the existing path so
already-installed users don't break. A future v2 may symmetrize to
`windows/bin/` + `macos/bin/` with a deprecation cycle. Don't move
`bin/` — you'll silently break the user's scheduled tasks (which point
at absolute paths from when they ran `install-all.ps1`).

## Phase status (updated as work lands)

| Phase | Scope | Status |
|------:|-------|--------|
| 1 | Windows recorder shims | ✅ shipped |
| 2 | Windows snapshot daemon | ✅ shipped |
| 3 | Windows restore | ✅ shipped |
| 4 | Windows installer + Task Scheduler | ✅ shipped |
| M0 | Add `macos/bin/` + `shared/` directories | ✅ on `feature/macos-port` |
| M1 | Mac recorder + installer | ✅ on `feature/macos-port` |
| M2 | Mac snapshot daemon | ✅ on `feature/macos-port` |
| M3 | Mac restore | ✅ on `feature/macos-port` |
| M4 | Mac LaunchAgents + master installer | ✅ on `feature/macos-port` |
| M5 | Hands-on verification by a Mac user (smoke + edge cases) | pending — needs Mac access |

## Critical contracts (DO NOT BREAK without coordination)

These are shared between Windows and Mac. Changing any of them means
updating BOTH sides in lockstep.

### State directory location

`$HOME/.claude-restorer/sessions/` — same on both OSes. On Windows that's
`%USERPROFILE%\.claude-restorer\sessions\`.

### Record filename

`<pid>-<host>.json`. Host is sanitized (`:` and `/` replaced with `_`)
so that `wsl:Ubuntu` becomes `wsl_Ubuntu` in the filename.

### Record JSON schema

```json
{
  "pid": 12345,
  "host": "wt | vscode | cursor | wsl:Ubuntu | terminal | iterm | warp | ghostty | unknown",
  "wrapper": "exec | wait",
  "cwd": "C:\\Dev\\foo  OR  /Users/me/foo",
  "wt_session": "uuid-or-empty",
  "started_at": "2026-05-15T12:00:00Z",
  "session_id": "claude-conversation-uuid OR null",
  "real_claude": "/path/to/real/claude.exe",
  "args": ["--resume", "..."]
}
```

- `wrapper: "exec"` — the shim `exec`'d the real claude (bash on
  Windows/Mac/Linux). PID = claude's PID. Daemon prunes by PID liveness.
- `wrapper: "wait"` — the shim is the parent and waits for claude
  (PowerShell on Windows). PID = the wrapper shell's PID. Daemon does
  NOT prune by PID alone; orphan-age safeguard with name check.

### cwd → project key encoding

```
project_key = re.sub(r'[^a-zA-Z0-9-]', '-', cwd)
```

Empirically matches Claude Code's `~/.claude/projects/` directory
naming. Examples:

| Input cwd | Encoded key |
|-----------|-------------|
| `C:\Dev\foo` | `C--Dev-foo` |
| `C:\Dev\my-api.service` | `C--Dev-my-api-service` |
| `/Users/me/proj` | `-Users-me-proj` |

Used by the daemon to find session JSONLs in `~/.claude/projects/<key>/`.

### Session-id discovery rule

For a record with `cwd` and `started_at`:

1. Compute `key` per encoding above.
2. List `~/.claude/projects/<key>/*.jsonl`.
3. Take the newest file whose mtime is `>= started_at - 5s` (5s clock
   skew slack).
4. The filename minus `.jsonl` is the `session_id`.

If no match yet, leave `session_id: null`. The daemon will retry on its
next tick.

## Windows-side conventions (already shipped)

- All `.ps1` files written with CRLF (PowerShell's native).
- Profile installation block markers:
  ```
  # >>> instance-restorer-5000 >>>
  ...
  # <<< instance-restorer-5000 <<<
  ```
  Both `install-shim.ps1` (PowerShell) and `install-shim.sh` (bash) use
  these EXACT strings. Don't change them — both installers and
  uninstallers grep for them.
- Scheduled tasks named `ClaudeRestorer-Daemon` and
  `ClaudeRestorer-Restore`. Don't rename without updating
  `uninstall-all.ps1`.
- Daemon log: `$HOME/.claude-restorer/daemon.log`.
- Restore log: `$HOME/.claude-restorer/restore.log`.
- WinForms is used for the dialog. `Add-Type -AssemblyName System.Windows.Forms`
  + `[System.Windows.Forms.MessageBox]::Show(...)`.
- Tab spawn idiom: `wt -w 0 nt --startingDirectory <cwd> -- powershell.exe -NoExit -Command "claude --resume <id>"`.

## Mac-side conventions (being built — for contributors)

### BSD vs GNU command differences (will bite you)

macOS ships BSD versions of common Unix tools. Bash scripts written for
Linux often break silently on Mac. The biggest gotchas:

| Command | GNU/Linux | macOS BSD |
|---------|-----------|-----------|
| `date -d "string"` | Parses arbitrary strings | **No `-d`**. Use `date -j -f "%Y-%m-%dT%H:%M:%SZ" "$str" "+%s"` |
| `stat -c %Y file` | mtime as epoch | **No `-c`**. Use `stat -f %m file` |
| `sed -i 's/x/y/' file` | In-place, no backup | **Requires `-i ''`**: `sed -i '' 's/x/y/' file` |
| `readlink -f path` | Canonicalize | **No `-f`**. Use `realpath` (install via `brew install coreutils` if missing) or a workaround |
| `ps -p $pid -o lstart=` | Custom format | Available on Mac, but format string is `"%a %b %e %T %Y"` |
| `find ... -newermt "iso-string"` | Works | **Doesn't work the same** — pre-compute epoch and use `-newer` against a touched reference file |

Don't use GNU-only flags. If unsure, run `man <cmd>` on the Mac to
verify or test in Git Bash on Windows (which uses GNU coreutils — opposite
problem, but easier to detect).

### `jq` is required

We assume `jq` is installed (default on most dev Macs; trivial
`brew install jq` if not). Don't hand-write JSON in bash — escaping is
a nightmare and fragile.

### Scheduling — launchd

Two LaunchAgent plists in `~/Library/LaunchAgents/`. Loaded via
`launchctl bootstrap gui/$(id -u) <plist>`. Unloaded via
`launchctl bootout`. Manually triggered via `launchctl kickstart -k`.

**No native logon delay.** Use a wrapper: `bash -c 'sleep 30 && exec
/path/to/script.sh'` in `ProgramArguments`.

### Dialog — osascript

```bash
answer="$(osascript <<EOF
display dialog "summary text here" \
  with title "instance-restorer-5000" \
  buttons {"No","Yes"} default button "Yes"
EOF
)"
[[ "$answer" == *"Yes"* ]] && proceed
```

Built into macOS. No package install. Multi-line text works.

### Per-terminal automation matrix

| `host` | Approach | Tier |
|--------|----------|------|
| `terminal` (Terminal.app) | `osascript -e 'tell app "Terminal" to do script "..."'` | First-class |
| `iterm` (iTerm2) | `osascript` against `tell application "iTerm" to create window with default profile` then `write text` | First-class |
| `warp` | `open -a Warp <cwd>`; show resume command in summary dialog | Fallback (v1) |
| `ghostty` | `open -na Ghostty --args --working-directory=<cwd>`; show resume command | Fallback (v1) |
| `vscode` | `code <cwd>`; show resume command (same as Windows) | Fallback |
| `cursor` | `cursor <cwd>`; show resume command | Fallback |
| `unknown` | Open Terminal.app at cwd, print resume command | Fallback |

Iterating on Warp/Ghostty native automation is a reasonable v2.

### Bundle ID prefix

Use `com.claude-restorer.*` for plist `Label` keys. Don't introduce a
personal handle (e.g. `com.<your-name>.*`) — these labels are visible
in `launchctl list` and shared across contributors.

## What's out of scope (don't propose these)

- **cmd.exe on Windows.** No shell-level alias mechanism. Adding it
  requires PATH manipulation + a `claude.cmd` shim that calls pwsh —
  ~500ms launch overhead. Not worth it; modern devs use pwsh or bash.
- **fish / nu / other Windows shells.** Same reasoning.
- **iCloud / cross-machine sync of records.** Local-only by design.
- **Survive disk failure.** Out of scope; if your drive dies you have
  bigger problems.
- **A GUI configuration tool.** Defaults work; advanced users edit
  scripts.
- **Single cross-platform runtime (Python/Node).** Explicitly rejected:
  asking every user to install a runtime undermines the "zero
  dependencies" install promise. Each OS uses native primitives.

## Testing without a Mac (for the original maintainer)

Bash syntax can be partially validated on Git Bash for Windows, which
uses GNU coreutils. This catches:

- Bash grammar errors (`bash -n script.sh`)
- Missing quoting / unset variable issues (`bash -u script.sh`)
- Incorrect bash builtins

It does NOT catch:

- BSD vs GNU command differences (see table above) — Git Bash uses GNU
- macOS-specific paths (`/Users/...`, `~/Library/LaunchAgents/`)
- AppleScript or osascript behavior
- launchd interactions
- Real terminal app responses to AppleScript

For untestable changes, write defensively, document each assumption with
a comment, and add a "Mac-only verification" section to the PR description
listing exactly what a Mac user should run to confirm.

## Common debugging commands

```bash
# Windows: see live records
ls $env:USERPROFILE\.claude-restorer\sessions\

# Windows: tail the daemon log
Get-Content $env:USERPROFILE\.claude-restorer\daemon.log -Tail 20

# Windows: force a daemon tick
Start-ScheduledTask -TaskName ClaudeRestorer-Daemon

# Windows: force a restore prompt
Start-ScheduledTask -TaskName ClaudeRestorer-Restore

# Windows: dry-run restore against current state
& 'C:\Dev\instance-restorer-5000\bin\restore.ps1' -DryRun

# Mac: see live records
ls ~/.claude-restorer/sessions/

# Mac: tail the daemon log
tail -20 ~/.claude-restorer/daemon.log

# Mac: force a daemon tick
launchctl kickstart -k "gui/$(id -u)/com.claude-restorer.daemon"

# Mac: force a restore prompt
launchctl kickstart -k "gui/$(id -u)/com.claude-restorer.restore"
```

## When in doubt

Read `docs/how-it-works.md` for the user-facing mental model and
`docs/macos-port-spec.md` for the Mac design rationale. Most "why does
it work this way" questions are answered there.

If you change something architectural, update this file AND the relevant
doc. The spec is the contract; this CLAUDE.md is the implementation
notebook. Keeping them in sync is what makes the project remain
hand-off-able to a stranger six months from now.