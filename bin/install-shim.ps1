# install-shim.ps1 - wire the PowerShell shim into $PROFILE.
#
# Adds a `claude` function (PowerShell aliases can't take args, so a
# function is required) that invokes claude-shim.ps1 with the original
# arguments. Idempotent via marker comments.
#
# Installs into BOTH Windows PowerShell 5.1 and PowerShell 7 profiles
# (whichever exist as paths) - they're separate files. Run from any
# version; you don't need to launch both.

[CmdletBinding()]
param(
    # Override for tests. Defaults to the user's $HOME.
    [string]$ProfileRoot = $HOME
)

$ErrorActionPreference = 'Stop'

$shim = Join-Path $PSScriptRoot 'claude-shim.ps1'
if (-not (Test-Path $shim)) {
    throw "install-shim.ps1: cannot find $shim"
}

$markerBegin = '# >>> instance-restorer-5000 >>>'
$markerEnd   = '# <<< instance-restorer-5000 <<<'

# Both Windows PowerShell 5.1 and PowerShell 7 profile locations
$profilePaths = @(
    (Join-Path $ProfileRoot 'Documents\WindowsPowerShell\profile.ps1'),
    (Join-Path $ProfileRoot 'Documents\PowerShell\profile.ps1')
)

function Install-Block {
    param([string]$Path, [string]$Shim)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Force -Path $Path | Out-Null
    }

    $content = Get-Content -Raw -Path $Path -ErrorAction SilentlyContinue
    if (-not $content) { $content = '' }

    if ($content -match [regex]::Escape($markerBegin)) {
        # Strip existing block.
        $pattern = "(?ms)\r?\n?$([regex]::Escape($markerBegin)).*?$([regex]::Escape($markerEnd))\r?\n?"
        $content = [regex]::Replace($content, $pattern, '')
        Write-Host "  removed previous block from $Path"
    }

    # PowerShell single-quoted strings: escape internal ' by doubling.
    $shimEscaped = $Shim -replace "'", "''"
    $block = @"

$markerBegin
# Routes ``claude`` through the launch recorder.
function claude { & '$shimEscaped' @args }
$markerEnd
"@

    Set-Content -Path $Path -Value ($content.TrimEnd() + $block) -Encoding UTF8
    Write-Host "  installed function into $Path"
}

foreach ($p in $profilePaths) {
    Install-Block -Path $p -Shim $shim
}

Write-Host ""
Write-Host "Done. Open a NEW PowerShell window and run:"
Write-Host "  Get-Command claude"
Write-Host "It should report  CommandType: Function"
Write-Host ""
Write-Host "If your execution policy blocks the profile, run once (as admin if needed):"
Write-Host "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
