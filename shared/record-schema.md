# Record schema

The single shared contract between the Windows and macOS implementations.
**Both sides must read and write records that conform to this schema.**

State directory: `$HOME/.claude-restorer/sessions/`
File name: `<pid>-<host>.json` where `<host>` is sanitized
(`:` and `/` replaced with `_`).

## Fields

```jsonc
{
  // Process ID at launch time. For wrapper="exec" this is claude's PID
  // (after exec); for wrapper="wait" this is the wrapper shell's PID.
  "pid": 12345,

  // Which terminal hosted the launch. See "Host enum" below.
  "host": "wt",

  // How the shim handed off to claude. Affects how the daemon prunes.
  // - "exec": shim exec'd into claude. PID == claude's PID. Daemon
  //           prunes by liveness (process gone OR PID reused).
  // - "wait": shim is a parent process and `wait`s for claude.
  //           PID == wrapper shell's PID. Daemon does NOT prune by
  //           liveness alone; orphan-age + name check only.
  "wrapper": "exec",

  // Working directory at launch time, as the OS reports it.
  // Windows: backslash form, e.g. "C:\\Dev\\foo".
  // macOS/Linux: POSIX form, e.g. "/Users/me/proj" or "/home/me/proj".
  "cwd": "C:\\Dev\\foo",

  // Windows Terminal session UUID, if available. Empty otherwise.
  // On Mac, mirror this concept with iTerm2's $ITERM_SESSION_ID where
  // available; field name stays "wt_session" for cross-platform record
  // compatibility.
  "wt_session": "abc-def-...",

  // ISO 8601 UTC, e.g. "2026-05-15T12:00:00Z".
  // Used by the daemon to:
  //   1. Detect PID reuse (process start time > started_at + 5s slack)
  //   2. Filter session JSONLs (mtime >= started_at - 5s)
  "started_at": "2026-05-15T12:00:00Z",

  // Filled in by the daemon once it can match a JSONL in
  // ~/.claude/projects/<encoded-cwd>/. Null until then.
  "session_id": "a400d7a5-909c-4b0e-a38f-ae92fd4aeaf0",

  // Path to the real claude binary the shim invoked. Recorded for
  // debugging — restore doesn't use it (restore relies on the user's
  // shell having `claude` on PATH).
  "real_claude": "C:\\Users\\foo\\.local\\bin\\claude.exe",

  // Args the user passed to `claude`. Empty array for a bare launch.
  // Recorded for debugging; restore always uses --resume <session_id>.
  "args": []
}
```

## Host enum

| Value | OS | Source detection |
|-------|----|-----------------|
| `wt` | Windows | `$WT_SESSION` env var present |
| `vscode` | both | `$TERM_PROGRAM == "vscode"` (no Cursor markers) |
| `cursor` | both | `$TERM_PROGRAM == "vscode"` AND (`$CURSOR_TRACE_ID` set OR `$TERM_PROGRAM_VERSION` contains `cursor` OR `$VSCODE_GIT_ASKPASS_NODE` contains `cursor`) |
| `wsl:<distro>` | Windows | `$WSL_DISTRO_NAME` env var present |
| `terminal` | macOS | `$TERM_PROGRAM == "Apple_Terminal"` |
| `iterm` | macOS | `$TERM_PROGRAM == "iTerm.app"` |
| `warp` | macOS | `$TERM_PROGRAM == "WarpTerminal"` |
| `ghostty` | macOS | `$TERM_PROGRAM == "ghostty"` |
| `unknown` | both | None of the above matched |

The `unknown` case is supported throughout: restore falls back to opening
a default terminal at the cwd with the resume command printed.

## cwd → project key encoding

Used by the daemon to find session JSONLs in `~/.claude/projects/<key>/`.

```
key = re.sub(r'[^a-zA-Z0-9-]', '-', cwd)
```

Empirically matches Claude Code's directory naming. **Examples that
must hold:**

| Input cwd | Encoded key |
|-----------|-------------|
| `C:\Dev\foo` | `C--Dev-foo` |
| `C:\Dev\Carvana.AddressVerification` | `C--Dev-Carvana-AddressVerification` |
| `/Users/me/proj` | `-Users-me-proj` |
| `/home/me/proj` | `-home-me-proj` |
| `/mnt/c/Dev/foo` | `-mnt-c-Dev-foo` |

If you change the encoder, write a unit test against this table first.

## Session-id discovery rule

For a record with `cwd` and `started_at`:

1. Compute `key` per encoding above.
2. List `~/.claude/projects/<key>/*.jsonl`.
3. Filter to files whose `mtime >= started_at - 5s` (5s clock-skew slack).
4. Sort descending by mtime; take the newest.
5. The filename minus `.jsonl` is the `session_id`.

If no match yet, leave `session_id: null`. The daemon retries every tick.

## Constraints both implementations must honor

- **Atomic writes.** Records may be read by the daemon while the shim
  is still writing them. Use a temp file + rename pattern, or write the
  whole record in one syscall.
- **JSON validity.** Use a real JSON encoder (PowerShell's
  `ConvertTo-Json`, `jq`, or equivalent). Don't hand-format with backslash
  escaping in shell — too fragile.
- **UTC timestamps.** Always UTC for `started_at`. Never local time.
- **No secrets.** Records contain user-visible info only (paths, terminal
  names, session IDs). They live in `$HOME` so are user-readable;
  shouldn't contain credentials.
- **Forward compatibility.** Implementations should ignore unknown fields
  rather than failing. Future versions may add fields.
