# snapshot-daemon.ps1 - instance-restorer-5000 record reconciler.
#
# Single-shot iteration over every record in the state dir:
#   1. Prune dead-PID 'exec' records (bash shim case).
#   2. Backfill session_id by scanning ~/.claude/projects/<encoded-cwd>/*.jsonl
#      for files modified after started_at.
#
# Invoked every 60s by Task Scheduler (Phase 4). For now, run manually.
#
# Records with wrapper="wait" (pwsh) are NEVER pruned by PID liveness,
# because their PID is the user's long-lived shell. The shim's try/finally
# handles cleanup on normal claude exit; whatever survives a forced restart
# is exactly what we want to restore.

[CmdletBinding()]
param(
    # Override for tests.
    [string]$StateDir    = (Join-Path $env:USERPROFILE '.claude-restorer\sessions'),
    [string]$ProjectsDir = (Join-Path $env:USERPROFILE '.claude\projects'),
    [string]$LogFile     = (Join-Path $env:USERPROFILE '.claude-restorer\daemon.log'),
    # Records older than this with no live process AND wrapper=wait are
    # treated as orphaned (the shell crashed without running finally).
    # Generous default - we'd rather restore a stale session than lose one.
    [int]$WaitOrphanHours = 72
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $StateDir)) {
    # Nothing to do.
    return
}

# Ensure log dir exists.
$logDir = Split-Path -Parent $LogFile
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

function Write-DaemonLog {
    param([string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "$stamp  $Message" | Add-Content -Path $LogFile -Encoding UTF8
}

# Encode a cwd the same way Claude Code does for ~/.claude/projects/.
# Empirically: every non-alphanumeric char (except `-`) becomes `-`.
# So colon, backslash, slash, dot, underscore, space all map to a dash;
# adjacent non-alphanumerics produce adjacent dashes (no collapsing).
function Convert-CwdToProjectKey {
    param([string]$Cwd)
    return ($Cwd -replace '[^a-zA-Z0-9-]', '-')
}

# Test whether a Windows PID is alive AND is still the process that wrote
# our record (not a different binary that got the PID after reuse).
# Returns $true only if: process exists, name is in $ExpectedNames (when
# given), AND start time is at-or-before the recorded started_at.
# $ExpectedNames are without the .exe suffix (PowerShell's ProcessName).
function Test-WindowsPidAlive {
    param(
        [int]$ProcessId,
        [datetime]$RecordedStartUtc,
        [string[]]$ExpectedNames = $null
    )
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
    } catch {
        return $false
    }
    if ($ExpectedNames -and ($p.ProcessName -notin $ExpectedNames)) {
        # PID got reused by an unrelated binary.
        return $false
    }
    try {
        $procStart = $p.StartTime.ToUniversalTime()
        # 5s slack for clock skew. If the process started noticeably AFTER
        # our record, PID was reused (possibly by a same-name binary).
        if ($procStart -gt $RecordedStartUtc.AddSeconds(5)) {
            return $false
        }
    } catch {
        # StartTime can throw for protected processes. If we can't tell,
        # assume alive (don't risk pruning a real session).
    }
    return $true
}

# WSL PID liveness via `wsl -d <distro> kill -0 <pid>`. Slow (~200ms) but
# works for both Ubuntu and other distros without a guest agent.
function Test-WslPidAlive {
    param([string]$Distro, [int]$ProcessId)
    try {
        & wsl.exe -d $Distro -- kill -0 $ProcessId 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Find the newest session_id whose JSONL file was modified after the
# record's started_at. Returns $null if nothing matches yet.
function Find-SessionId {
    param([string]$Cwd, [datetime]$StartedUtc)
    $key = Convert-CwdToProjectKey $Cwd
    $dir = Join-Path $ProjectsDir $key
    if (-not (Test-Path $dir)) { return $null }
    $candidates = Get-ChildItem -Path $dir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $StartedUtc.AddSeconds(-5) } |
        Sort-Object LastWriteTimeUtc -Descending
    if ($candidates) {
        # Filename without .jsonl extension is the session UUID.
        return $candidates[0].BaseName
    }
    return $null
}

# Save record back to disk, preserving JSON shape. Uses a temp-file rename
# so a concurrent shim writing the same file never sees a half-written one.
function Save-Record {
    param([string]$Path, $Record)
    $tmp = "$Path.tmp"
    $Record | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

# ---------- main loop over records ----------
$now = (Get-Date).ToUniversalTime()
$records = Get-ChildItem -Path $StateDir -Filter '*.json' -ErrorAction SilentlyContinue
$pruned = 0
$updated = 0

foreach ($file in $records) {
    $r = $null
    try {
        $r = Get-Content -Path $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-DaemonLog "skipping corrupt record $($file.Name): $($_.Exception.Message)"
        continue
    }

    # Parse started_at once.
    $startedUtc = $null
    try {
        $startedUtc = ([datetime]$r.started_at).ToUniversalTime()
    } catch {
        Write-DaemonLog "record $($file.Name) has unparseable started_at='$($r.started_at)' - skipping"
        continue
    }

    # ---------- pruning ----------
    $shouldPrune = $false
    $pruneReason = ''

    switch ($r.wrapper) {
        'exec' {
            # Bash exec'd into claude. Record's PID == claude's PID.
            if ($r.host -like 'wsl:*') {
                $distro = ($r.host -replace '^wsl:', '')
                if (-not (Test-WslPidAlive -Distro $distro -ProcessId $r.pid)) {
                    $shouldPrune = $true
                    $pruneReason = "wsl pid $($r.pid) on $distro is gone"
                }
            } else {
                # After exec, the process should be claude. If the PID is
                # held by a different binary (or a younger claude), prune.
                if (-not (Test-WindowsPidAlive -ProcessId $r.pid `
                                               -RecordedStartUtc $startedUtc `
                                               -ExpectedNames @('claude'))) {
                    $shouldPrune = $true
                    $pruneReason = "win pid $($r.pid) is dead, reused, or no longer claude"
                }
            }
        }
        'wait' {
            # pwsh shim. Don't prune by PID alone (the user's pwsh may be
            # long-lived between claude launches; finally handles cleanup).
            # Orphan-prune only very old records where the wrapper PID is
            # ALSO no longer the original powershell process.
            $age = $now - $startedUtc
            if ($age.TotalHours -gt $WaitOrphanHours) {
                if (-not (Test-WindowsPidAlive -ProcessId $r.pid `
                                               -RecordedStartUtc $startedUtc `
                                               -ExpectedNames @('powershell','pwsh'))) {
                    $shouldPrune = $true
                    $pruneReason = "wait record older than ${WaitOrphanHours}h; wrapper pid $($r.pid) gone or reused"
                }
            }
        }
        default {
            Write-DaemonLog "record $($file.Name) has unknown wrapper='$($r.wrapper)' - leaving alone"
        }
    }

    if ($shouldPrune) {
        Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
        Write-DaemonLog "pruned $($file.Name): $pruneReason"
        $pruned++
        continue
    }

    # ---------- session_id backfill ----------
    if (-not $r.session_id) {
        $sid = Find-SessionId -Cwd $r.cwd -StartedUtc $startedUtc
        if ($sid) {
            $r.session_id = $sid
            try {
                Save-Record -Path $file.FullName -Record $r
                Write-DaemonLog "filled session_id=$sid in $($file.Name)"
                $updated++
            } catch {
                Write-DaemonLog "failed to save $($file.Name): $($_.Exception.Message)"
            }
        }
    }
}

if ($pruned -gt 0 -or $updated -gt 0) {
    Write-DaemonLog "tick complete: pruned=$pruned updated=$updated total=$($records.Count)"
}
