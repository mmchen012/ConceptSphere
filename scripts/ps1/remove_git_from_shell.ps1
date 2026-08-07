$ErrorActionPreference = "Stop"

$DisplayName = "Git"
$Clsid = "{F35D1C88-345C-4ED7-A6C8-5A69E3C15942}"

$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

# Remove the Desktop namespace attachment first, then its CLSID definition.
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

# Restart Explorer so it immediately reloads the Desktop namespace.
Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force
Start-Process explorer.exe

Write-Host ""
Write-Host "$DisplayName Shell entry removed successfully."
Write-Host "Removed CLSID: $Clsid"
Write-Host "The D:\Git folder and Git for Windows installation were not modified."
