$ErrorActionPreference = "Stop"

$DisplayName = "ConceptSphere"
$ActualTarget = "D:\Dropbox\Private\ConceptSphere"

# Use a new neutral junction path and a fresh CLSID so Explorer does not reuse
# the cached identity of the earlier malformed entry.
$AliasRoot = "D:\ShellNamespaceTargets"
$Target = Join-Path $AliasRoot "ConceptSphereNamespaceTarget"
$Clsid = "{64E4961B-5B61-4A42-B70C-EE1FBA7E8426}"

# The CLSID used by the earlier failed ConceptSphere scripts.
$OldClsid = "{1B726C4E-133C-40DF-90F4-B195B5AB9406}"

if (-not (Test-Path -Path $ActualTarget -PathType Container)) {
    throw "The target folder does not exist: $ActualTarget"
}

# ---------------------------------------------------------------------------
# 1. Prepare the target before changing any registry keys.
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
# 2. Build a fresh Shell entry using the working Git script's structure.
#    The stale ConceptSphere registration is not removed until this succeeds.
# ---------------------------------------------------------------------------

$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

# Remove only a partial registration for this new CLSID, if a previous run
# stopped unexpectedly.
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

# Create the ConceptSphere Shell folder.
New-Item -Path $ClsidPath -Force | Out-Null
Set-Item -Path $ClsidPath -Value $DisplayName

# Force an explicit user-facing name.
New-ItemProperty `
    -Path $ClsidPath `
    -Name "LocalizedString" `
    -PropertyType String `
    -Value $DisplayName `
    -Force | Out-Null

# Do not add a separate entry to the navigation pane.
New-ItemProperty `
    -Path $ClsidPath `
    -Name "System.IsPinnedToNameSpaceTree" `
    -PropertyType DWord `
    -Value 0 `
    -Force | Out-Null

# Place ConceptSphere immediately before Git where Explorer honors this value.
New-ItemProperty `
    -Path $ClsidPath `
    -Name "SortOrderIndex" `
    -PropertyType DWord `
    -Value 66 `
    -Force | Out-Null

# Use the standard Windows folder icon.
$ConceptSphereIcon = "$env:SystemRoot\System32\imageres.dll,-3"

New-Item -Path "$ClsidPath\DefaultIcon" -Force | Out-Null
Set-Item `
    -Path "$ClsidPath\DefaultIcon" `
    -Value $ConceptSphereIcon

# Use Windows' built-in file-system folder implementation.
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

# Match the working Git script exactly for the Shell folder attributes.
New-ItemProperty `
    -Path "$ClsidPath\ShellFolder" `
    -Name "Attributes" `
    -PropertyType DWord `
    -Value 0xF080004D `
    -Force | Out-Null

# Attach the new Shell folder beneath Desktop.
New-Item -Path $NamespacePath -Force | Out-Null
Set-Item -Path $NamespacePath -Value $DisplayName

# ---------------------------------------------------------------------------
# 3. Verify the complete new registration before removing the stale one.
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

# ---------------------------------------------------------------------------
# 4. The new entry is complete. Remove only the old custom ConceptSphere CLSID.
# ---------------------------------------------------------------------------

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

# Restart Explorer only after the new registration has been verified.
Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force
Start-Process explorer.exe

Write-Host ""
Write-Host "ConceptSphere Shell entry created successfully."
Write-Host "Name:          $DisplayName"
Write-Host "New CLSID:     $Clsid"
Write-Host "Shell target:  $Target"
Write-Host "Actual target: $ActualTarget"
Write-Host ""
Write-Host "Open the Shell Desktop with:"
Write-Host "  explorer.exe shell:desktop"
Write-Host ""
Write-Host "Open ConceptSphere directly with:"
Write-Host "  explorer.exe `"shell:::$Clsid`""
