# restore.ps1 - instance-restorer-5000 reopener.
#
# Reads the state dir, prompts the user, and relaunches each surviving
# Claude session in its original host (Windows Terminal pwsh tab, WSL tab,
# VS Code workspace, etc.). Records with no session_id are listed but
# skipped (we can't `--resume` without one).
#
# Triggered manually for now; Phase 4 will wire to Task Scheduler at logon.

[CmdletBinding()]
param(
    [string]$StateDir = (Join-Path $env:USERPROFILE '.claude-restorer\sessions'),
    [string]$LogFile  = (Join-Path $env:USERPROFILE '.claude-restorer\restore.log'),
    # Print the launch commands without executing or deleting records.
    [switch]$DryRun,
    # Skip the GUI prompt (for scripted use / testing).
    [switch]$NoPrompt,
    # Pause between launches so wt has time to settle (ms).
    [int]$LaunchDelayMs = 400
)

$ErrorActionPreference = 'Continue'

# ---------- helpers ----------
function Write-RestoreLog {
    param([string]$Message)
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "$stamp  $Message"
    if (-not (Test-Path (Split-Path -Parent $LogFile))) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
    }
    $line | Add-Content -Path $LogFile -Encoding UTF8
    if ($DryRun -or $env:RESTORE_VERBOSE) { Write-Host $line }
}

function Convert-WslPathToWindows {
    param([string]$WslPath, [string]$Distro)
    # /home/user/foo on Ubuntu -> \\wsl$\Ubuntu\home\user\foo
    if ($WslPath -like '/mnt/?/*') {
        # /mnt/c/Dev/foo -> C:\Dev\foo (don't go through \\wsl$\)
        $drive = $WslPath.Substring(5,1).ToUpper()
        $rest  = $WslPath.Substring(6) -replace '/', '\'
        return "${drive}:$rest"
    }
    return "\\wsl`$\$Distro" + ($WslPath -replace '/', '\')
}

# Build the wt.exe argument list for one tab.
function Get-WtArgsForRecord {
    param($Record)

    $sid = $Record.session_id
    switch -Wildcard ($Record.host) {
        'wt' {
            return @(
                '-w', '0',
                'new-tab',
                '--startingDirectory', $Record.cwd,
                '--', 'powershell.exe', '-NoExit',
                '-Command', "claude --resume $sid"
            )
        }
        'wsl:*' {
            $distro = $Record.host -replace '^wsl:', ''
            $winCwd = Convert-WslPathToWindows -WslPath $Record.cwd -Distro $distro
            # We must invoke wsl.exe explicitly: relying on `bash` would
            # resolve to Git Bash on Windows PATH, NOT the WSL distro.
            # `wsl --cd` sets the working dir on the Linux side; `bash -lc`
            # loads .bashrc so the `claude` alias is in scope; trailing
            # `exec bash` keeps the tab open after claude exits.
            $bashCmd = "claude --resume $sid; exec bash"
            return @(
                '-w', '0',
                'new-tab',
                '-p', $distro,
                '--startingDirectory', $winCwd,
                '--', 'wsl.exe', '-d', $distro, '--cd', $Record.cwd,
                '--', 'bash', '-lc', $bashCmd
            )
        }
        default {
            # 'unknown' or anything we don't have a wt path for - fall back
            # to a generic pwsh tab in WT at the cwd, leaving the user to
            # decide what to do.
            return @(
                '-w', '0',
                'new-tab',
                '--startingDirectory', $Record.cwd,
                '--', 'powershell.exe', '-NoExit',
                '-Command', "Write-Host 'instance-restorer-5000: please run: claude --resume $sid'"
            )
        }
    }
}

# Editor records (vscode/cursor) can't auto-run a terminal command, so
# we open the folder and accumulate the resume commands here; we display
# all of them at the end so the user can copy individually.
$script:editorCommands = @()

function Invoke-Restore {
    param($Record)

    switch -Wildcard ($Record.host) {
        { $_ -eq 'vscode' -or $_ -eq 'cursor' } {
            $cmd = "claude --resume $($Record.session_id)"
            $exe = if ($Record.host -eq 'vscode') { 'code' } else { 'cursor' }
            Write-RestoreLog "$($Record.host): opening $($Record.cwd) ; resume cmd=$cmd"
            $script:editorCommands += [pscustomobject]@{
                Editor = $Record.host
                Cwd    = $Record.cwd
                Cmd    = $cmd
            }
            if (-not $DryRun) {
                Start-Process -FilePath $exe -ArgumentList @($Record.cwd) -ErrorAction SilentlyContinue
            }
        }
        default {
            # wt, wsl:*, unknown - all routed through Windows Terminal.
            $wtArgs = Get-WtArgsForRecord -Record $Record
            Write-RestoreLog "wt: $($wtArgs -join ' ')"
            if (-not $DryRun) {
                Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------- collect records ----------
if (-not (Test-Path $StateDir)) {
    Write-Host "instance-restorer-5000: nothing to restore (state dir missing)."
    return
}

$records = @()
$skippedNoSid = @()
foreach ($file in Get-ChildItem -Path $StateDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try {
        $r = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
    } catch {
        Write-RestoreLog "skipping corrupt $($file.Name): $($_.Exception.Message)"
        continue
    }
    # Attach the source path so we can delete after launching.
    $r | Add-Member -NotePropertyName _file -NotePropertyValue $file.FullName -Force
    if (-not $r.session_id) {
        $skippedNoSid += $r
    } else {
        $records += $r
    }
}

if ($records.Count -eq 0 -and $skippedNoSid.Count -eq 0) {
    Write-Host "instance-restorer-5000: nothing to restore."
    return
}

# ---------- prompt ----------
$summary = "Restore $($records.Count) Claude session(s)?`n`n"
foreach ($r in $records) {
    $sidShort = if ($r.session_id) { $r.session_id.Substring(0, 8) } else { 'no-sid' }
    $summary += ("  {0,-12} {1,-50}  [{2}]`n" -f $r.host, $r.cwd, $sidShort)
}
if ($skippedNoSid.Count -gt 0) {
    $summary += "`n($($skippedNoSid.Count) record(s) without session_id will be skipped:`n"
    foreach ($r in $skippedNoSid) {
        $summary += "  {0,-12} {1}`n" -f $r.host, $r.cwd
    }
    $summary += "Use ``claude --resume`` in those folders to pick from the session list.)"
}

$shouldProceed = $false
if ($NoPrompt -or $DryRun) {
    $shouldProceed = $true
    if ($DryRun) { Write-Host "$summary`n[DryRun: would proceed without prompting]" }
} else {
    if ($records.Count -eq 0) {
        Write-Host $summary
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    $btn = [System.Windows.Forms.MessageBox]::Show(
        $summary,
        'instance-restorer-5000',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    $shouldProceed = ($btn -eq [System.Windows.Forms.DialogResult]::Yes)
}

if (-not $shouldProceed) {
    Write-RestoreLog "user declined restore of $($records.Count) record(s)"
    Write-Host "Restore declined. State records left in place; rerun restore.ps1 anytime."
    return
}

# ---------- launch + cleanup ----------
$launched = 0
foreach ($r in $records) {
    Invoke-Restore -Record $r
    $launched++
    if (-not $DryRun) {
        Remove-Item -Path $r._file -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds $LaunchDelayMs
    }
}

Write-RestoreLog "restored $launched session(s) (skipped $($skippedNoSid.Count) without session_id)"
Write-Host "Restored $launched session(s)."
if ($skippedNoSid.Count -gt 0) {
    Write-Host "$($skippedNoSid.Count) record(s) without session_id were left in place; consider running restore again after the daemon backfills them."
}

# Surface editor (vscode/cursor) commands the user must run by hand.
if ($script:editorCommands.Count -gt 0) {
    $msg = "These editor sessions opened, but $($script:editorCommands.Count) need a manual ``claude --resume`` (paste in each editor's terminal):`n`n"
    foreach ($e in $script:editorCommands) {
        $msg += "$($e.Editor)  $($e.Cwd)`n  $($e.Cmd)`n`n"
    }
    Write-Host $msg
    if (-not $DryRun -and -not $NoPrompt) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $msg,
            'instance-restorer-5000 - editor sessions',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
}
