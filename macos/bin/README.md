# macos/bin/

macOS implementation of instance-restorer-5000.

**Status:** in progress on `feature/macos-port`. See `../../docs/macos-port-spec.md`
for design and `../../CLAUDE.md` for contributor notes.

When complete, this directory will mirror the structure of `../../bin/`
(the Windows side) with bash-and-AppleScript equivalents:

```
macos/bin/
├── claude-shim.sh           # the recorder
├── install-shim.sh
├── uninstall-shim.sh
├── snapshot-daemon.sh       # the reconciler (runs every 60s via launchd)
├── restore.sh               # the prompt + relauncher (runs at logon)
├── install-all.sh           # one-shot full install
├── uninstall-all.sh
└── plists/
    ├── daemon.plist.template
    └── restore.plist.template
```

## Install (once macOS scripts ship)

```bash
./macos/bin/install-all.sh
```

That single command will:
1. Append the `claude` alias to your zsh and bash rc files.
2. Generate two LaunchAgent plists in `~/Library/LaunchAgents/` from the
   templates in `plists/`, substituting your install path.
3. `launchctl bootstrap` both agents into your GUI session.

No `sudo`. No Homebrew except `jq` (auto-detected; installer prints the
brew command if missing).
