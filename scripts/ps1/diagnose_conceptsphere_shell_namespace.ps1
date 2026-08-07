# Capture the state of the ConceptSphere namespace, target, icon, and old aliases.
# This script makes no changes.

$ErrorActionPreference = "Continue"

$Clsid = "{6C4A7D0B-2B31-4A65-9F7E-53A2E9D1C842}"
$TargetFolder = "D:\Dropbox\Private\ConceptSphere\commands_and_scripts"
$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"
$PropertyBagPath = "$ClsidPath\Instance\InitPropertyBag"

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputPath = Join-Path $env:USERPROFILE "Desktop\ConceptSphereShellDiagnosis_$Timestamp.txt"

$Lines = New-Object System.Collections.Generic.List[string]
function Add-Line([string]$Text) {
    $Lines.Add($Text)
    Write-Host $Text
}

Add-Line "ConceptSphere Shell diagnosis"
Add-Line "Time: $(Get-Date -Format o)"
Add-Line "User: $env:USERDOMAIN\$env:USERNAME"
Add-Line ""
Add-Line "Target exists: $(Test-Path -Path $TargetFolder -PathType Container)"
Add-Line "Target: $TargetFolder"
Add-Line "CLSID key exists: $(Test-Path -Path $ClsidPath)"
Add-Line "Namespace key exists: $(Test-Path -Path $NamespacePath)"

if (Test-Path -Path $PropertyBagPath) {
    $RegisteredTarget = Get-ItemPropertyValue -Path $PropertyBagPath -Name "TargetFolderPath" -ErrorAction SilentlyContinue
    Add-Line "Registered target: $RegisteredTarget"
    Add-Line "Registered target exists: $(Test-Path -Path $RegisteredTarget -PathType Container)"
}

if (Test-Path -Path "$ClsidPath\DefaultIcon") {
    $IconValue = [string](Get-Item -Path "$ClsidPath\DefaultIcon").GetValue("")
    Add-Line "DefaultIcon registry value: $IconValue"

    $IconPath = $IconValue.Trim()
    if ($IconPath.StartsWith('"')) {
        $ClosingQuote = $IconPath.IndexOf('"', 1)
        if ($ClosingQuote -gt 1) {
            $IconPath = $IconPath.Substring(1, $ClosingQuote - 1)
        }
    }
    elseIf ($IconPath.Contains(',')) {
        $IconPath = $IconPath.Split(',')[0]
    }

    Add-Line "Resolved icon path: $IconPath"
    Add-Line "Icon exists: $(Test-Path -Path $IconPath -PathType Leaf)"
}

Add-Line ""
Add-Line "Dropbox processes:"
$DropboxProcesses = @(Get-Process -Name Dropbox -ErrorAction SilentlyContinue)
if ($DropboxProcesses.Count -eq 0) {
    Add-Line "  None"
}
else {
    foreach ($Process in $DropboxProcesses) {
        Add-Line "  PID=$($Process.Id), Started=$($Process.StartTime)"
    }
}

Add-Line ""
Add-Line "Old alias paths:"
foreach ($AliasPath in @(
    "D:\ShellNamespaceTargets\ConceptSphere",
    "D:\ShellNamespaceTargets\ConceptSphereCommandsAndScripts",
    "D:\ShellNamespaceTargets\ConceptSphereNamespaceTarget"
)) {
    if (-not (Test-Path -Path $AliasPath)) {
        Add-Line "  Missing: $AliasPath"
        continue
    }

    $Item = Get-Item -Path $AliasPath -Force
    Add-Line "  Present: $AliasPath"
    Add-Line "    LinkType: $($Item.LinkType)"
    Add-Line "    Target: $($Item.Target -join ', ')"
    Add-Line "    Attributes: $($Item.Attributes)"
}

$Lines | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host ""
Write-Host "Diagnosis saved to: $OutputPath"
