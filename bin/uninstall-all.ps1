# uninstall-all.ps1 - reverse install-all.ps1.

[CmdletBinding()]
param(
    [string]$ProfileRoot = $HOME,
    [switch]$KeepShim,
    [switch]$KeepState
)

$ErrorActionPreference = 'Continue'

$binDir = $PSScriptRoot
$shimUninstaller = Join-Path $binDir 'uninstall-shim.ps1'

# ---------- scheduled tasks ----------
foreach ($name in @('ClaudeRestorer-Restore','ClaudeRestorer-Daemon')) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "removed task '$name'"
    } else {
        Write-Host "task '$name' was not registered"
    }
}

# ---------- pwsh shim ----------
if (-not $KeepShim) {
    if (Test-Path $shimUninstaller) {
        & $shimUninstaller -ProfileRoot $ProfileRoot
    } else {
        Write-Warning "shim uninstaller missing: $shimUninstaller"
    }
} else {
    Write-Host "kept pwsh shim (-KeepShim)"
}

# ---------- state dir ----------
$stateDir = Join-Path $env:USERPROFILE '.claude-restorer'
if (-not $KeepState -and (Test-Path $stateDir)) {
    Remove-Item -Recurse -Force $stateDir
    Write-Host "removed state dir $stateDir"
} elseif ($KeepState) {
    Write-Host "kept state dir $stateDir (-KeepState)"
}

Write-Host ""
Write-Host "Uninstall complete."
