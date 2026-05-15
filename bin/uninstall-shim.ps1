# uninstall-shim.ps1 - remove the claude function block from $PROFILE files.

[CmdletBinding()]
param(
    # Override for tests. Defaults to the user's $HOME.
    [string]$ProfileRoot = $HOME
)

$ErrorActionPreference = 'Continue'

$markerBegin = '# >>> instance-restorer-5000 >>>'
$markerEnd   = '# <<< instance-restorer-5000 <<<'

$profilePaths = @(
    (Join-Path $ProfileRoot 'Documents\WindowsPowerShell\profile.ps1'),
    (Join-Path $ProfileRoot 'Documents\PowerShell\profile.ps1')
)

foreach ($p in $profilePaths) {
    if (-not (Test-Path $p)) {
        Write-Host "  $p : not present, skipping"
        continue
    }
    $content = Get-Content -Raw -Path $p
    if (-not ($content -match [regex]::Escape($markerBegin))) {
        Write-Host "  $p : no marker, skipping"
        continue
    }
    $pattern = "(?ms)\r?\n?$([regex]::Escape($markerBegin)).*?$([regex]::Escape($markerEnd))\r?\n?"
    $new = [regex]::Replace($content, $pattern, '')
    Set-Content -Path $p -Value $new.TrimEnd() -Encoding UTF8
    Write-Host "  $p : removed block"
}

Write-Host ""
Write-Host "Done. Open a new PowerShell window - 'claude' will resolve to the real binary again."
