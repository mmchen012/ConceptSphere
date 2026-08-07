# Read-only diagnostic for the current ConceptSphere Shell namespace.
$ErrorActionPreference = "Continue"

$ExpectedClsid = "{24D2F991-D1D6-43E3-8390-90E415BCA92E}"
$ExpectedTarget = "D:\Dropbox\Private\ConceptSphere\commands_and_scripts"
$ExpectedShellTarget = Join-Path $env:LOCALAPPDATA "ConceptSphere\Shell\ConceptSphere"
$ExpectedIcon = Join-Path $env:LOCALAPPDATA "ConceptSphere\Shell\ConceptSphere.ico"

$ClsidPath = "HKCU:\Software\Classes\CLSID\$ExpectedClsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$ExpectedClsid"
$PropertyBagPath = "$ClsidPath\Instance\InitPropertyBag"

Write-Host "ConceptSphere Shell namespace diagnostic"
Write-Host "======================================="
Write-Host "Real target exists:  $(Test-Path -Path $ExpectedTarget -PathType Container)"
Write-Host "Shell target exists: $(Test-Path -LiteralPath $ExpectedShellTarget)"
Write-Host "Icon exists:         $(Test-Path -Path $ExpectedIcon -PathType Leaf)"
Write-Host "CLSID key exists:    $(Test-Path -Path $ClsidPath)"
Write-Host "Namespace exists:    $(Test-Path -Path $NamespacePath)"

if (Test-Path -LiteralPath $ExpectedShellTarget) {
    $Item = Get-Item -LiteralPath $ExpectedShellTarget -Force
    Write-Host "Shell target type:   $($Item.LinkType)"
    Write-Host "Junction target:     $($Item.Target)"
}

if (Test-Path -Path $PropertyBagPath) {
    $RegisteredTarget = Get-ItemPropertyValue `
        -Path $PropertyBagPath `
        -Name "TargetFolderPath" `
        -ErrorAction SilentlyContinue

    Write-Host "Registered target:   $RegisteredTarget"
}

if (Test-Path -Path $ClsidPath) {
    $RegisteredName = (Get-Item -Path $ClsidPath).GetValue("")
    Write-Host "Registered name:     $RegisteredName"
}

try {
    $Shell = New-Object -ComObject Shell.Application
    $Folder = $Shell.Namespace("shell:::$ExpectedClsid")

    if ($null -ne $Folder -and $null -ne $Folder.Self) {
        Write-Host "Explorer name:       $($Folder.Self.Name)"
        Write-Host "Explorer path:       $($Folder.Self.Path)"
    }
    else {
        Write-Host "Explorer lookup:     Failed"
    }
}
catch {
    Write-Host "Explorer lookup:     $($_.Exception.Message)"
}
