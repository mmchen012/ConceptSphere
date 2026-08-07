# Remove all custom ConceptSphere Shell namespace entries.
# Run as the same Windows user who owns the Explorer session. Do not elevate.

$ErrorActionPreference = "Stop"

$Clsids = @(
    "{24D2F991-D1D6-43E3-8390-90E415BCA92E}",
    "{6C4A7D0B-2B31-4A65-9F7E-53A2E9D1C842}",
    "{8B7E1C94-893E-4A27-B4D0-0DE7443C7B47}",
    "{64E4961B-5B61-4A42-B70C-EE1FBA7E8426}",
    "{1B726C4E-133C-40DF-90F4-B195B5AB9406}"
)

foreach ($Clsid in $Clsids) {
    $ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
    $NamespacePath =
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

    Remove-Item -Path $NamespacePath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $ClsidPath -Recurse -Force -ErrorAction SilentlyContinue
}

$JunctionPaths = @(
    (Join-Path $env:LOCALAPPDATA "ConceptSphere\Shell\ConceptSphere"),
    "D:\ShellNamespaceTargets\ConceptSphere",
    "D:\ShellNamespaceTargets\ConceptSphereCommandsAndScripts",
    "D:\ShellNamespaceTargets\ConceptSphereNamespaceTarget"
)

foreach ($JunctionPath in $JunctionPaths) {
    if (-not (Test-Path -LiteralPath $JunctionPath)) {
        continue
    }

    $Item = Get-Item -LiteralPath $JunctionPath -Force
    $IsReparsePoint =
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0

    if ($IsReparsePoint) {
        & cmd.exe /d /c "rmdir `"$JunctionPath`""
    }
    else {
        Write-Warning "Not removing a normal directory: $JunctionPath"
    }
}

$StableAssetDirectory = Join-Path $env:LOCALAPPDATA "ConceptSphere\Shell"
$StableIconPath = Join-Path $StableAssetDirectory "ConceptSphere.ico"

Remove-Item `
    -Path $StableIconPath `
    -Force `
    -ErrorAction SilentlyContinue

if (Test-Path -Path $StableAssetDirectory) {
    $RemainingItems = @(
        Get-ChildItem -Path $StableAssetDirectory -Force -ErrorAction SilentlyContinue
    )

    if ($RemainingItems.Count -eq 0) {
        Remove-Item -Path $StableAssetDirectory -Force -ErrorAction SilentlyContinue
    }
}

Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Stop-Process -Force
Start-Process explorer.exe

Write-Host ""
Write-Host "All custom ConceptSphere Shell namespace entries were removed."
