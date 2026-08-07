<#
.SYNOPSIS
    Build ConceptSphere-Setup-2.0.exe locally with makensis.

.DESCRIPTION
    Checks every input up front, stages the payload to a temp folder outside
    Dropbox, rebuilds the .nvda-addon from nvda_addon\globalPlugins, runs
    makensis, and optionally signs the result.

    Building locally is also what keeps the SmartScreen "unrecognized app"
    prompt away: that check only fires on files carrying a Mark of the Web, and
    a file you compiled yourself has never been near the internet.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Sign
    .\build.ps1 -Source "D:\somewhere\else\v2.0" -Sign

.NOTES
    Needs NSIS:  winget install NSIS.NSIS
    Run from the folder holding this script. No elevation required to build;
    -Sign needs the certificate from the one-time setup in your CurrentUser
    store, which does not need elevation either.

    THIS SCRIPT MUST BE AUTHENTICODE-SIGNED to run under an AllSigned
    execution policy. After editing it:
        $c = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
             Where-Object { $_.Subject -eq 'CN=ConceptSphere' } | Select-Object -First 1
        Set-AuthenticodeSignature .\build.ps1 -Certificate $c `
            -HashAlgorithm SHA256 -TimestampServer http://timestamp.digicert.com
#>
[CmdletBinding()]
param(
    # Where the compiled tools and nvda_addon\ live.
    [string]$Source = "D:\Dropbox\Private\ConceptSphere\commands_and_scripts\ahk\v2.0",

    # Scratch folder for the staged payload. Deliberately outside Dropbox:
    # staging deletes and rewrites this on every run, which made Dropbox hold a
    # handle on it and fail the next build with "used by another process".
    [string]$StageDir = (Join-Path $env:TEMP 'ConceptSphere-build'),

    # Skip if you only changed the .nsi and the packaged add-on is current.
    [switch]$SkipAddon,

    # Authenticode-sign the finished installer.
    [switch]$Sign,

    [string]$CertSubject = "CN=ConceptSphere",

    [string]$TimestampServer = "http://timestamp.digicert.com",

    # Override if NSIS is somewhere unusual.
    [string]$MakeNsis
)

$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$payload   = Join-Path $StageDir 'payload'
$addonSrc  = Join-Path $root 'addon'
$outDir    = Join-Path $root 'Output'
$nsi       = Join-Path $root 'ConceptSphereTools.nsi'
$addonName = 'ConceptSphereTools-1.0.0.nvda-addon'

function Say { param([string]$m) Write-Host "  $m" }

# --- locate makensis ---------------------------------------------------------
if (-not $MakeNsis) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
        "$env:ProgramFiles\NSIS\makensis.exe"
    )
    $MakeNsis = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $MakeNsis) {
        $cmd = Get-Command makensis.exe -ErrorAction SilentlyContinue
        if ($cmd) { $MakeNsis = $cmd.Source }
    }
}
if (-not $MakeNsis -or -not (Test-Path $MakeNsis)) {
    throw "makensis.exe not found. Install NSIS (winget install NSIS.NSIS) or pass -MakeNsis."
}

Write-Host "ConceptSphere installer build"
Say "source   : $Source"
Say "staging  : $payload"
Say "makensis : $MakeNsis"

# --- preflight ---------------------------------------------------------------
# Every input is checked here, and ALL failures are reported together. A
# missing File source is an NSIS compile error thrown one line at a time, so
# without this a build with three missing files takes three runs to diagnose.
Write-Host "`nChecking inputs..."
$missing = @()

function Need {
    param([string]$Path, [string]$What)
    if (-not (Test-Path -LiteralPath $Path)) {
        $script:missing += "$What : $Path"
    }
}

Need $nsi                                        "NSIS script"
Need (Join-Path $root 'install\Register-ConceptSphereTask.ps1') "task helper"
Need (Join-Path $root 'install\Remove-ConceptSphereTasks.ps1')  "task helper"

if (-not (Test-Path -LiteralPath $Source)) {
    $missing += "source folder : $Source"
} else {
    foreach ($f in 'MiniTray.exe', 'EnhancedStartMenu.exe', 'ConceptSphereWatchdog.exe',
                   'ConsoleSelectAll.exe', 'DesktopFocus.exe', 'MiniTray.ico',
                   'nvdaControllerClient64.dll') {
        Need (Join-Path $Source $f) "payload file"
    }
    Need (Join-Path $Source 'lib') "lib folder"
}

$plugins = Join-Path $Source 'nvda_addon\globalPlugins'
# Required either way: the .nsi ships the loose .py files alongside the
# packaged add-on, so -SkipAddon still needs this folder.
Need $plugins "plugin folder"
if ($SkipAddon) {
    Need (Join-Path $root $addonName) "prebuilt add-on"
} else {
    Need (Join-Path $addonSrc 'manifest.ini') "add-on manifest"
}

if ($missing.Count) {
    Write-Host ""
    Write-Host "Cannot build -- $($missing.Count) input(s) missing:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "The two task helpers can be recovered from an installed copy:"
    Write-Host "  Copy-Item 'C:\Program Files\ConceptSphere\install\*.ps1' '$root\install'"
    Write-Host "The manifest is inside the packaged add-on, and both are in Dropbox history."
    throw "Preflight failed."
}

# Superseded plugins left in the folder would be repackaged silently, and two
# of them wrap speech.speak -- loading them alongside the merged plugin nests
# the wrappers. Caught here rather than discovered on the machine.
if (-not $SkipAddon) {
    $stale = Get-ChildItem "$plugins\*.py" |
             Where-Object { $_.Name -in 'minitrayQuiet.py','quietFocusAncestry.py','startMenuContextMenuFix.py' }
    if ($stale) {
        Write-Host ""
        Write-Host "Superseded plugins still in $plugins :" -ForegroundColor Yellow
        $stale | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor Yellow }
        throw "These were merged into conceptSphereQuiet.py. Delete them, or pass -SkipAddon to reuse the existing package."
    }
}
Say "all inputs present"

# --- stage payload -----------------------------------------------------------
Write-Host "`nStaging payload..."
if (Test-Path $payload) { Remove-Item $payload -Recurse -Force }
New-Item -ItemType Directory -Path $payload, "$payload\lib", "$payload\nvda" -Force | Out-Null

Copy-Item "$Source\*.exe"                      $payload
Copy-Item "$Source\*.ahk"                      $payload
Copy-Item "$Source\MiniTray.ico"               $payload
Copy-Item "$Source\nvdaControllerClient64.dll" $payload
Copy-Item "$Source\lib\*.ahk"                  "$payload\lib"

$exes = @(Get-ChildItem "$payload\*.exe" | Select-Object -ExpandProperty Name)
Say "exes: $($exes -join ', ')"

# The .nsi seeds this into %APPDATA%\MiniTray without overwriting, so it only
# matters on a machine that has never run MiniTray. Prefer the live settings,
# fall back to the pre-move copy, and write a minimal one rather than failing
# the build -- a missing File source is a compile error, not a warning.
$iniTargets = @(
    "$env:APPDATA\MiniTray\MiniTray.ini"
    "$Source\MiniTray.ini"
    "$Source\MiniTray.ini.migrated"
)
$ini = $iniTargets | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($ini) {
    Copy-Item $ini "$payload\MiniTray.ini"
    Say "seed ini: $ini"
} else {
    Set-Content "$payload\MiniTray.ini" @(
        '[__MiniTray__]'
        'SoundMode=Wav'
        'Speak=0'
        'QuietPlugin=1'
        'ConfirmCloseAll=1'
        'AutoApply=1'
    ) -Encoding UTF8
    Say "seed ini: none found, wrote a minimal default"
}

# --- rebuild the NVDA add-on -------------------------------------------------
if ($SkipAddon) {
    Copy-Item "$root\$addonName" "$payload\nvda"
    Say "add-on: reused existing package"
} else {
    Write-Host "`nPackaging the NVDA add-on..."
    $zipPath = Join-Path $root $addonName
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    # Entry names must use forward slashes and sit at the archive root. Built by
    # hand because Compress-Archive has written backslash separators, which
    # NVDA's zipfile reader treats as part of the filename rather than a folder.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, (Join-Path $addonSrc 'manifest.ini'), 'manifest.ini') | Out-Null
        foreach ($py in Get-ChildItem "$plugins\*.py") {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $py.FullName, "globalPlugins/$($py.Name)") | Out-Null
            Say "  + globalPlugins/$($py.Name)"
        }
    }
    finally { $zip.Dispose() }

    Copy-Item $zipPath "$payload\nvda"
}
Copy-Item "$plugins\*.py" "$payload\nvda"

# --- compile -----------------------------------------------------------------
# The payload location is handed to NSIS as a define. File directives resolve
# at compile time, so the .nsi cannot discover the staging folder by itself.
Write-Host "`nCompiling..."
if ($payload -match '\s') {
    throw "Staging path contains a space, which /D cannot carry through to makensis: $payload`nPass -StageDir with a space-free path."
}
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
& $MakeNsis "/DPAYLOAD=$payload" $nsi
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }

$exe = Join-Path $outDir 'ConceptSphere-Setup-2.0.exe'
if (-not (Test-Path $exe)) { throw "makensis reported success but $exe is not there." }
$size = (Get-Item $exe).Length
Say ("built: {0}  ({1:N0} bytes)" -f $exe, $size)

# --- sign --------------------------------------------------------------------
if ($Sign) {
    Write-Host "`nSigning..."
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object { $_.Subject -eq $CertSubject } | Select-Object -First 1
    if (-not $cert) { throw "No code-signing certificate with subject $CertSubject in CurrentUser\My." }

    $res = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert `
               -HashAlgorithm SHA256 -TimestampServer $TimestampServer
    Say "status: $($res.Status)"
    if ($res.Status -ne 'Valid') { Say "         $($res.StatusMessage)" }
}

Write-Host "`nDone. $exe"

# SIG # Begin signature block
# MIIb8AYJKoZIhvcNAQcCoIIb4TCCG90CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCTtclZ1rbogLo9
# dMp0rSyjUrjZfMMnxsjkeLb8JjNZcaCCFj4wggMAMIIB6KADAgECAhBcf27FFLZ4
# qUCaAUxM7sE7MA0GCSqGSIb3DQEBCwUAMBgxFjAUBgNVBAMMDUNvbmNlcHRTcGhl
# cmUwHhcNMjYwODAzMTE0NDMyWhcNMjcwODAzMTIwNDMyWjAYMRYwFAYDVQQDDA1D
# b25jZXB0U3BoZXJlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAq9bh
# BV+Fw61djUqnI6nc45cAQj3IzoHGWdbgTYFUS/Kliv7ZhNSKP1OTbE0nNdMRFVME
# D+2A4EYVCPRM+6/f0pIqxvVjMuOycmRVF2b6zOJamLKY/olmWdjWkQ6pCoGGzgNL
# GLDKriQMZ9oTvK3uVMAqIKhazm+Zwz9LN/SqNGQPiy4+1zecrDORna+Y3q2cqB3Q
# uqkCTIznazZ1wAsQ22VTTn+fhRxnvKAb/ZgNBrvA2XXrTTe6ivbNnJNiDNDPxNp3
# 56hureEEdsnjZCerEWXQi7i58jSXLOvOqpCkbhXP1JFv6NkvLg0nbyrL7TUNadkC
# Thw8aBsfbgFJg59+EQIDAQABo0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAww
# CgYIKwYBBQUHAwMwHQYDVR0OBBYEFLsG2I5Vp8qT2E+plFEFLY7xhW+5MA0GCSqG
# SIb3DQEBCwUAA4IBAQATDsXeIEnosN++oDAHW18N/k83PPXElz9a0kTGMRY9OgVM
# iuHzvVio/Q4nhgoHb5H7ax66odF7WbedzTp4CCybBTtyB8E4GNnelwHk6fuNyXJT
# Up+ZMxlOIBXIM0uimWoo6+wqlqwcrrUFyOQ4qXdc8h/mYcrLSF0zmMaBjz/SSsHe
# nFpbXMkyq4imGcutpKvCGtUzPJFLAjzocUuisFNzh/sbXtofeGhjBlVWkR0d0Afd
# ksjuh634fvAdiDyXc3lTi+NXzn8NZa4MlSXMiVNQb+98zLQ8bmLV0nsTYUDVxxE7
# W4y/zrNrS3UXXzGLKqFrQ5SjmjlTRGetcEifgh8DMIIFjTCCBHWgAwIBAgIQDpsY
# jvnQLefv21DiCEAYWjANBgkqhkiG9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMG
# A1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQw
# IgYDVQQDExtEaWdpQ2VydCBBc3N1cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAw
# MDAwWhcNMzExMTA5MjM1OTU5WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGln
# aUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhE
# aWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQC/5pBzaN675F1KPDAiMGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57
# G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9o
# k3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFh
# mzTrBcZe7FsavOvJz82sNEBfsXpm7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463J
# T17lNecxy9qTXtyOj4DatpGYQJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFw
# q1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yh
# Tzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU
# 75KSOp493ADkRSWJtppEGSt+wJS00mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LV
# jHAsQWCqsWMYRJUadmJ+9oCw++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJ
# bOUOUlFHdL4mrLZBdd56rF+NP8m800ERElvlEFDrMcXKchYiCd98THU/Y+whX8Qg
# UWtvsauGi0/C1kVfnSD8oR7FwI+isX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IB
# OjCCATYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6
# mK4cD08wHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/
# BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDovL29jc3Au
# ZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4
# oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJv
# b3RDQS5jcmwwEQYDVR0gBAowCDAGBgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBw
# oL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0
# E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtD
# IeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlU
# sLihVo7spNU96LHc/RzY9HdaXFSMb++hUD38dglohJ9vytsgjTVgHAIDyyCwrFig
# DkBjxZgiwbJZ9VVrzyerbHbObyMt9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwY
# w02fc7cBqZ9Xql4o4rmUMIIGtDCCBJygAwIBAgIQDcesVwX/IZkuQEMiDDpJhjAN
# BgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQg
# SW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2Vy
# dCBUcnVzdGVkIFJvb3QgRzQwHhcNMjUwNTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5
# WjBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNV
# BAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hB
# MjU2IDIwMjUgQ0ExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx
# 0wqYQXK+PEbAHKx126NGaHS0URedTa2NDZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz
# 4aH+qbxeLho8I6jY3xL1IusLopuW2qftJYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJ
# gMQB3h2DZ0Mal5kYp77jYMVQXSZH++0trj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQ
# bzIBHYJBYgzWIjk8eDrYhXDEpKk7RdoX0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6
# bNMI1I7Gb5IBZK4ivbVCiZv7PNBYqHEpNVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJ
# RfN20VRS3hpLgIR4hjzL0hpoYGk81coWJ+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU1
# 4lDnki7CcoKCz6eum5A19WZQHkqUJfdkDjHkccpL6uoG8pbF0LJAQQZxst7VvwDD
# jAmSFTUms+wV/FbWBqi7fTJnjq3hj0XbQcd8hjj/q8d6ylgxCZSKi17yVp2NL+cn
# T6Toy+rN+nM8M7LnLqCrO2JP3oW//1sfuZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq
# 1BtmXUqEG1NqzJKS4kOmxkYp2WyODi7vQTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqg
# PrHRVHhGNKlYzyjlroPxul+bgIspzOwbtmsgY1MCAwEAAaOCAV0wggFZMBIGA1Ud
# EwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8G
# A1UdIwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjAT
# BgNVHSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGG
# GGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2Nh
# Y2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYD
# VR0fBDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9
# bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQAXzvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfF
# iBowf0/Dm1wGc/Do7oVMY2mhXZXjDNJQa8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4
# /iEIUBO41P5F448rSYJ59Ib61eoalhnd6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/
# DMm/axFSgoR8n6c3nuZB9BfBwAQYK9FHaoq2e26MHvVY9gCDA/JYsq7pGdogP8HR
# trYfctSLANEBfHU16r3J05qX3kId+ZOczgj5kjatVB+NdADVZKON/gnZruMvNYY2
# o1f4MXRJDMdTSlOLh0HCn2cQLwQCqjFbqrXuvTPSegOOzr4EWj7PtspIHBldNE2K
# 9i697cvaiIo2p61Ed2p8xMJb82Yosn0z4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc
# 3hsXMrS+U0yy+GWqAXam4ToWd2UQ1KYT70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLi
# Ru7hAWE6bTEm4XYRkA6Tl4KSFLFk43esaUeqGkH/wyW4N7OigizwJWeukcyIPbAv
# jSabnf7+Pu0VrFgoiovRDiyx3zEdmcif/sYQsfch28bZeUz2rtY/9TCA6TD8dC3J
# E3rYkrhLULy7Dc90G6e8BlqmyIjlgp2+VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM
# 1pD2T7m3XDCCBu0wggTVoAMCAQICEAqA7xhLjfEFgtHEdqeVdGgwDQYJKoZIhvcN
# AQELBQAwaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEw
# PwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2
# IFNIQTI1NiAyMDI1IENBMTAeFw0yNTA2MDQwMDAwMDBaFw0zNjA5MDMyMzU5NTla
# MGMxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UE
# AxMyRGlnaUNlcnQgU0hBMjU2IFJTQTQwOTYgVGltZXN0YW1wIFJlc3BvbmRlciAy
# MDI1IDEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDQRqwtEsae0Oqu
# YFazK1e6b1H/hnAKAd/KN8wZQjBjMqiZ3xTWcfsLwOvRxUwXcGx8AUjni6bz52fG
# Tfr6PHRNv6T7zsf1Y/E3IU8kgNkeECqVQ+3bzWYesFtkepErvUSbf+EIYLkrLKd6
# qJnuzK8Vcn0DvbDMemQFoxQ2Dsw4vEjoT1FpS54dNApZfKY61HAldytxNM89PZXU
# P/5wWWURK+IfxiOg8W9lKMqzdIo7VA1R0V3Zp3DjjANwqAf4lEkTlCDQ0/fKJLKL
# kzGBTpx6EYevvOi7XOc4zyh1uSqgr6UnbksIcFJqLbkIXIPbcNmA98Oskkkrvt6l
# PAw/p4oDSRZreiwB7x9ykrjS6GS3NR39iTTFS+ENTqW8m6THuOmHHjQNC3zbJ6nJ
# 6SXiLSvw4Smz8U07hqF+8CTXaETkVWz0dVVZw7knh1WZXOLHgDvundrAtuvz0D3T
# +dYaNcwafsVCGZKUhQPL1naFKBy1p6llN3QgshRta6Eq4B40h5avMcpi54wm0i2e
# PZD5pPIssoszQyF4//3DoK2O65Uck5Wggn8O2klETsJ7u8xEehGifgJYi+6I03Uu
# T1j7FnrqVrOzaQoVJOeeStPeldYRNMmSF3voIgMFtNGh86w3ISHNm0IaadCKCkUe
# 2LnwJKa8TIlwCUNVwppwn4D3/Pt5pwIDAQABo4IBlTCCAZEwDAYDVR0TAQH/BAIw
# ADAdBgNVHQ4EFgQU5Dv88jHt/f3X85FxYxlQQ89hjOgwHwYDVR0jBBgwFoAU729T
# SunkBnx6yuKQVvYv1Ensy04wDgYDVR0PAQH/BAQDAgeAMBYGA1UdJQEB/wQMMAoG
# CCsGAQUFBwMIMIGVBggrBgEFBQcBAQSBiDCBhTAkBggrBgEFBQcwAYYYaHR0cDov
# L29jc3AuZGlnaWNlcnQuY29tMF0GCCsGAQUFBzAChlFodHRwOi8vY2FjZXJ0cy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2
# U0hBMjU2MjAyNUNBMS5jcnQwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL2NybDMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5
# NlNIQTI1NjIwMjVDQTEuY3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG
# /WwHATANBgkqhkiG9w0BAQsFAAOCAgEAZSqt8RwnBLmuYEHs0QhEnmNAciH45PYi
# T9s1i6UKtW+FERp8FgXRGQ/YAavXzWjZhY+hIfP2JkQ38U+wtJPBVBajYfrbIYG+
# Dui4I4PCvHpQuPqFgqp1PzC/ZRX4pvP/ciZmUnthfAEP1HShTrY+2DE5qjzvZs7J
# IIgt0GCFD9ktx0LxxtRQ7vllKluHWiKk6FxRPyUPxAAYH2Vy1lNM4kzekd8oEARz
# FAWgeW3az2xejEWLNN4eKGxDJ8WDl/FQUSntbjZ80FU3i54tpx5F/0Kr15zW/mJA
# xZMVBrTE2oi0fcI8VMbtoRAmaaslNXdCG1+lqvP4FbrQ6IwSBXkZagHLhFU9HCrG
# /syTRLLhAezu/3Lr00GrJzPQFnCEH1Y58678IgmfORBPC1JKkYaEt2OdDh4GmO0/
# 5cHelAK2/gTlQJINqDr6JfwyYHXSd+V08X1JUPvB4ILfJdmL+66Gp3CSBXG6IwXM
# ZUXBhtCyIaehr0XkBoDIGMUG1dUtwq1qmcwbdUfcSYCn+OwncVUXf53VJUNOaMWM
# ts0VlRYxe5nK+At+DI96HAlXHAL5SlfYxJ7La54i71McVWRP66bW+yERNpbJCjyC
# YG2j+bdpxo/1Cy4uPcU3AWVPGrbn5PhDBf3Froguzzhk++ami+r3Qrx5bIbY3TVz
# giFI7Gq3zWcxggUIMIIFBAIBATAsMBgxFjAUBgNVBAMMDUNvbmNlcHRTcGhlcmUC
# EFx/bsUUtnipQJoBTEzuwTswDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIB
# DDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEE
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgopqZbwUFswG9
# 5UWEq2t6APHiAA8Ew52TkeT63HF4mZswDQYJKoZIhvcNAQEBBQAEggEAeYtT3x32
# 31TRQy0R1YSBWjt76Ydtp9XjCZKWciQtiWRc9raHtGc8Y2SYic3CiPwn/Kd/jjzr
# kPVo8JJ9m9TU6pzAVWS22O6hSActsYiVl/Tto6BColIOB+wG+Adz5VU6HDMVIrBd
# dlPsv/uzesE6U9Hl2w45DC88DsndykEJI2Mi+6ljAQaIJ6eKYXjn4zadYGzHwZlJ
# l0M3QJl86ua0bVWYvzmGpiNbrRzysmYWbNWXnpBVtBnvL2JZPfnVQf4d5oSOxLOX
# o+g7p9RjN3ZvuZnncPTl501N3HQ60FfwrVtR1M9p89ki6Og0wTmNVCHqCAa2JrgW
# 65uisCx4HHNi3aGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA4MDQwMDI1MjRa
# MC8GCSqGSIb3DQEJBDEiBCC0SxCKZVhkrCFHNi7luhIjux9d/+Zu/zrJ0yzeYlO7
# XzANBgkqhkiG9w0BAQEFAASCAgC4r2eHet+U8Y3fHHvlWaJhkxwFYyJwNV4w7SYC
# ZOr5L9uoKip3nYkfx/rlpguLxy3gZcN+7fLT0D73WNJ9ZCwC4z1jf7Yr8ARqh6G7
# 1DbueT0PZSlvnEWzHjy1TIt3j/4tMyP+GIBD2bdRGrqWFCuvJrvw92xogX76lY/0
# gX8iInpJmrYkV8VUUN9JNY1K8XQZW9lVqpLxBMBJOFC9PldEQ6l1Ba+g4a1S76lN
# 5ojE+A2k7wRZ1OfsP4svyruZRjd30pdLZzq+HJ8fY8GE/ZlkbYn9P1CCkpdeAX29
# y1UgWXtg2gE286o7YJ74AKHMe//OR9VpZCV+YPsJrVAaC3UiB/RsacflDDyYPVHd
# 1w3u7LKhkqt6cb1/QZUoSYl6x0dp2MrO4xJiHFutPhxZDk9WGyMwa1PvT6G/eKGl
# ghdLaFckBbZMgfeYPPt5wnza7aXKHA7XmHwgMGj1Wd1T55i6QrH4JiIGlpbyJbfy
# IeuP/3UguUYH1vDlAm+YqAGRbCy3zmCAtXDuJsTNysy4IrMy5nGA89pwBTrXyjoZ
# X163T447Hu0Yc+DWTAJMHqDasAPMOxjjVvNpe4za00AbYOmnLcWAWKNVCfiklk+i
# vHlz6pRvWOglSya8mzdJQPMz99WLRBwnjsx+UiCaXSzO1le+ls0k5FBMYEbJYgLb
# pBuNBg==
# SIG # End signature block
