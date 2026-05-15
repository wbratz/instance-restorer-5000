# claude-shim.ps1 - instance-restorer-5000 launch recorder for PowerShell.
#
# Companion to claude-shim.sh. Invoked via a `claude` function defined in the
# user's PowerShell $PROFILE. Records the launch, then invokes the real
# claude.exe in-place (& operator) so the TUI gets a proper console. A
# try/finally removes the record on clean exit. Forced restarts skip the
# finally block - exactly the case we want preserved.

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Continue'

# ---------- locate state dir ----------
$stateDir = Join-Path $env:USERPROFILE '.claude-restorer\sessions'
if (-not (Test-Path $stateDir)) {
    try { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
    catch { Write-Warning "claude-shim.ps1: cannot create $stateDir" }
}

# ---------- detect host ----------
function Get-HostName {
    if ($env:WSL_DISTRO_NAME) { return "wsl:$($env:WSL_DISTRO_NAME)" }
    if ($env:TERM_PROGRAM -eq 'vscode') {
        if ($env:CURSOR_TRACE_ID `
            -or ($env:TERM_PROGRAM_VERSION -and $env:TERM_PROGRAM_VERSION -like '*cursor*') `
            -or ($env:VSCODE_GIT_ASKPASS_NODE -and $env:VSCODE_GIT_ASKPASS_NODE -like '*cursor*')) {
            return 'cursor'
        }
        return 'vscode'
    }
    if ($env:WT_SESSION) { return 'wt' }
    return 'unknown'
}
$hostName = Get-HostName

# ---------- resolve real claude.exe (skip our own function/script) ----------
$realClaude = $null
$candidates = Get-Command claude -All -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandType -eq 'Application' }
foreach ($c in $candidates) {
    # Skip the .ps1 itself in case someone put it on PATH as `claude.ps1`
    if ($c.Source -like '*claude-shim.ps1') { continue }
    $realClaude = $c.Source
    break
}

if (-not $realClaude) {
    Write-Error "claude-shim.ps1: no real claude.exe found on PATH"
    exit 127
}

# ---------- write record ----------
$pidVal = $PID
$startedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$hostSafe = $hostName -replace '[:\\/]', '_'
$record = Join-Path $stateDir ("$pidVal-$hostSafe.json")

$payload = [ordered]@{
    pid          = $pidVal
    host         = $hostName
    # "wait" = wrapper stays alive while claude runs; finally cleans up the
    # record on normal exit. Daemon should NOT prune these via PID liveness
    # (the wrapper PID is the user's long-lived shell).
    wrapper      = 'wait'
    cwd          = $PWD.Path
    wt_session   = if ($env:WT_SESSION) { $env:WT_SESSION } else { '' }
    started_at   = $startedAt
    session_id   = $null
    real_claude  = $realClaude
    # PowerShell 5.1 quirk: @() inside an if/else inside a hashtable
    # collapses to {} via ConvertTo-Json. @(if ...) preserves array shape.
    args         = @(if ($Args) { $Args })
}

try {
    $payload | ConvertTo-Json -Compress:$false | Set-Content -Path $record -Encoding UTF8
} catch {
    Write-Warning "claude-shim.ps1: failed to write $record"
}

# ---------- hand off ----------
try {
    & $realClaude @Args
    $exit = $LASTEXITCODE
} finally {
    if (Test-Path $record) {
        Remove-Item $record -Force -ErrorAction SilentlyContinue
    }
}

exit $exit
