<#
.SYNOPSIS
    Hide every notification-area icon except MiniTray's (Windows 11).

.DESCRIPTION
    Windows 11 keeps one subkey per tray icon under

        HKCU:\Control Panel\NotifyIconSettings\<id>

    with ExecutablePath naming the owner and IsPromoted deciding whether the
    icon sits on the taskbar (1) or in the hidden overflow flyout (0). This
    sets IsPromoted=0 for everything except the executables in -KeepExe, and 1
    for those.

    Nothing is uninstalled or blocked -- the icons still exist, they just move
    into the overflow. That is the point: fewer stops between the taskbar and
    the one icon worth reaching.

    The original IsPromoted values are written to a backup JSON before the
    first change, and -Restore puts them all back.

    Windows 10 stored this in the opaque IconStreams blob, which cannot be
    edited safely; on a machine without NotifyIconSettings this script reports
    that and changes nothing.

.PARAMETER KeepExe
    Executable names (leaf, not path) to keep promoted. Case-insensitive.

.PARAMETER Restore
    Put every recorded IsPromoted value back and stop.

.PARAMETER ListOnly
    Report what would change and change nothing.

.PARAMETER RestartExplorer
    Restart Explorer so the change shows immediately. Off by default -- it
    tears down and rebuilds the shell, which is disruptive mid-install.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Set-TrayIcons.ps1 -ListOnly
    powershell -NoProfile -ExecutionPolicy Bypass -File Set-TrayIcons.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File Set-TrayIcons.ps1 -Restore

.NOTES
    Runs as the current user: HKCU, no elevation needed. When the installer
    calls it, that is the account that elevated the installer.
#>
[CmdletBinding()]
param(
    [string[]]$KeepExe = @('MiniTray.exe'),

    [switch]$Restore,
    [switch]$ListOnly,
    [switch]$RestartExplorer,

    # Overwrite an existing backup with the CURRENT state. Rarely what you
    # want -- after one run the current state is already the tidied one.
    [switch]$ForceBackup,

    [string]$BackupPath = (Join-Path $env:APPDATA 'ConceptSphere\tray-icons-backup.json'),
    [string]$LogPath    = (Join-Path ([IO.Path]::GetTempPath()) 'ConceptSphere-tray-icons.log')
)

$ErrorActionPreference = 'Stop'
# No Set-StrictMode: this runs unattended during an install.

$regRoot = 'HKCU:\Control Panel\NotifyIconSettings'

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Get-IconEntries {
    $entries = @()
    foreach ($key in (Get-ChildItem -LiteralPath $regRoot -ErrorAction SilentlyContinue)) {
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }

        $exe = $null
        if ($props.PSObject.Properties.Name -contains 'ExecutablePath') { $exe = $props.ExecutablePath }

        $promoted = $null
        if ($props.PSObject.Properties.Name -contains 'IsPromoted') { $promoted = [int]$props.IsPromoted }

        # Plain assignment rather than an if-expression inside the literal:
        # 5.1 is the host the installer uses, and this is not the place to find
        # out which statement forms its parser accepts in a hashtable.
        $leaf = ''
        if ($exe) { $leaf = Split-Path -Leaf $exe }

        $entries += [pscustomobject]@{
            Id       = $key.PSChildName
            PSPath   = $key.PSPath
            Exe      = $exe
            Leaf     = $leaf
            Promoted = $promoted
        }
    }
    return $entries
}

$mode = 'tidy'
if ($Restore)      { $mode = 'restore' }
elseif ($ListOnly) { $mode = 'list' }
Write-Log "--- tray icons ($mode) ---"

if (-not (Test-Path -LiteralPath $regRoot)) {
    Write-Log "No $regRoot on this machine -- Windows 10 or earlier keeps tray"
    Write-Log "visibility in the opaque IconStreams blob, which is not safe to edit."
    Write-Log "Nothing changed."
    exit 0
}

# --- restore ------------------------------------------------------------------
if ($Restore) {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        Write-Log "No backup at $BackupPath -- nothing to restore."
        exit 0
    }

    $saved = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    $done = 0
    foreach ($item in @($saved)) {
        $path = Join-Path $regRoot $item.Id
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            if ($null -eq $item.Promoted) {
                Remove-ItemProperty -LiteralPath $path -Name IsPromoted -ErrorAction SilentlyContinue
            } else {
                Set-ItemProperty -LiteralPath $path -Name IsPromoted -Value ([int]$item.Promoted) -Type DWord
            }
            $done++
        }
        catch { Write-Log "  could not restore $($item.Leaf): $($_.Exception.Message)" }
    }
    Write-Log "Restored $done of $(@($saved).Count) recorded icons."
    if ($RestartExplorer) {
        Write-Log 'Restarting Explorer...'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log 'Takes effect after Explorer restarts (log off and on, or -RestartExplorer).'
    }
    exit 0
}

# --- survey -------------------------------------------------------------------
$entries = @(Get-IconEntries)
if ($entries.Count -eq 0) {
    Write-Log 'No icon entries found. Windows records one the first time an icon appears.'
    exit 0
}

$keep  = @($entries | Where-Object { $_.Leaf -and ($KeepExe -contains $_.Leaf) })
$other = @($entries | Where-Object { -not ($_.Leaf -and ($KeepExe -contains $_.Leaf)) })

Write-Log "$($entries.Count) icon entries; keeping $($KeepExe -join ', ') promoted."

if ($keep.Count -eq 0) {
    Write-Log "NOTE: none of $($KeepExe -join ', ') has an entry yet."
    Write-Log "Windows only records an icon once it has been shown, so run this again"
    Write-Log "after MiniTray has been running -- otherwise its icon lands in the"
    Write-Log "overflow with everything else. The Start menu shortcut re-runs it."
}

# --- backup -------------------------------------------------------------------
if (-not $ListOnly) {
    if ((Test-Path -LiteralPath $BackupPath) -and -not $ForceBackup) {
        Write-Log "Backup already exists, left as it is: $BackupPath"
    } else {
        New-Item -ItemType Directory -Path (Split-Path $BackupPath) -Force | Out-Null
        $entries |
            Select-Object Id, Leaf, Exe, Promoted |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath $BackupPath -Encoding UTF8
        Write-Log "Saved current state to $BackupPath"
    }
}

# --- apply --------------------------------------------------------------------
$changed = 0
foreach ($e in $entries) {
    $want = 0
    if ($e.Leaf -and ($KeepExe -contains $e.Leaf)) { $want = 1 }

    $name = "(no ExecutablePath, id $($e.Id))"
    if ($e.Leaf) { $name = $e.Leaf }

    if ($e.Promoted -eq $want) { continue }

    if ($ListOnly) {
        Write-Log ("WOULD SET IsPromoted={0}: {1}" -f $want, $name)
        continue
    }

    try {
        Set-ItemProperty -LiteralPath $e.PSPath -Name IsPromoted -Value $want -Type DWord
        Write-Log ("IsPromoted={0}: {1}" -f $want, $name)
        $changed++
    }
    catch { Write-Log "  could not change $name : $($_.Exception.Message)" }
}

if ($ListOnly) {
    Write-Log 'List only, nothing changed.'
    exit 0
}

Write-Log "Changed $changed of $($entries.Count) entries."

if ($RestartExplorer) {
    Write-Log 'Restarting Explorer...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
} else {
    Write-Log 'Takes effect after Explorer restarts (log off and on, or -RestartExplorer).'
}

exit 0
