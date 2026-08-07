#Requires -Version 5.1

param(
    [string]$BackupPath
)

$ErrorActionPreference = "Stop"

$backupDirectory = Join-Path $env:USERPROFILE "Documents\ConceptSphere\RegistryBackups"

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $latestBackup = Get-ChildItem `
        -Path $backupDirectory `
        -Filter "TraditionalChineseImeHotKey-*.reg" `
        -File `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestBackup) {
        throw "No Traditional Chinese IME registry backup was found in $backupDirectory."
    }

    $BackupPath = $latestBackup.FullName
}

$resolvedBackupPath = (Resolve-Path -Path $BackupPath -ErrorAction Stop).Path

Write-Host "Restoring:"
Write-Host "  $resolvedBackupPath"
Write-Host ""

& reg.exe import $resolvedBackupPath
if ($LASTEXITCODE -ne 0) {
    throw "Unable to restore the registry backup. reg.exe exited with code $LASTEXITCODE."
}

Write-Host ""
Write-Host "The original Traditional Chinese IME hotkey settings were restored."
Write-Host "Sign out of Windows and sign back in for the IME to reload them."
