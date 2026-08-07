#Requires -Version 5.1

$ErrorActionPreference = "Stop"

$registryPath = "HKCU:\Control Panel\Input Method\Hot Keys\00000070"
$nativeRegistryPath = "HKEY_CURRENT_USER\Control Panel\Input Method\Hot Keys\00000070"
$backupDirectory = Join-Path $env:USERPROFILE "Documents\ConceptSphere\RegistryBackups"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $backupDirectory "TraditionalChineseImeHotKey-$timestamp.reg"

function Get-BinaryValueText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $value = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction Stop
        return [BitConverter]::ToString([byte[]]$value)
    }
    catch {
        return "<not present>"
    }
}

New-Item -Path $backupDirectory -ItemType Directory -Force | Out-Null

Write-Host "Traditional Chinese IME Ctrl+Space hotkey"
Write-Host "Registry key: $nativeRegistryPath"
Write-Host ""
Write-Host "Current values:"
Write-Host "  Key Modifiers: $(Get-BinaryValueText -Path $registryPath -Name 'Key Modifiers')"
Write-Host "  Virtual Key:   $(Get-BinaryValueText -Path $registryPath -Name 'Virtual Key')"
Write-Host ""

# Back up the existing registry key before changing it.
& reg.exe export $nativeRegistryPath $backupPath /y | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to back up the registry key. reg.exe exited with code $LASTEXITCODE."
}

New-Item -Path $registryPath -Force | Out-Null

# Disable Traditional Chinese IME/non-IME toggle:
#   Key Modifiers: 02-C0-00-00 (Ctrl) -> 00-C0-00-00 (unassigned)
#   Virtual Key:   20-00-00-00 (Space) -> FF-00-00-00 (invalid/unassigned)
New-ItemProperty `
    -Path $registryPath `
    -Name "Key Modifiers" `
    -PropertyType Binary `
    -Value ([byte[]](0x00, 0xC0, 0x00, 0x00)) `
    -Force | Out-Null

New-ItemProperty `
    -Path $registryPath `
    -Name "Virtual Key" `
    -PropertyType Binary `
    -Value ([byte[]](0xFF, 0x00, 0x00, 0x00)) `
    -Force | Out-Null

Write-Host "New values:"
Write-Host "  Key Modifiers: $(Get-BinaryValueText -Path $registryPath -Name 'Key Modifiers')"
Write-Host "  Virtual Key:   $(Get-BinaryValueText -Path $registryPath -Name 'Virtual Key')"
Write-Host ""
Write-Host "Backup saved to:"
Write-Host "  $backupPath"
Write-Host ""
Write-Host "Sign out of Windows and sign back in for the IME to reload this setting."
Write-Host "Do not reopen and apply the legacy 'Input language hot keys' dialog afterward,"
Write-Host "because Windows may recreate the Ctrl+Space assignment."
