# Install a stable ConceptSphere item in explorer.exe shell:desktop.
# Run as the same Windows user who owns the Explorer session. Do not elevate.

$ErrorActionPreference = "Stop"

$DisplayName = "ConceptSphere"
$ActualTarget = "D:\Dropbox\Private\ConceptSphere\scripts"
$Clsid = "{24D2F991-D1D6-43E3-8390-90E415BCA92E}"

# Previous custom ConceptSphere CLSIDs. They are removed only after the new
# entry has been opened successfully and Explorer reports the correct name.
$OldClsids = @(
    "{6C4A7D0B-2B31-4A65-9F7E-53A2E9D1C842}",
    "{8B7E1C94-893E-4A27-B4D0-0DE7443C7B47}",
    "{64E4961B-5B61-4A42-B70C-EE1FBA7E8426}",
    "{1B726C4E-133C-40DF-90F4-B195B5AB9406}"
)

if (-not (Test-Path -Path $ActualTarget -PathType Container)) {
    throw "The ConceptSphere target does not exist: $ActualTarget"
}

# Keep both the junction and icon outside Dropbox so Explorer does not inherit
# Dropbox's namespace identity or depend on Dropbox to load the icon.
$StableAssetDirectory = Join-Path $env:LOCALAPPDATA "ConceptSphere\Shell"
$ShellTarget = Join-Path $StableAssetDirectory $DisplayName
$StableIconPath = Join-Path $StableAssetDirectory "ConceptSphere.ico"

New-Item `
    -Path $StableAssetDirectory `
    -ItemType Directory `
    -Force | Out-Null

function ConvertTo-NormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Value = $Path

    if ($Value.StartsWith("\??\")) {
        $Value = $Value.Substring(4)
    }

    return [IO.Path]::GetFullPath($Value).TrimEnd("\")
}

function Remove-JunctionSafely {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $Item = Get-Item -LiteralPath $Path -Force
    $IsReparsePoint =
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0

    if (-not $IsReparsePoint) {
        throw "Refusing to remove a normal directory: $Path"
    }

    & cmd.exe /d /c "rmdir `"$Path`""

    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $Path)) {
        throw "Failed to remove the existing junction: $Path"
    }
}

# Recreate the junction on every install. This avoids retaining a stale link
# from one of the earlier ConceptSphere scripts.
if (Test-Path -LiteralPath $ShellTarget) {
    $ExistingItem = Get-Item -LiteralPath $ShellTarget -Force
    $IsReparsePoint =
        ($ExistingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0

    if (-not $IsReparsePoint) {
        throw (
            "The shell target path exists as a normal directory:`r`n" +
            "  $ShellTarget`r`n" +
            "Rename or remove it manually, then rerun this installer."
        )
    }

    Remove-JunctionSafely -Path $ShellTarget
}

New-Item `
    -Path $ShellTarget `
    -ItemType Junction `
    -Target $ActualTarget | Out-Null

$JunctionItem = Get-Item -LiteralPath $ShellTarget -Force
$JunctionTargets = @($JunctionItem.Target)

if ($JunctionTargets.Count -eq 0) {
    throw "The ConceptSphere junction was created without a readable target."
}

$ExpectedTarget = ConvertTo-NormalizedPath -Path $ActualTarget
$ResolvedTarget = ConvertTo-NormalizedPath -Path ([string]$JunctionTargets[0])

if ($ResolvedTarget -ne $ExpectedTarget) {
    throw (
        "Junction verification failed.`r`n" +
        "Expected: $ExpectedTarget`r`n" +
        "Actual:   $ResolvedTarget"
    )
}

# Copy the icon to a stable local path.
$PackagedIcon = Join-Path $PSScriptRoot "ConceptSphere.ico"
$TargetIcon = Join-Path $ActualTarget "ConceptSphere.ico"

if (Test-Path -Path $PackagedIcon -PathType Leaf) {
    Copy-Item -Path $PackagedIcon -Destination $StableIconPath -Force
}
elseif (Test-Path -Path $TargetIcon -PathType Leaf) {
    Copy-Item -Path $TargetIcon -Destination $StableIconPath -Force
}

$IconRegistryValue = "$env:SystemRoot\System32\imageres.dll,-3"

if (Test-Path -Path $StableIconPath -PathType Leaf) {
    $IconRegistryValue = '"' + $StableIconPath + '",0'
}

$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

# Build the new entry from scratch using the same file-system-folder structure
# as the working Git namespace registration.
Remove-Item -Path $NamespacePath -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $ClsidPath -Recurse -Force -ErrorAction SilentlyContinue

New-Item -Path $ClsidPath -Force | Out-Null
Set-Item -Path $ClsidPath -Value $DisplayName

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
    -Value 66 `
    -Force | Out-Null

New-Item -Path "$ClsidPath\DefaultIcon" -Force | Out-Null
Set-Item -Path "$ClsidPath\DefaultIcon" -Value $IconRegistryValue

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

$PropertyBagPath = "$ClsidPath\Instance\InitPropertyBag"
New-Item -Path $PropertyBagPath -Force | Out-Null

New-ItemProperty `
    -Path $PropertyBagPath `
    -Name "Attributes" `
    -PropertyType DWord `
    -Value 0x11 `
    -Force | Out-Null

# Explorer sees the neutral local path named ConceptSphere instead of a folder
# directly inside Dropbox.
New-ItemProperty `
    -Path $PropertyBagPath `
    -Name "TargetFolderPath" `
    -PropertyType ExpandString `
    -Value $ShellTarget `
    -Force | Out-Null

New-Item -Path "$ClsidPath\ShellFolder" -Force | Out-Null

New-ItemProperty `
    -Path "$ClsidPath\ShellFolder" `
    -Name "FolderValueFlags" `
    -PropertyType DWord `
    -Value 0x28 `
    -Force | Out-Null

New-ItemProperty `
    -Path "$ClsidPath\ShellFolder" `
    -Name "Attributes" `
    -PropertyType DWord `
    -Value 0xF080004D `
    -Force | Out-Null

New-Item -Path $NamespacePath -Force | Out-Null
Set-Item -Path $NamespacePath -Value $DisplayName

# Verify the registry registration before asking Explorer to load it.
$RegisteredTarget = Get-ItemPropertyValue `
    -Path $PropertyBagPath `
    -Name "TargetFolderPath"

$RegisteredNamespaceName = (Get-Item -Path $NamespacePath).GetValue("")

if ($RegisteredTarget -ne $ShellTarget) {
    throw "Target verification failed. Registered value: $RegisteredTarget"
}

if ($RegisteredNamespaceName -ne $DisplayName) {
    throw "Name verification failed. Registered value: $RegisteredNamespaceName"
}

# Restart Explorer and verify the actual display name returned by the Shell.
Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force

Start-Process explorer.exe
Start-Sleep -Seconds 3

$Shell = New-Object -ComObject Shell.Application
$ShellFolder = $Shell.Namespace("shell:::$Clsid")

if ($null -eq $ShellFolder -or $null -eq $ShellFolder.Self) {
    Remove-Item -Path $NamespacePath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $ClsidPath -Recurse -Force -ErrorAction SilentlyContinue
    throw "Explorer could not open the new ConceptSphere namespace entry."
}

$ExplorerName = [string]$ShellFolder.Self.Name

if ($ExplorerName -ne $DisplayName) {
    Remove-Item -Path $NamespacePath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $ClsidPath -Recurse -Force -ErrorAction SilentlyContinue

    Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Stop-Process -Force
    Start-Process explorer.exe

    throw (
        "Explorer reported the wrong display name.`r`n" +
        "Expected: $DisplayName`r`n" +
        "Actual:   $ExplorerName`r`n" +
        "The previous namespace registrations were left intact."
    )
}

# The replacement is proven to work. Remove the duplicated Dropbox entry and
# all other obsolete custom ConceptSphere registrations.
foreach ($OldClsid in $OldClsids) {
    $OldClsidPath = "HKCU:\Software\Classes\CLSID\$OldClsid"
    $OldNamespacePath =
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$OldClsid"

    Remove-Item `
        -Path $OldNamespacePath `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -Path $OldClsidPath `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

# Remove obsolete junction names from earlier versions, but never delete normal
# directories.
$OldAliasPaths = @(
    "D:\ShellNamespaceTargets\ConceptSphere",
    "D:\ShellNamespaceTargets\ConceptSphereCommandsAndScripts",
    "D:\ShellNamespaceTargets\ConceptSphereNamespaceTarget"
)

foreach ($OldAliasPath in $OldAliasPaths) {
    if (-not (Test-Path -LiteralPath $OldAliasPath)) {
        continue
    }

    $OldAliasItem = Get-Item -LiteralPath $OldAliasPath -Force
    $IsOldReparsePoint =
        ($OldAliasItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0

    if ($IsOldReparsePoint) {
        & cmd.exe /d /c "rmdir `"$OldAliasPath`""
    }
}

Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force
Start-Process explorer.exe

Write-Host ""
Write-Host "ConceptSphere Shell namespace installed successfully."
Write-Host "Display name:  $ExplorerName"
Write-Host "CLSID:         $Clsid"
Write-Host "Shell target:  $ShellTarget"
Write-Host "Actual target: $ActualTarget"
Write-Host "Icon:          $IconRegistryValue"
Write-Host ""
Write-Host "Open with: explorer.exe shell:desktop"
