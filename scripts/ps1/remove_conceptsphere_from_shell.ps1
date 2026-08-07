# Remove the ConceptSphere Shell namespace entry from the Windows account
# that owns the current Explorer session.
#
# IMPORTANT: Run this script normally. Do not use "Run as administrator".
# Compatible with Windows PowerShell 5.1 and PowerShell 7.

$ErrorActionPreference = "Stop"

$DisplayName = "ConceptSphere"
$KnownClsids = @(
    "{64E4961B-5B61-4A42-B70C-EE1FBA7E8426}",
    "{1B726C4E-133C-40DF-90F4-B195B5AB9406}"
)

$KnownTargetFragments = @(
    "D:\Dropbox\Private\ConceptSphere",
    "D:\ShellNamespaceTargets\ConceptSphere",
    "ConceptSphereNamespaceTarget"
)

$CurrentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
$CurrentSessionId = $CurrentProcess.SessionId
$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentSid = $CurrentIdentity.User.Value

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$DesktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
$BackupDirectory = Join-Path $DesktopPath "ConceptSphereShellRemoval_$Timestamp"
$LogPath = Join-Path $BackupDirectory "removal.log"

New-Item -Path $BackupDirectory -ItemType Directory -Force | Out-Null

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    Write-Host $Line
    Add-Content -Path $LogPath -Value $Line -Encoding UTF8
}

function Wait-BeforeExit {
    Write-Host ""
    Write-Host "Press Enter to close this window."
    [void](Read-Host)
}

function Get-ExplorerOwnerSidForCurrentSession {
    try {
        $ExplorerProcesses = @(
            Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                Where-Object { $_.SessionId -eq $CurrentSessionId }
        )

        foreach ($ExplorerProcess in $ExplorerProcesses) {
            $OwnerResult = $ExplorerProcess.GetOwnerSid()
            if ($OwnerResult.ReturnValue -eq 0 -and $OwnerResult.Sid) {
                return [string]$OwnerResult.Sid
            }
        }
    }
    catch {
        Write-Status "Could not determine the Explorer owner SID: $($_.Exception.Message)"
    }

    return $null
}

function Get-DefaultValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        return $null
    }

    try {
        return [string](Get-Item -Path $Path -ErrorAction Stop).GetValue("")
    }
    catch {
        return $null
    }
}

function Get-PropertyValueSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -Path $Path)) {
        return $null
    }

    try {
        return [string](Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Test-ConceptSphereText {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if ($Value -match "(?i)ConceptSphere") {
        return $true
    }

    foreach ($Fragment in $KnownTargetFragments) {
        if ($Value.IndexOf($Fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Get-CurrentUserNamespaceRoots {
    $Roots = New-Object System.Collections.Generic.List[string]

    $DesktopExplorerRoot =
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop"

    if (Test-Path -Path $DesktopExplorerRoot) {
        foreach ($Child in @(Get-ChildItem -Path $DesktopExplorerRoot -ErrorAction SilentlyContinue)) {
            if ($Child.PSChildName -like "NameSpace*") {
                $Roots.Add($Child.PSPath)
            }
        }
    }

    $FixedRoots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\DelegateFolders"
    )

    foreach ($Root in $FixedRoots) {
        if (Test-Path -Path $Root) {
            $Roots.Add($Root)
        }
    }

    return @($Roots | Sort-Object -Unique)
}

function Get-ClassEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Clsid
    )

    $ClassRoots = @(
        "HKCU:\Software\Classes\CLSID",
        "HKCU:\Software\Classes\WOW6432Node\CLSID"
    )

    $Evidence = New-Object System.Collections.Generic.List[string]

    foreach ($Root in $ClassRoots) {
        $ClassPath = Join-Path $Root $Clsid
        if (-not (Test-Path -Path $ClassPath)) {
            continue
        }

        $Values = @(
            (Get-DefaultValue -Path $ClassPath),
            (Get-PropertyValueSafe -Path $ClassPath -Name "LocalizedString"),
            (Get-PropertyValueSafe -Path $ClassPath -Name "InfoTip"),
            (Get-DefaultValue -Path (Join-Path $ClassPath "DefaultIcon")),
            (Get-PropertyValueSafe `
                -Path (Join-Path $ClassPath "Instance\InitPropertyBag") `
                -Name "TargetFolderPath")
        )

        foreach ($Value in $Values) {
            if (-not [string]::IsNullOrWhiteSpace($Value)) {
                $Evidence.Add($Value)
            }
        }
    }

    return @($Evidence)
}

function Find-ConceptSphereClsids {
    $Found = @{}

    foreach ($Clsid in $KnownClsids) {
        $Found[$Clsid] = $true
    }

    foreach ($NamespaceRoot in @(Get-CurrentUserNamespaceRoots)) {
        Write-Status "Checking namespace root: $NamespaceRoot"

        foreach ($NamespaceKey in @(Get-ChildItem -Path $NamespaceRoot -ErrorAction SilentlyContinue)) {
            $Clsid = [string]$NamespaceKey.PSChildName
            if ($Clsid -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
                continue
            }

            $Matches = Test-ConceptSphereText -Value (Get-DefaultValue -Path $NamespaceKey.PSPath)

            if (-not $Matches) {
                foreach ($Evidence in @(Get-ClassEvidence -Clsid $Clsid)) {
                    if (Test-ConceptSphereText -Value $Evidence) {
                        $Matches = $true
                        break
                    }
                }
            }

            if ($Matches) {
                $Found[$Clsid] = $true
            }
        }
    }

    return @($Found.Keys | Sort-Object -Unique)
}

function Export-RegistryKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PowerShellPath,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if (-not (Test-Path -Path $PowerShellPath)) {
        return
    }

    $NativePath = $PowerShellPath
    $NativePath = $NativePath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_CURRENT_USER\\', 'HKCU\'
    $NativePath = $NativePath -replace '^HKCU:\\', 'HKCU\'

    $Destination = Join-Path $BackupDirectory $FileName
    & reg.exe export $NativePath $Destination /y *> $null

    if ($LASTEXITCODE -eq 0) {
        Write-Status "Backed up: $NativePath"
    }
    else {
        Write-Status "Backup skipped for: $NativePath"
    }
}

function Remove-RegistryKeyVisible {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BackupName
    )

    if (-not (Test-Path -Path $Path)) {
        Write-Status "Not present: $Path"
        return $false
    }

    Export-RegistryKey -PowerShellPath $Path -FileName $BackupName
    Write-Status "Removing: $Path"
    Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop

    if (Test-Path -Path $Path) {
        throw "The registry key still exists after removal: $Path"
    }

    Write-Status "Removed: $Path"
    return $true
}

function Remove-HideDesktopIconValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Clsid
    )

    $Roots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"
    )

    foreach ($Root in $Roots) {
        if (-not (Test-Path -Path $Root)) {
            continue
        }

        $Value = Get-PropertyValueSafe -Path $Root -Name $Clsid
        if ($null -ne $Value) {
            Write-Status "Removing desktop visibility value: $Root -> $Clsid"
            Remove-ItemProperty -Path $Root -Name $Clsid -Force -ErrorAction Stop
        }
    }
}

function Remove-ConceptSphereJunction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        Write-Status "Junction not present: $Path"
        return
    }

    $Item = Get-Item -Path $Path -Force
    $IsReparsePoint = (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)

    if (-not $IsReparsePoint) {
        Write-Status "Not deleting ordinary folder: $Path"
        return
    }

    Write-Status "Removing junction: $Path"
    & $env:ComSpec /d /c "rmdir `"$Path`""

    if ($LASTEXITCODE -ne 0 -or (Test-Path -Path $Path)) {
        throw "Failed to remove the junction: $Path"
    }

    Write-Status "Removed junction: $Path"
}

function Restart-ExplorerForCurrentSession {
    Write-Status "Restarting Explorer in session $CurrentSessionId."

    $ExplorerProcesses = @(
        Get-Process -Name explorer -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $CurrentSessionId }
    )

    foreach ($ExplorerProcess in $ExplorerProcesses) {
        Stop-Process -Id $ExplorerProcess.Id -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 800
    Start-Process explorer.exe
    Start-Sleep -Seconds 2

    try {
        if (-not ("ConceptSphereShellRefresh.NativeMethods" -as [type])) {
            Add-Type -TypeDefinition @"
namespace ConceptSphereShellRefresh {
    using System;
    using System.Runtime.InteropServices;

    public static class NativeMethods {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(
            uint eventId,
            uint flags,
            IntPtr item1,
            IntPtr item2
        );
    }
}
"@
        }

        [ConceptSphereShellRefresh.NativeMethods]::SHChangeNotify(
            0x08000000,
            0,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        )
    }
    catch {
        Write-Status "Explorer refresh notification warning: $($_.Exception.Message)"
    }
}

try {
    Write-Status "ConceptSphere Shell namespace remover started."
    Write-Status "Windows identity: $($CurrentIdentity.Name)"
    Write-Status "Current SID: $CurrentSid"
    Write-Status "Current session: $CurrentSessionId"
    Write-Status "Run this script normally, not as administrator."

    $ExplorerOwnerSid = Get-ExplorerOwnerSidForCurrentSession
    if ($ExplorerOwnerSid) {
        Write-Status "Explorer owner SID: $ExplorerOwnerSid"

        if ($ExplorerOwnerSid -ne $CurrentSid) {
            throw (
                "This PowerShell window belongs to a different account than Explorer. " +
                "Close it and run the script normally without using Run as administrator."
            )
        }
    }

    Write-Status "Searching the current user's Shell namespace registrations."
    $Clsids = @(Find-ConceptSphereClsids)
    Write-Status "CLSID candidates: $($Clsids -join ', ')"

    $NamespaceRoots = @(Get-CurrentUserNamespaceRoots)
    $ClassRoots = @(
        "HKCU:\Software\Classes\CLSID",
        "HKCU:\Software\Classes\WOW6432Node\CLSID"
    )

    $RemovedCount = 0
    $BackupIndex = 0

    foreach ($Clsid in $Clsids) {
        Write-Status "Processing CLSID: $Clsid"

        foreach ($NamespaceRoot in $NamespaceRoots) {
            $BackupIndex++
            if (Remove-RegistryKeyVisible `
                -Path (Join-Path $NamespaceRoot $Clsid) `
                -BackupName ("namespace_{0:D3}.reg" -f $BackupIndex)) {
                $RemovedCount++
            }
        }

        foreach ($ClassRoot in $ClassRoots) {
            $BackupIndex++
            if (Remove-RegistryKeyVisible `
                -Path (Join-Path $ClassRoot $Clsid) `
                -BackupName ("class_{0:D3}.reg" -f $BackupIndex)) {
                $RemovedCount++
            }
        }

        Remove-HideDesktopIconValues -Clsid $Clsid
    }

    Remove-ConceptSphereJunction -Path "D:\ShellNamespaceTargets\ConceptSphere"
    Remove-ConceptSphereJunction -Path "D:\ShellNamespaceTargets\ConceptSphereNamespaceTarget"

    $AliasRoot = "D:\ShellNamespaceTargets"
    if (Test-Path -Path $AliasRoot -PathType Container) {
        $RemainingItems = @(Get-ChildItem -Path $AliasRoot -Force)
        if ($RemainingItems.Count -eq 0) {
            Write-Status "Removing empty alias directory: $AliasRoot"
            Remove-Item -Path $AliasRoot -Force
        }
    }

    Restart-ExplorerForCurrentSession

    $Remaining = New-Object System.Collections.Generic.List[string]
    foreach ($Clsid in $Clsids) {
        foreach ($Root in ($NamespaceRoots + $ClassRoots)) {
            $Path = Join-Path $Root $Clsid
            if (Test-Path -Path $Path) {
                $Remaining.Add($Path)
            }
        }
    }

    if ($Remaining.Count -gt 0) {
        foreach ($Path in $Remaining) {
            Write-Status "Still present: $Path"
        }
        throw "One or more ConceptSphere registry keys still exist."
    }

    Write-Status "Removal completed successfully."
    Write-Status "Registry keys removed: $RemovedCount"
    Write-Status "Backup and log folder: $BackupDirectory"
    Write-Status "The real Dropbox ConceptSphere folder was not modified."

    Write-Host ""
    Write-Host "Open the Shell Desktop to verify:"
    Write-Host "  explorer.exe shell:desktop"
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log file: $LogPath"
    Add-Content -Path $LogPath -Value "ERROR: $($_.Exception.ToString())" -Encoding UTF8
}
finally {
    Wait-BeforeExit
}
