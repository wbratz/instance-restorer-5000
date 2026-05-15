# instance-restorer-5000

Restore Claude Code terminal sessions after a forced Windows restart.

Every `claude` you launch is recorded (host + cwd + session id). Whatever
records survive a crash get listed in a Yes/No prompt at next logon, and
the system reopens each conversation in its original terminal.

Per-user install. No admin rights needed.

---

## Install — Windows

### 1. Clone

Pick any stable location and clone the repo there. **Once installed, the
scheduled tasks pin the absolute paths of the scripts** — moving the
directory later breaks restore + daemon. The examples below assume
`$HOME\instance-restorer-5000` (i.e. `%USERPROFILE%\instance-restorer-5000`):

```powershell
git clone https://github.com/wbratz/instance-restorer-5000.git $HOME\instance-restorer-5000
```

If you put it somewhere else, substitute that path everywhere you see
`$HOME\instance-restorer-5000` below.

### 2. Run the installer

From any PowerShell window:

```powershell
& "$HOME\instance-restorer-5000\bin\install-all.ps1"
```

This does three things:

1. Adds a `claude` function to your `$PROFILE` (Windows PowerShell 5.1 and
   PowerShell 7) so launches go through the recorder.
2. Registers `ClaudeRestorer-Restore` — runs at logon + 30s. Shows a Yes/No
   dialog if any sessions survived the last shutdown; on Yes, reopens them.
3. Registers `ClaudeRestorer-Daemon` — runs at logon + 2 min, then every
   60s. Backfills session-ids and prunes records for processes that are
   gone for good.

Open a new PowerShell window after install:

```powershell
Get-Command claude        # should report CommandType: Function
```

That's it. Crash your machine, sign back in, accept the dialog.

### Optional: bash side (Git Bash, VS Code/Cursor with bash, WSL)

The pwsh shim only intercepts launches from a pwsh shell. If you also
launch `claude` from bash, install the bash shim:

```bash
bash "$HOME/instance-restorer-5000/bin/install-shim.sh"
```

For WSL, run the bash installer **inside the distro** (not from Windows).
WSL's `$HOME` points at the Linux home, not the Windows clone — point at
the Windows path explicitly:

```bash
# inside `wsl -d Ubuntu` (replace <you> with your Windows username)
bash /mnt/c/Users/<you>/instance-restorer-5000/bin/install-shim.sh
```

## Uninstall — Windows

```powershell
& "$HOME\instance-restorer-5000\bin\uninstall-all.ps1"
```

Removes both scheduled tasks, the `$PROFILE` block, and (by default) the
state dir at `%USERPROFILE%\.claude-restorer`. Pass `-KeepShim` to leave
the function in `$PROFILE`, or `-KeepState` to preserve records.

For the bash side: `bash "$HOME/instance-restorer-5000/bin/uninstall-shim.sh"`.

---

## Install — macOS

> **Status:** built and unit-tested on Git Bash; awaiting hands-on
> verification by a Mac user before recommending broadly. See
> `docs/macos-port-spec.md`.

Prerequisite: `jq` (`brew install jq` if missing).

### 1. Clone

Pick any stable location and clone there. The LaunchAgent plists pin the
absolute path of the scripts; moving the directory later breaks restore +
daemon. Examples assume `$HOME/instance-restorer-5000`:

```bash
git clone https://github.com/wbratz/instance-restorer-5000.git $HOME/instance-restorer-5000
```

### 2. Run the installer

```bash
bash $HOME/instance-restorer-5000/macos/bin/install-all.sh
```

This does three things:

1. Adds a `claude` alias to your `~/.zshrc` (and `~/.bashrc` /
   `~/.bash_profile` if they exist) so launches go through the recorder.
2. Generates two LaunchAgent plists in `~/Library/LaunchAgents/`:
   - `com.claude-restorer.restore` — runs at logon + 30s. Shows a Yes/No
     dialog (osascript) if any sessions survived; on Yes, relaunches each
     in its original terminal.
   - `com.claude-restorer.daemon` — runs every 60s. Same job as the
     Windows daemon: backfill session_id, prune dead records.
3. Loads both via `launchctl bootstrap gui/$(id -u)`.

Open a new terminal and verify:

```bash
type claude
# claude is an alias for /Users/.../instance-restorer-5000/macos/bin/claude-shim.sh
```

No `sudo`. Per-user.

## Uninstall — macOS

```bash
bash $HOME/instance-restorer-5000/macos/bin/uninstall-all.sh
```

Unloads both LaunchAgents (`launchctl bootout`), removes the plists from
`~/Library/LaunchAgents/`, removes the alias from your shell rc files,
and removes the state dir. Pass `--keep-shim` or `--keep-state` to
preserve those.

---

## What runs where

| Component | File | When |
|-----------|------|------|
| Recorder (pwsh) | `bin/claude-shim.ps1` | Each `claude` launch from pwsh |
| Recorder (bash) | `bin/claude-shim.sh` | Each `claude` launch from bash/WSL |
| Daemon | `bin/snapshot-daemon.ps1` | Every 60s (after logon + 2 min) |
| Restore | `bin/restore.ps1` | Logon + 30s |
| Installer | `bin/install-all.ps1` | Once, by you |

State lives at:
- Records: `%USERPROFILE%\.claude-restorer\sessions\<pid>-<host>.json`
- Daemon log: `%USERPROFILE%\.claude-restorer\daemon.log`
- Restore log: `%USERPROFILE%\.claude-restorer\restore.log`

## Per-host restore behaviour

| Recorded `host` | What restore does |
|-----------------|-------------------|
| `wt` | `wt -w 0 nt --startingDirectory <cwd> -- powershell.exe -NoExit -Command "claude --resume <id>"` |
| `wsl:<distro>` | `wt -w 0 nt -p "<distro>" -- wsl.exe -d <distro> --cd <cwd> -- bash -lc "claude --resume <id>; exec bash"` |
| `vscode` / `cursor` | `code <cwd>` (or `cursor <cwd>`), then shows the resume command in a final dialog so you paste it into each editor's terminal |
| `unknown` | Falls back to a wt pwsh tab at the cwd that prints the resume command |

`wt -w 0` opens new tabs in your most recently active Windows Terminal
window — restored Claude sessions slot in alongside whatever you have
open. If WT isn't running, restore opens a new window with the tabs.

## Manual triggers and inspection

```powershell
# Trigger a restore prompt right now (uses current state dir):
Start-ScheduledTask -TaskName ClaudeRestorer-Restore

# Force one daemon tick:
Start-ScheduledTask -TaskName ClaudeRestorer-Daemon

# Or invoke the scripts directly:
& "$HOME\instance-restorer-5000\bin\restore.ps1" -DryRun  # preview, no relaunch
& "$HOME\instance-restorer-5000\bin\snapshot-daemon.ps1"

# Task status:
Get-ScheduledTask -TaskName 'ClaudeRestorer-*' | Get-ScheduledTaskInfo

# Live records:
Get-ChildItem $env:USERPROFILE\.claude-restorer\sessions\
```

## How a single record looks

```json
{
  "pid": 22372,
  "host": "wt",
  "wrapper": "wait",
  "cwd": "C:\\Users\\alice\\my-project",
  "wt_session": "4986d202-57cd-4b44-9709-ffd19f880bfe",
  "started_at": "2026-05-15T15:56:27Z",
  "session_id": "f6c1c0f9-ea7b-4375-8533-d6409449b242",
  "real_claude": "C:\\Users\\alice\\.local\\bin\\claude.exe",
  "args": []
}
```

`wrapper` is `exec` for bash records (the shim `exec`s into claude, so the
PID becomes claude's) or `wait` for pwsh records (the shim invokes claude
as a child and a `try/finally` removes the record on normal exit).

## Limitations

- **cmd.exe / nu / fish not supported.** Bash and PowerShell only. cmd
  has no shell-level alias/function mechanism we could hook; supporting
  it would require a `claude.cmd` shim earlier on `PATH` plus invasive
  installer changes. Not planned unless someone needs it — switch to
  PowerShell or Git Bash for Claude work.
- **Cursor detection is heuristic.** Relies on `CURSOR_TRACE_ID` or
  `cursor` substring in `TERM_PROGRAM_VERSION` / `VSCODE_GIT_ASKPASS_NODE`.
  If a Cursor launch shows up as `host: "vscode"`, run `gci env:` in that
  terminal and we'll add a detection rule.
- **VS Code / Cursor terminal restore is half-automatic.** The folder
  reopens automatically; the `claude --resume <id>` command is shown in a
  final dialog for you to paste into each editor's terminal.
- **PID reuse on cold boot.** Long-lived `wait` records hold the user's
  pwsh PID. After reboot, that PID may belong to an unrelated process.
  The daemon now verifies the live PID is `powershell.exe` / `pwsh.exe`
  before treating a `wait` record as still valid (orphan-age check).
- **No session-id, no `--resume`.** If a Claude session was killed before
  it wrote any messages to disk, the JSONL doesn't exist and the daemon
  can't backfill `session_id`. Restore lists those records but skips them
  — open the folder yourself and run `claude --resume` to pick from the
  full session list.
