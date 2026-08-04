$ErrorActionPreference = "Stop"

$Clsid = "{1B726C4E-133C-40DF-90F4-B195B5AB9406}"
$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupDirectory = Join-Path `
    ([Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)) `
    "ConceptSphereShellBackup_$Timestamp"

New-Item -Path $BackupDirectory -ItemType Directory -Force | Out-Null

function Backup-RegistryKey {
    param(
        [Parameter(Mandatory)]
        [string]$NativeRegistryPath,

        [Parameter(Mandatory)]
        [string]$PowerShellRegistryPath,

        [Parameter(Mandatory)]
        [string]$DestinationFile
    )

    if (Test-Path -Path $PowerShellRegistryPath) {
        & reg.exe export $NativeRegistryPath $DestinationFile /y | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to back up registry key: $NativeRegistryPath"
        }
    }
}

function Register-DesktopShellFolder {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$Clsid,

        [Parameter(Mandatory)]
        [uint32]$SortOrderIndex,

        [Parameter(Mandatory)]
        [string]$Icon
    )

    if (-not (Test-Path -Path $Target -PathType Container)) {
        throw "The target folder does not exist: $Target"
    }

    $ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
    $NamespacePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

    New-Item -Path $ClsidPath -Force | Out-Null
    Set-Item -Path $ClsidPath -Value $Name

    New-ItemProperty `
        -Path $ClsidPath `
        -Name "System.IsPinnedToNameSpaceTree" `
        -PropertyType DWord `
        -Value 0 `
        -Force | Out-Null

    New-ItemProperty `
        -Path $ClsidPath `
        -Name "SortOrderIndex" `
        -PropertyType DWord `
        -Value $SortOrderIndex `
        -Force | Out-Null

    New-Item -Path "$ClsidPath\DefaultIcon" -Force | Out-Null
    Set-Item -Path "$ClsidPath\DefaultIcon" -Value $Icon

    New-Item -Path "$ClsidPath\InProcServer32" -Force | Out-Null
    Set-Item `
        -Path "$ClsidPath\InProcServer32" `
        -Value "$env:SystemRoot\System32\shell32.dll"

    New-Item -Path "$ClsidPath\Instance" -Force | Out-Null
    New-ItemProperty `
        -Path "$ClsidPath\Instance" `
        -Name "CLSID" `
        -PropertyType String `
        -Value "{0E5AAE11-A475-4C5B-AB00-C66DE400274E}" `
        -Force | Out-Null

    New-Item -Path "$ClsidPath\Instance\InitPropertyBag" -Force | Out-Null

    New-ItemProperty `
        -Path "$ClsidPath\Instance\InitPropertyBag" `
        -Name "Attributes" `
        -PropertyType DWord `
        -Value ([uint32]0x11) `
        -Force | Out-Null

    New-ItemProperty `
        -Path "$ClsidPath\Instance\InitPropertyBag" `
        -Name "TargetFolderPath" `
        -PropertyType ExpandString `
        -Value $Target `
        -Force | Out-Null

    New-Item -Path "$ClsidPath\ShellFolder" -Force | Out-Null

    New-ItemProperty `
        -Path "$ClsidPath\ShellFolder" `
        -Name "FolderValueFlags" `
        -PropertyType DWord `
        -Value ([uint32]0x28) `
        -Force | Out-Null

    New-ItemProperty `
        -Path "$ClsidPath\ShellFolder" `
        -Name "Attributes" `
        -PropertyType DWord `
        -Value ([uint32]0xF080004D) `
        -Force | Out-Null

    New-Item -Path $NamespacePath -Force | Out-Null
    Set-Item -Path $NamespacePath -Value $Name
}

function Restart-WindowsExplorer {
    Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Stop-Process -Force
    Start-Process explorer.exe
}

Backup-RegistryKey `
    -NativeRegistryPath "HKCU\Software\Classes\CLSID\$Clsid" `
    -PowerShellRegistryPath $ClsidPath `
    -DestinationFile (Join-Path $BackupDirectory "conceptsphere_clsid.reg")

Backup-RegistryKey `
    -NativeRegistryPath "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid" `
    -PowerShellRegistryPath $NamespacePath `
    -DestinationFile (Join-Path $BackupDirectory "conceptsphere_desktop_namespace.reg")

Remove-Item -Path $NamespacePath -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $ClsidPath -Recurse -Force -ErrorAction SilentlyContinue

Restart-WindowsExplorer

Write-Host ""
Write-Host "The ConceptSphere Shell namespace entry has been removed."
Write-Host "Registry backup: $BackupDirectory"
