# How instance-restorer-5000 works

Companion doc for the live demo. Read it cold to understand the system;
keep it open on a second monitor while presenting.

## The 30-second pitch

Every time you launch `claude`, a tiny background recorder writes a small
JSON file with three things: which folder you're in, which terminal
you're in, and which conversation ID Claude is using. When your machine
gets force-restarted, those JSON files survive on disk. The next time you
log in, a Windows dialog asks "want your Claude sessions back?" — click
yes, and your terminals reopen with conversations resumed exactly where
they were.

## A user's day with it

### Act 1 — Install (one time, ~2 seconds)

You run one command in PowerShell:

```powershell
& 'C:\path\to\instance-restorer-5000\bin\install-all.ps1'
```

You see three numbered steps complete and a "Install complete" message.
That's it. **No admin prompt, no reboot, no dialog box.** You forget
about it.

What happened behind the scenes:

1. A `claude` function was added to your PowerShell profile, so every
   future `claude` you type runs through a tiny wrapper script first.
2. Two scheduled tasks were registered under your user account:
   - **`ClaudeRestorer-Daemon`** — runs every 60 seconds in a hidden
     window. Maintains the state files.
   - **`ClaudeRestorer-Restore`** — runs once at every login. Asks the
     question.

### Act 2 — Normal day, normal work

You're working. You launch Claude in three different folders to work on
three different things in parallel. You type `claude` like you always
have. **You see no difference.** No popups, no slowdowns, no extra
output.

What's actually happening as you work:

- Each time you type `claude`, the wrapper script runs first. It takes
  ~5 milliseconds. You can't perceive it. It writes a small JSON file
  into `%USERPROFILE%\.claude-restorer\sessions\` containing your PID,
  your folder, and which terminal you're in.
- About a minute later, the daemon runs (you don't see it — hidden
  window, runs for ~50ms, closes). It looks at each JSON file, finds
  Claude's actual conversation ID from `~/.claude/projects/`, and stitches
  it back into the JSON. Now each record knows enough to fully resume
  that conversation.
- When you `/exit` a Claude conversation normally, the wrapper deletes
  its JSON file as part of cleanup. The system goes back to tracking only
  what's actually live.

So at any given moment, the state directory has exactly one JSON file per
currently-running Claude conversation. Open three Claudes, three files.
Close one, two files. Open another, three files again. It's a real-time
mirror of what's running.

### Act 3 — The crash

It's 11am. IT pushes a forced reboot. Your screen goes black. You lose
**every PowerShell window**, **every Claude conversation**, **all
context**.

What just happened on disk:

- Your PowerShell shells got killed instantly. They never got to run
  their cleanup code, so **the JSON files in your state directory are
  still there.**
- Each surviving JSON file is essentially a recipe: "open Windows
  Terminal in this folder, run `claude --resume <this-id>`."

You wait through the reboot. You sign back in.

### Act 4 — Coming back

About 30 seconds after you sign in, **a small Windows dialog appears**:

```
Restore 3 Claude session(s)?

  wt   C:\Dev\my-api.service                 [a400d7a5]
  wt   C:\Dev\automation-toolkit             [b9f3c2d1]
  wt   C:\Dev\platform                       [e7a82914]

[Yes]  [No]
```

You click **Yes**.

In the next second or two:
- Three new tabs spawn in your existing Windows Terminal window
- Each tab is in the right folder
- Each tab automatically runs `claude --resume <id>` for its session
- Claude reopens, you scroll up, and **the entire conversation is
  there** — every back-and-forth, every file Claude was working on, the
  full context

You go back to work. The whole interruption was: forced reboot, Windows
sign-in, click Yes once, everything is back.

## What's actually happening behind the scenes

Three pieces, each with a clear job. The system is small on purpose.

### Piece 1: The recorder (`claude-shim.ps1`)

When you typed the install command, it added two lines to your PowerShell
profile:

```powershell
function claude { & 'C:\path\to\bin\claude-shim.ps1' @args }
```

That's the magic intercept. Now every `claude` you type doesn't go
straight to claude.exe — it goes to this script first. The script:

1. Figures out which terminal you're in (Windows Terminal? VS Code? WSL?
   Cursor?). It does this by checking environment variables your terminal
   sets (`WT_SESSION`, `TERM_PROGRAM`, `WSL_DISTRO_NAME`, etc.).
2. Writes a JSON file to `%USERPROFILE%\.claude-restorer\sessions\` named
   `<pid>-<host>.json` containing what it knows so far.
3. Hands control off to the real `claude.exe`, with a `try/finally`
   around it. If you exit Claude normally, the `finally` block deletes
   the JSON file. If your shell gets killed (the crash case), the finally
   never runs — and the JSON survives.

That's the whole recorder. Maybe 100 lines of PowerShell. Adds ~5ms to
every Claude launch.

### Piece 2: The daemon (`snapshot-daemon.ps1`)

The recorder writes records but it doesn't know Claude's session ID at
launch time — Claude itself hasn't picked one yet. The daemon's job is
to fix that, plus clean up records that no longer represent live
conversations.

Every 60 seconds (Task Scheduler triggers it), the daemon does one quick
pass:

1. **Backfill session IDs.** For each record without one, it looks at
   `~/.claude/projects/<encoded-folder-path>/` and finds the newest
   `.jsonl` file modified after the record was created. That filename's
   the session ID. Writes it back into the JSON.
2. **Prune dead records.** For any record whose process is gone (and it
   wasn't a clean exit), the daemon removes the file. It's careful here:
   it checks both that the PID exists AND that the process at that PID
   is what we expect (claude.exe or powershell.exe, depending on the
   record type), AND that the start time matches — because Windows
   reuses PIDs aggressively after a crash, and we don't want to mistake
   "explorer.exe happens to have the old Claude's PID" for a live record.

It runs hidden, finishes in ~50ms, doesn't show in the taskbar. You
never see it.

### Piece 3: The restore (`restore.ps1`)

This one only matters at login. Task Scheduler fires it 30 seconds after
you sign in. It:

1. Reads every JSON file in the state directory.
2. Splits them into "ready to restore" (have session IDs) and "skipped"
   (don't yet — usually because Claude was killed before writing any
   messages).
3. **If the state directory is empty, exits silently.** No popup, nothing.
   This is the everyday case — most days nothing crashed.
4. If there's anything to restore, pops a Windows dialog (built with
   System.Windows.Forms — same dialog API Notepad uses) showing a Yes/No
   prompt with the summary.
5. If you click Yes, for each restorable record it runs the right
   command for that terminal:
   - Windows Terminal: `wt -w 0 nt --startingDirectory <folder> -- powershell.exe -NoExit -Command "claude --resume <id>"` — opens a new tab in your most recently active WT window
   - WSL: `wt -w 0 nt -p <distro> -- wsl.exe -d <distro> --cd <folder> -- bash -lc 'claude --resume <id>; exec bash'`
   - VS Code / Cursor: opens the folder via `code` / `cursor`, then
     shows the resume command in a follow-up dialog so you paste it
6. Deletes each record after successfully launching, so the next time
   the system fires, those sessions don't get re-restored.

## The non-obvious design choices, briefly

These are the things that took thinking to get right; most users will
never know they exist, but they're worth knowing if anyone asks during
the demo.

### Why PowerShell, not a real installable program?

Zero dependencies. Every Windows machine has PowerShell, Task Scheduler,
and System.Windows.Forms baked in. Distributing this as an .exe would
mean code-signing, an installer wizard, antivirus headaches. Five .ps1
files in a folder is the lightest possible footprint.

### Why two scheduled tasks, not one?

Different responsibilities, different cadences:
- The restore needs to happen **once at login** with a quick delay so
  the desktop has time to settle.
- The daemon needs to run **continuously** every 60 seconds, but only
  *after* restore has had its chance — otherwise the daemon could prune
  records before the user has decided whether to restore them.
- That's why the daemon is set to start 2 minutes after login (after
  restore's 30-second window has long since passed).

### How does the system avoid restoring sessions that are already running?

This is what burned us in early testing. After the morning crash, you
might have already manually opened a few Claude windows. We don't want
restore to spawn duplicates. The system handles this in two ways:
1. **Records get deleted on clean exit.** Manually-opened sessions that
   you then closed don't leave records around.
2. **The daemon's PID-reuse check** distinguishes "this PID belongs to
   the powershell that originally ran Claude" from "this PID got reused
   by some unrelated process after the crash." Stale records get cleaned
   up; valid live ones stay.

### How does the system know which session ID belongs to which folder?

Claude Code stores conversations in
`~/.claude/projects/<encoded-folder-path>/<session-uuid>.jsonl`. The
encoding is "replace every non-alphanumeric character with a dash" — so
`C:\Dev\my-api.service` becomes
`C--Dev-my-api-service`. The daemon mirrors this encoding
to find the right project folder, then takes the newest .jsonl file as
the session ID. This is how we link a recorder JSON back to a real Claude
conversation file.

### What happens if the daemon misses a tick or PowerShell isn't available?

Nothing bad. The recorder still writes JSON files even if the daemon
never runs. The records just won't have session IDs — at restore time,
they show up in the "skipped" list with a note that says "open this
folder and run `claude --resume`" so the user can pick the conversation
manually from Claude's built-in resume picker.

### Why a dialog instead of just auto-restoring everything?

Two reasons:
1. **Sometimes you don't want everything back.** Maybe you only crashed
   one important conversation and the others were experiments. The
   summary lets you see what's there before agreeing.
2. **Sometimes the company forced the reboot for a reason** (security
   patch, configuration change). Auto-spawning four PowerShell windows
   the moment you sign in would be jarring. A click is the appropriate
   level of friction.

## What the system explicitly doesn't try to do

- **Save anything inside Claude.** All session state is Claude Code's own
  responsibility (it stores the JSONL files in `~/.claude/projects/`).
  We just remember "you had session X open in folder Y" — Claude does
  the actual conversation restore.
- **Sync across machines.** State stays local. If you sign into a
  different machine, you start fresh.
- **Survive disk failure.** The state files live on the same disk as
  Claude's own session files. If your drive dies, both are gone — but
  that's a much bigger problem than a forced reboot.
- **Handle terminals we didn't build for.** Native Windows Terminal,
  VS Code, Cursor, and WSL all work. cmd.exe, nu, fish — not supported.
  Likewise no automatic restoration in tmux or screen sessions.

## What it costs you to have running

| Resource | Cost |
|----------|------|
| Disk | ~50KB of JSON state at peak; logs cap at maybe a few MB |
| RAM | Zero idle. The daemon is a 50ms PowerShell run every 60 seconds |
| CPU | Negligible — 3 daemon ticks per minute, each well under 0.1% CPU |
| Startup time | ~5ms added to each `claude` launch |
| Notifications | None during normal use. One dialog after a crash. |

## A demo-friendly summary line

> "Every Claude launch leaves a fingerprint. Every clean exit erases its
> own fingerprint. After a crash, the fingerprints that survive are
> exactly the conversations you had open — and a single click brings
> them all back."
