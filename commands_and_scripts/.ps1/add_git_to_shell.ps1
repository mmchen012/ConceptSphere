$Target = "D:\Git"
$Clsid = "{F35D1C88-345C-4ED7-A6C8-5A69E3C15942}"

if (-not (Test-Path -Path $Target -PathType Container)) {
    throw "The target folder does not exist: $Target"
}

$ClsidPath = "HKCU:\Software\Classes\CLSID\$Clsid"
$NamespacePath =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$Clsid"

# Create the Git Shell folder.
New-Item -Path $ClsidPath -Force | Out-Null
Set-Item -Path $ClsidPath -Value "Git"

# Do not add a separate Git entry to the navigation pane.
New-ItemProperty `
    -Path $ClsidPath `
    -Name "System.IsPinnedToNameSpaceTree" `
    -PropertyType DWord `
    -Value 0 `
    -Force | Out-Null

# Used for Shell namespace ordering where Explorer honors it.
New-ItemProperty `
    -Path $ClsidPath `
    -Name "SortOrderIndex" `
    -PropertyType DWord `
    -Value 67 `
    -Force | Out-Null

# Prefer the Git for Windows icon when available.
$GitIcon = Join-Path $env:ProgramFiles `
    "Git\mingw64\share\git\git-for-windows.ico"

if (-not (Test-Path -Path $GitIcon)) {
    $GitIcon = "$env:SystemRoot\System32\imageres.dll,-3"
}

New-Item -Path "$ClsidPath\DefaultIcon" -Force | Out-Null
Set-Item -Path "$ClsidPath\DefaultIcon" -Value $GitIcon

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

New-Item -Path "$ClsidPath\Instance\InitPropertyBag" -Force | Out-Null

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

# Attach the Shell folder directly beneath the Desktop namespace.
New-Item -Path $NamespacePath -Force | Out-Null
Set-Item -Path $NamespacePath -Value "Git"

# Restart Explorer so it reloads the namespace.
Stop-Process -Name explorer -Force
Start-Process explorer.exe