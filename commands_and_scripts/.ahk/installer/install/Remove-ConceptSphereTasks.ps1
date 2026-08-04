<#
.SYNOPSIS
    Removes every scheduled task that launches a ConceptSphere tool, wherever it
    lives and whatever it is called.

.DESCRIPTION
    For a clean install. Tasks registered by hand over time point at old copies
    (D:\Dropbox\...\v2.0\) under assorted names, and a leftover one is not
    harmless: two instances launched from different paths do NOT collide,
    because #SingleInstance Force matches on window class "AutoHotkey" plus the
    script path as the title. Different path, second instance, both claiming the
    same hotkeys.

    Matching is by the ACTION, not the task name: any task whose action runs one
    of the known executables is a match, however it was named. Task names are
    also matched against a known list, to catch a task whose exe has since been
    deleted or moved. Tasks under \Microsoft\ are never touched.

    Enumeration tries Get-ScheduledTask and falls back to parsing
    `schtasks /Query /FO CSV /V`, so a broken or missing ScheduledTasks module
    cannot stop the sweep. Removal does the same in reverse:
    Unregister-ScheduledTask, then `schtasks /Delete`.

    Everything is logged to %TEMP%\ConceptSphere-task-cleanup.log.

.EXAMPLE
    # See what would go, change nothing:
    powershell -NoProfile -ExecutionPolicy Bypass -File Remove-ConceptSphereTasks.ps1 -ListOnly
#>
[CmdletBinding()]
param(
    # Report matches without removing anything.
    [switch]$ListOnly,

    [string]$LogPath = (Join-Path ([IO.Path]::GetTempPath()) 'ConceptSphere-task-cleanup.log')
)

$ErrorActionPreference = 'Stop'
# Deliberately no Set-StrictMode: this runs unattended during an install.

# Executables that identify a task as ours, current and historical.
$knownExes = @(
    'MiniTray.exe'
    'EnhancedStartMenu.exe'
    'ConceptSphereWatchdog.exe'
    'StartMenuWatchdog.exe'     # superseded by the unified watchdog
    'ConsoleSelectAll.exe'
    'DesktopFocus.exe'
    'TogglePinnedOverflow.exe'
    'WindowSizer.exe'          # pre-merge name for MiniTray
    'MiniTrayUtil.exe'         # pre-rename
)

# Task names to remove even if the action no longer resolves to a known exe.
$knownNames = @(
    'MiniTray', 'MiniTrayUtil', 'Mini Tray'
    'Enhanced Start Menu', 'EnhancedStartMenu'
    'ConceptSphere Watchdog', 'ConceptSphereWatchdog'
    'Start Menu Watchdog', 'StartMenuWatchdog'
    'Console Select All', 'ConsoleSelectAll'
    'Desktop Focus', 'DesktopFocus'
    'Window Sizer', 'WindowSizer'
    'Toggle Pinned Overflow', 'TogglePinnedOverflow'
)

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

# Run a native exe without letting its stderr become a terminating error. With
# $ErrorActionPreference = 'Stop', piping native stderr into PowerShell (2>&1)
# turns each line into an ErrorRecord and throws NativeCommandError -- and
# schtasks writes to stderr for any task that is absent or not running.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments, [switch]$Quiet)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $File @Arguments 2>&1
        if (-not $Quiet) {
            foreach ($l in @($out)) {
                if ("$l".Trim()) { Write-Log "    $l" }
            }
        }
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = @($out) }
    }
    catch {
        Write-Log "    (native call failed: $($_.Exception.Message))"
        return [pscustomobject]@{ Code = -1; Output = @() }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Test-IsKnownExe {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $false }
    $leaf = ''
    try { $leaf = Split-Path -Leaf ($CommandLine.Trim().Trim('"')) } catch { return $false }
    return ($knownExes -contains $leaf)
}

# --- enumeration: cmdlet first, schtasks CSV as backup -----------------------
function Get-Candidates {
    $found = @()

    try {
        foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
            if ($task.TaskPath -like '\Microsoft\*') { continue }

            $why = $null
            foreach ($action in @($task.Actions)) {
                $exe = $null
                try { $exe = $action.Execute } catch { }
                if (Test-IsKnownExe $exe) { $why = "action runs $exe"; break }
            }
            if (-not $why -and ($knownNames -contains $task.TaskName)) { $why = 'known task name' }

            if ($why) {
                $found += [pscustomobject]@{
                    Name   = $task.TaskName
                    Path   = $task.TaskPath
                    Reason = $why
                }
            }
        }
        return $found
    }
    catch {
        Write-Log "Get-ScheduledTask unavailable ($($_.Exception.Message)); using schtasks."
    }

    $res = Invoke-Native -File 'schtasks.exe' -Arguments @('/Query', '/FO', 'CSV', '/V') -Quiet
    if ($res.Code -ne 0 -and $res.Output.Count -eq 0) {
        Write-Log 'schtasks query failed too; nothing can be enumerated.'
        return $found
    }

    $rows = @()
    try { $rows = @($res.Output | ForEach-Object { "$_" } | ConvertFrom-Csv) }
    catch { Write-Log "Could not parse the schtasks CSV: $($_.Exception.Message)"; return $found }

    foreach ($row in $rows) {
        $full = "$($row.TaskName)"
        if (-not $full -or $full -eq 'TaskName') { continue }
        if ($full -like '\Microsoft\*') { continue }

        $leafName = Split-Path -Leaf $full
        $taskPath = $full.Substring(0, $full.Length - $leafName.Length)
        if (-not $taskPath) { $taskPath = '\' }

        $cmd = "$($row.'Task To Run')"
        $why = $null
        if (Test-IsKnownExe $cmd) { $why = "action runs $cmd" }
        elseif ($knownNames -contains $leafName) { $why = 'known task name' }

        if ($why) {
            $found += [pscustomobject]@{ Name = $leafName; Path = $taskPath; Reason = $why }
        }
    }
    return $found
}

Write-Log "--- cleanup start (ListOnly=$ListOnly) ---"

$matched = @(Get-Candidates)

if ($matched.Count -eq 0) {
    Write-Log 'No existing ConceptSphere tasks found.'
    Write-Log '--- cleanup done ---'
    exit 0
}

foreach ($m in $matched) {
    $full = ($m.Path.TrimEnd('\')) + '\' + $m.Name

    if ($ListOnly) {
        Write-Log "WOULD REMOVE: $full  ($($m.Reason))"
        continue
    }

    Write-Log "Removing: $full  ($($m.Reason))"
    [void](Invoke-Native -File 'schtasks.exe' -Arguments @('/End', '/TN', $full))
    Start-Sleep -Milliseconds 150

    $removed = $false
    try {
        Unregister-ScheduledTask -TaskName $m.Name -TaskPath $m.Path -Confirm:$false
        $removed = $true
    }
    catch {
        Write-Log "  Unregister-ScheduledTask failed: $($_.Exception.Message)"
    }

    if (-not $removed) {
        $res = Invoke-Native -File 'schtasks.exe' -Arguments @('/Delete', '/TN', $full, '/F')
        $removed = ($res.Code -eq 0)
    }

    if ($removed) { Write-Log '  removed.' } else { Write-Log '  COULD NOT REMOVE.' }
}

if (-not $ListOnly) {
    # Anything still resident from a task we just deleted would keep holding its
    # exe open and keep claiming hotkeys.
    foreach ($exe in $knownExes) {
        $procs = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            Write-Log "Stopping $($procs.Count) running $exe process(es)."
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Log '--- cleanup done ---'
exit 0

# SIG # Begin signature block
# MIIb8AYJKoZIhvcNAQcCoIIb4TCCG90CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDgJI4aEfzIW21a
# dJU+Im/pJDiE1B8Nd3uhsipyFPE9IqCCFj4wggMAMIIB6KADAgECAhBcf27FFLZ4
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
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgUYoCqtfypuu5
# hSh68dsgJGvbfEJfv95LMTDI25cGQgQwDQYJKoZIhvcNAQEBBQAEggEAAJ6hoaa6
# wmIGAFA61b/nYHToU6NDdspTsnWpKwnDIvlDk6Y11HL9Dbx9Lg8vM6ZHVXmL6YbC
# KD72HB4RDCqkezr3gQsLS8UuLgIo50GkmTf+KW6EDfUGR5yuEChPxrdJwPaXPVGC
# SRutrc2VkYPou3lyofLGIeVPCgpcb2YgRqXGEk6OK9d7xE0kRnKQ1/ByMf+16/5w
# Vr/Mtm9wy5Z3SYseQXvJzeT33jXVRP1cbqBAVEebqJWQf8KaU/omtd122/7jaSaB
# Y4Ai62x5Cb9viRtb1dE4bECrbEQRIFmWt2tUuMPx6oyEYMmWwM6kpCbKDESJcG7J
# sMD0zMM0J8SCvKGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA4MDMyMDQ0MTRa
# MC8GCSqGSIb3DQEJBDEiBCALwUXzTP8m6/s2BEqDYQo+rzF08wMbFsV2AZwj5VGf
# 0DANBgkqhkiG9w0BAQEFAASCAgAppjGPczz7yDEvPnOkY1/uMNJstcGzbBS719E8
# OiogwAKVKRNmA6b+PonXLM98UvhGujWiEyS5HOJQB4qi1il1uacTBuxPaZDEGDZ/
# 6O49GXOq2TJaeNEAgGpgtmRNIdblNED5JKhssU9pBHP2vTgs7+uBcjz5Ia+Ld/qr
# Do70v71jAjnK3TLDCo8MzkK8fl9NL9DFL0atmLtwf/WN34X+Q1DL9zpmbZWOysUD
# VWrOVa2A6Frk8vNeSOSCD3w7OthfXT6nWMJtCIsSS9z6VD30w6mEgw+5mfD50nOF
# sTx02FXGF1WtIguvVN8lWiDMS/LicntNyHUUMXCaZHAmt6HvNfIadr71i2my0x5y
# 3ccGaJqa1hfjWxxr0yKfkobDyZpWNyFiGQu2Gmjb4v0uofWbYBENlmtuE/DYRS8P
# WmybESq52ZfEUBKWI/mLB4FRklI8PZkHs449aOSBwKXGq6sEG6ntALWpB3exPJPe
# 8HcBTZwI0fyD1QZ+0W2V9HSzee+5LBQNFoJo4jmGYOeTOHu4Dv6aNjkAKLiySVJX
# js4jb6FwviwvubgjUqXckkXdwzCR4Qlru4czKUuGgV9ibMWVK/7/euFERRLICOu0
# 7dZocf1k6V8753ycCiOcqBOJgkZGZoTZnkMNUBEmhp/9I1DKydllEqQaLlUxW9Ly
# bKD5RQ==
# SIG # End signature block
