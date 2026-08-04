$ErrorActionPreference = "Stop"

$DisplayName = "ConceptSphere"
$ActualTarget = "D:\Dropbox\Private\ConceptSphere"
$AliasRoot = "D:\ShellNamespaceTargets"
$AliasTarget = Join-Path $AliasRoot $DisplayName
$Clsid = "{1B726C4E-133C-40DF-90F4-B195B5AB9406}"

if (-not (Test-Path -Path $ActualTarget -PathType Container)) {
    throw "The ConceptSphere folder does not exist: $ActualTarget"
}

$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"
$PropertyBagPath = "$ClsidPath\Instance\InitPropertyBag"

# Create a neutral file-system path outside the Dropbox sync root.
# This avoids Explorer inheriting Dropbox's storage-provider display identity.
New-Item -Path $AliasRoot -ItemType Directory -Force | Out-Null

if (Test-Path -Path $AliasTarget) {
    $ExistingAlias = Get-Item -Path $AliasTarget -Force

    $ExistingTargets = @($ExistingAlias.Target) |
        ForEach-Object { [string]$_ }

    $PointsToConceptSphere = $ExistingAlias.LinkType -eq "Junction" -and
        ($ExistingTargets -contains $ActualTarget)

    if (-not $PointsToConceptSphere) {
        throw (
            "The alias path already exists but is not the expected junction:`r`n" +
            "  $AliasTarget`r`n" +
            "Remove or rename it manually, then run this script again."
        )
    }
}
else {
    New-Item `
        -Path $AliasTarget `
        -ItemType Junction `
        -Target $ActualTarget | Out-Null
}

# Reuse the existing ConceptSphere CLSID. Do not touch Dropbox's CLSID.
New-Item -Path $ClsidPath -Force | Out-Null
Set-Item -Path $ClsidPath -Value $DisplayName

# Explicit Shell display-name override.
New-ItemProperty `
    -Path $ClsidPath `
    -Name "LocalizedString" `
    -PropertyType String `
    -Value $DisplayName `
    -Force | Out-Null

New-ItemProperty `
    -Path $ClsidPath `
    -Name "InfoTip" `
    -PropertyType String `
    -Value $ActualTarget `
    -Force | Out-Null

New-Item -Path $PropertyBagPath -Force | Out-Null

# Point the Shell folder at the neutral junction rather than directly into Dropbox.
New-ItemProperty `
    -Path $PropertyBagPath `
    -Name "TargetFolderPath" `
    -PropertyType ExpandString `
    -Value $AliasTarget `
    -Force | Out-Null

# Provide explicit item-name properties as an additional display-name override.
New-ItemProperty `
    -Path $PropertyBagPath `
    -Name "System.ItemName" `
    -PropertyType String `
    -Value $DisplayName `
    -Force | Out-Null

New-ItemProperty `
    -Path $PropertyBagPath `
    -Name "System.ItemNameDisplay" `
    -PropertyType String `
    -Value $DisplayName `
    -Force | Out-Null

New-Item -Path $NamespacePath -Force | Out-Null
Set-Item -Path $NamespacePath -Value $DisplayName

# Reload the Desktop namespace.
Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force
Start-Process explorer.exe

Start-Sleep -Seconds 2

# Report Explorer's current display name for this CLSID.
$Shell = New-Object -ComObject Shell.Application
$ShellFolder = $Shell.Namespace("shell:::$Clsid")
$ReportedName = $null

if ($null -ne $ShellFolder -and $null -ne $ShellFolder.Self) {
    $ReportedName = [string]$ShellFolder.Self.Name
}

Write-Host ""
Write-Host "ConceptSphere Shell entry repaired."
Write-Host "Display name requested: $DisplayName"
Write-Host "Explorer reports:       $ReportedName"
Write-Host "Shell target:           $AliasTarget"
Write-Host "Actual folder:          $ActualTarget"
Write-Host ""
Write-Host "Open it directly with:"
Write-Host "  explorer.exe `"shell:::$Clsid`""
