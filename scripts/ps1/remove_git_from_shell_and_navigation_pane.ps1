$ErrorActionPreference = "Stop"

$DisplayName = "Git"
$Clsid = "{F35D1C88-345C-4ED7-A6C8-5A69E3C15942}"

$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

# Remove the Desktop namespace attachment first, then the CLSID definition.
# Removing the CLSID also removes the pinned navigation-pane entry.
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

# Restart Explorer so it reloads the Desktop and navigation-pane namespaces.
Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force
Start-Process explorer.exe

Write-Host ""
Write-Host "$DisplayName Desktop and navigation-pane entries removed successfully."
Write-Host "Removed CLSID: $Clsid"
Write-Host "The D:\Git folder and Git for Windows installation were not modified."
