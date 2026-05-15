# install-all.ps1 - one-shot installer for instance-restorer-5000.
#
# Per-user install (no admin needed):
#   1. Calls install-shim.ps1 to wire the `claude` function into $PROFILE.
#   2. Registers two per-user scheduled tasks via Register-ScheduledTask:
#        ClaudeRestorer-Restore  - at logon + 30s,  runs restore.ps1 hidden
#        ClaudeRestorer-Daemon   - at logon + 2min, repeats every 60s,
#                                  runs snapshot-daemon.ps1 hidden
# Idempotent: re-running unregisters and re-registers the tasks cleanly.

[CmdletBinding()]
param(
    # Override for tests.
    [string]$ProfileRoot = $HOME,
    # Skip pwsh shim install (e.g., on a machine where you only want the
    # tasks for an already-installed shim).
    [switch]$SkipShim
)

$ErrorActionPreference = 'Stop'

$binDir = $PSScriptRoot
$shimInstaller = Join-Path $binDir 'install-shim.ps1'
$daemonScript  = Join-Path $binDir 'snapshot-daemon.ps1'
$restoreScript = Join-Path $binDir 'restore.ps1'

foreach ($p in @($shimInstaller, $daemonScript, $restoreScript)) {
    if (-not (Test-Path $p)) { throw "missing component: $p" }
}

# ---------- pwsh shim ----------
if (-not $SkipShim) {
    Write-Host "[1/3] Installing pwsh shim..."
    & $shimInstaller -ProfileRoot $ProfileRoot
} else {
    Write-Host "[1/3] Skipping pwsh shim install (-SkipShim)."
}

# ---------- scheduled tasks ----------
$taskDaemon  = 'ClaudeRestorer-Daemon'
$taskRestore = 'ClaudeRestorer-Restore'

function Register-RestorerTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath,
        [int]$LogonDelaySeconds,
        [bool]$Repeat
    )

    # Unregister any prior instance under the same name.
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "  removed existing task '$TaskName'"
    }

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

    # AtLogOn for current user; delay via Repetition's startBoundary trick is
    # awkward, so we use the trigger's RandomDelay (which is actually a fixed
    # max delay PowerShell quirk) — better: set Delay via the underlying CIM
    # object. Easiest portable form: New-ScheduledTaskTrigger -AtLogOn then
    # tweak.
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Delay is set via the trigger's Delay property (PT#S ISO 8601 format).
    $trigger.Delay = "PT${LogonDelaySeconds}S"

    if ($Repeat) {
        # Repeat every 1 minute, indefinitely. The Repetition object isn't
        # set by New-ScheduledTaskTrigger, so build it directly via the
        # CIM class.
        $repClass = Get-CimClass -ClassName MSFT_TaskRepetitionPattern -Namespace Root/Microsoft/Windows/TaskScheduler
        $rep = New-CimInstance -CimClass $repClass -Property @{
            Interval = 'PT1M'
            Duration = ''   # empty = indefinite
            StopAtDurationEnd = $false
        } -ClientOnly
        $trigger.Repetition = $rep
    }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Limited

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description "instance-restorer-5000: $TaskName"

    Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null
    Write-Host "  registered '$TaskName' (delay ${LogonDelaySeconds}s$(if ($Repeat) {', repeats every 60s'}))"
}

Write-Host "[2/3] Registering '$taskRestore' (logon + 30s)..."
Register-RestorerTask -TaskName $taskRestore -ScriptPath $restoreScript `
                      -LogonDelaySeconds 30 -Repeat:$false

Write-Host "[3/3] Registering '$taskDaemon' (logon + 2min, every 60s)..."
Register-RestorerTask -TaskName $taskDaemon -ScriptPath $daemonScript `
                      -LogonDelaySeconds 120 -Repeat:$true

Write-Host ""
Write-Host "Install complete."
Write-Host "  - Restore prompts at logon (30s after sign-in) if any sessions survived."
Write-Host "  - Daemon backfills session_ids and prunes stale records every 60s."
Write-Host ""
Write-Host "Manual triggers any time:"
Write-Host "  Start-ScheduledTask -TaskName $taskRestore"
Write-Host "  Start-ScheduledTask -TaskName $taskDaemon"
Write-Host ""
Write-Host "View task status:    Get-ScheduledTask -TaskName 'ClaudeRestorer-*' | Get-ScheduledTaskInfo"
Write-Host "Logs:                $env:USERPROFILE\.claude-restorer\{daemon,restore}.log"
Write-Host "Uninstall:           & '$binDir\uninstall-all.ps1'"
