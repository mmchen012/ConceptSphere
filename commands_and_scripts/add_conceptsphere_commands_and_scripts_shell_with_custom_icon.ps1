$ErrorActionPreference = "Stop"

$DisplayName = "ConceptSphere"
$ActualTarget = "D:\Dropbox\Private\ConceptSphere\commands_and_scripts"

# Neutral junction to avoid inheriting Dropbox's display identity.
$AliasRoot = "D:\ShellNamespaceTargets"
$Target = Join-Path $AliasRoot "ConceptSphereCommandsAndScripts"

# Fresh CLSID for the corrected ConceptSphere shell entry.
$Clsid = "{8B7E1C94-893E-4A27-B4D0-0DE7443C7B47}"

# Older custom ConceptSphere CLSIDs to clean up after the new entry is created.
$OldClsids = @(
    "{1B726C4E-133C-40DF-90F4-B195B5AB9406}",
    "{64E4961B-5B61-4A42-B70C-EE1FBA7E8426}"
)

# If present, use a custom icon placed in the target folder.
# Recommended path:
#   D:\Dropbox\Private\ConceptSphere\commands_and_scripts\ConceptSphere.ico
$CustomIconPath = Join-Path $ActualTarget "ConceptSphere.ico"

if (-not (Test-Path -Path $ActualTarget -PathType Container)) {
    throw "The target folder does not exist: $ActualTarget"
}

# ---------------------------------------------------------------------------
# 1. Prepare the neutral junction before touching the registry.
# ---------------------------------------------------------------------------

New-Item `
    -Path $AliasRoot `
    -ItemType Directory `
    -Force | Out-Null

if (-not (Test-Path -Path $Target)) {
    New-Item `
        -Path $Target `
        -ItemType Junction `
        -Target $ActualTarget | Out-Null
}

if (-not (Test-Path -Path $Target -PathType Container)) {
    throw "The neutral ConceptSphere target could not be created: $Target"
}

# ---------------------------------------------------------------------------
# 2. Create the shell entry using the same structure as the working Git script.
# ---------------------------------------------------------------------------

$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

Remove-Item `
    -Path $NamespacePath `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue

Remove-Item `
    -Path $ClsidPath `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue

New-Item -Path $ClsidPath -Force | Out-Null
Set-Item -Path $ClsidPath -Value $DisplayName

New-ItemProperty `
    -Path $ClsidPath `
    -Name "LocalizedString" `
    -PropertyType String `
    -Value $DisplayName `
    -Force | Out-Null

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

$ConceptSphereIcon = "$env:SystemRoot\System32\imageres.dll,-3"

if (Test-Path -Path $CustomIconPath -PathType Leaf) {
    $ConceptSphereIcon = $CustomIconPath
}

New-Item -Path "$ClsidPath\DefaultIcon" -Force | Out-Null
Set-Item `
    -Path "$ClsidPath\DefaultIcon" `
    -Value $ConceptSphereIcon

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

New-Item `
    -Path "$ClsidPath\Instance\InitPropertyBag" `
    -Force | Out-Null

New-ItemProperty `
    -Path "$ClsidPath\Instance\InitPropertyBag" `
    -Name "Attributes" `
    -PropertyType DWord `
    -Value 0x11 `
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

# ---------------------------------------------------------------------------
# 3. Verify, then clean up the older custom ConceptSphere registrations.
# ---------------------------------------------------------------------------

$RegisteredTarget = Get-ItemPropertyValue `
    -Path "$ClsidPath\Instance\InitPropertyBag" `
    -Name "TargetFolderPath"

$RegisteredName = (Get-Item -Path $NamespacePath).GetValue("")

if ($RegisteredTarget -ne $Target) {
    throw "Target verification failed. Registered: $RegisteredTarget"
}

if ($RegisteredName -ne $DisplayName) {
    throw "Name verification failed. Registered: $RegisteredName"
}

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

Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force
Start-Process explorer.exe

Write-Host ""
Write-Host "ConceptSphere shell entry created successfully."
Write-Host "Name:          $DisplayName"
Write-Host "CLSID:         $Clsid"
Write-Host "Shell target:  $Target"
Write-Host "Actual target: $ActualTarget"
Write-Host "Icon path:     $ConceptSphereIcon"
Write-Host ""
Write-Host "Open the Shell Desktop with:"
Write-Host "  explorer.exe shell:desktop"
