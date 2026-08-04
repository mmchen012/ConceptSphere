<#
.SYNOPSIS
    Registers (or removes) a ConceptSphere tool as an elevated logon task.

.DESCRIPTION
        powershell -NoProfile -ExecutionPolicy Bypass -File Register-ConceptSphereTask.ps1 `
            -TaskName "MiniTray" -Exe "C:\Program Files\ConceptSphere\MiniTray.exe" -Delay 20

    Task shape: logon trigger for one user, RunLevel Highest, runs on battery and
    is not stopped when unplugged, no execution time limit, IgnoreNew for
    multiple instances.

    Task names are load-bearing: StartMenuWatchdog restarts EnhancedStartMenu
    with schtasks /end + /run against "Enhanced Start Menu".

    TWO INDEPENDENT PATHS. It first tries the ScheduledTasks cmdlets. If any
    part of that throws -- a property the CIM class does not expose on this
    build, a module that will not load, an account name that will not resolve --
    it falls back to writing the task XML and handing it to schtasks.exe, which
    depends on nothing but the exe itself. Only if BOTH fail does it exit 1.

    Every step is logged, with the exception type and line number on failure, to
    %TEMP%\ConceptSphere-task-register.log and to stdout (which the installer
    captures into its details pane).

.NOTES
    Deliberately NO Set-StrictMode: this runs unattended during an install, and
    a strict-mode complaint about a property that happens not to exist on one
    Windows build is not worth failing an installation over.

    Native-command gotcha: with $ErrorActionPreference = 'Stop', piping a native
    exe's stderr into PowerShell (2>&1) turns each line into an ErrorRecord and
    throws NativeCommandError. schtasks /End writes to stderr whenever the task
    is absent or not running -- the normal case on a clean install. All native
    calls go through Invoke-Native, which drops to 'Continue' for the duration
    and returns the exit code.

    Exit codes: 0 success, 1 failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskName,

    [Parameter(Mandatory = $true)]
    [string]$Exe,

    # Account the task runs as. Default is the identity running this script,
    # read from the process token rather than %USERDOMAIN%\%USERNAME% -- those
    # can disagree with the real account name (Microsoft accounts truncate the
    # profile name), and an unresolvable name is a registration failure.
    [string]$User,

    # Logon delay in seconds.
    [int]$Delay = 0,

    # End, kill and unregister instead of registering.
    [switch]$Remove,

    # Register and immediately run it.
    [switch]$Start,

    [string]$LogPath = (Join-Path ([IO.Path]::GetTempPath()) 'ConceptSphere-task-register.log')
)

$ErrorActionPreference = 'Stop'

$exeName = Split-Path -Leaf $Exe
$script:Failures = @()

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Write-Failure {
    param([string]$Step, $ErrorRecord)
    $type = 'unknown'
    $line = '?'
    try { $type = $ErrorRecord.Exception.GetType().FullName } catch { }
    try { $line = $ErrorRecord.InvocationInfo.ScriptLineNumber } catch { }
    $msg = "$Step failed [$type, line $line]: $($ErrorRecord.Exception.Message)"
    $script:Failures += $msg
    Write-Log "  $msg"
}

# Run a native exe without letting its stderr become a terminating error.
# Returns the exit code.
function Invoke-Native {
    param([string]$File, [string[]]$Arguments)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $File @Arguments 2>&1
        foreach ($l in @($out)) {
            if ("$l".Trim()) { Write-Log "    $l" }
        }
        return $LASTEXITCODE
    }
    catch {
        Write-Log "    (native call failed: $($_.Exception.Message))"
        return -1
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Resolve-User {
    if ($User) { return $User }
    try {
        $n = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($n) { return $n }
    } catch { }
    return "$env:USERDOMAIN\$env:USERNAME"
}

# Best effort, never fatal: a tool that is not running is the normal case.
function Stop-Tool {
    param([string]$Name, [string]$Image)
    try {
        [void](Invoke-Native -File 'schtasks.exe' -Arguments @('/End', '/TN', $Name))
        Start-Sleep -Milliseconds 200
        $procs = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Image)) -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            Write-Log "  stopping $($procs.Count) running $Image process(es)"
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "  (stop skipped: $($_.Exception.Message))"
    }
}

function Test-TaskExists {
    param([string]$Name)
    # Cmdlet first, schtasks as the answer if the module is the thing that is broken.
    try {
        if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) { return $true }
    } catch { }
    return ((Invoke-Native -File 'schtasks.exe' -Arguments @('/Query', '/TN', $Name)) -eq 0)
}

# --- path 1: the ScheduledTasks cmdlets --------------------------------------
function Register-ViaCmdlets {
    param([string]$Name, [string]$Path, [string]$Account, [int]$DelaySeconds)

    $action = New-ScheduledTaskAction -Execute $Path -WorkingDirectory (Split-Path -Parent $Path)

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Account
    if ($DelaySeconds -gt 0) {
        try { $trigger.Delay = "PT${DelaySeconds}S" }
        catch { Write-Log "  (could not set trigger delay: $($_.Exception.Message))" }
    }

    $principal = New-ScheduledTaskPrincipal -UserId $Account -LogonType Interactive -RunLevel Highest

    # Built in two stages: if this build rejects one of the optional switches,
    # a plain settings set still gets the task registered.
    try {
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -DontStopOnIdleEnd `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit ([TimeSpan]::Zero)
    }
    catch {
        Write-Log "  (full settings set rejected: $($_.Exception.Message)) -- using defaults"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    }

    Register-ScheduledTask -TaskName $Name `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description "ConceptSphere: $(Split-Path -Leaf $Path), started at logon." `
        -Force | Out-Null
}

# --- path 2: schtasks + task XML ---------------------------------------------
function Register-ViaSchtasks {
    param([string]$Name, [string]$Path, [string]$Account, [int]$DelaySeconds)

    $delayXml = ''
    if ($DelaySeconds -gt 0) { $delayXml = "      <Delay>PT${DelaySeconds}S</Delay>`r`n" }

    $esc = {
        param($s)
        $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
    }
    $xPath = & $esc $Path
    $xDir  = & $esc (Split-Path -Parent $Path)
    $xUser = & $esc $Account

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>ConceptSphere: $(Split-Path -Leaf $Path), started at logon.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$xUser</UserId>
$delayXml    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$xUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$xPath</Command>
      <WorkingDirectory>$xDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    # schtasks wants Unicode XML.
    $xmlFile = Join-Path ([IO.Path]::GetTempPath()) ("ConceptSphere-" + ($Name -replace '[^A-Za-z0-9]', '') + ".xml")
    Set-Content -LiteralPath $xmlFile -Value $xml -Encoding Unicode
    Write-Log "  wrote task XML: $xmlFile"

    $rc = Invoke-Native -File 'schtasks.exe' -Arguments @('/Create', '/TN', $Name, '/XML', $xmlFile, '/F')
    if ($rc -ne 0) {
        Write-Log "  schtasks /Create returned $rc -- retrying with an explicit /RU"
        $rc = Invoke-Native -File 'schtasks.exe' -Arguments @('/Create', '/TN', $Name, '/XML', $xmlFile, '/F', '/RU', $Account)
    }
    if ($rc -ne 0) { throw "schtasks /Create returned $rc" }

    # Set CS_KEEPXML=1 to leave the XML behind for inspection.
    if (-not $env:CS_KEEPXML) {
        try { Remove-Item -LiteralPath $xmlFile -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# =============================================================================
Write-Log "=== $TaskName ($(if ($Remove) { 'remove' } else { 'register' })) ==="
Write-Log "  PowerShell $($PSVersionTable.PSVersion), $([IntPtr]::Size * 8)-bit"

$account = Resolve-User

if ($Remove) {
    Stop-Tool -Name $TaskName -Image $exeName

    $gone = $false
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
        $gone = $true
    }
    catch {
        Write-Failure 'Unregister-ScheduledTask' $_
    }
    if (-not $gone) {
        [void](Invoke-Native -File 'schtasks.exe' -Arguments @('/Delete', '/TN', $TaskName, '/F'))
    }

    if (Test-TaskExists -Name $TaskName) {
        Write-Log "REMOVE FAILED: '$TaskName' is still registered."
        exit 1
    }
    Write-Log "Removed (or was never registered)."
    exit 0
}

Write-Log "  exe   : $Exe"
Write-Log "  user  : $account"
Write-Log "  delay : ${Delay}s"

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Log "FAILED: executable not found: $Exe"
    exit 1
}

# An existing copy holds the exe open and, being elevated, cannot be replaced or
# reloaded by a normal process.
Stop-Tool -Name $TaskName -Image $exeName

$registered = $false

try {
    Register-ViaCmdlets -Name $TaskName -Path $Exe -Account $account -DelaySeconds $Delay
    $registered = Test-TaskExists -Name $TaskName
    if ($registered) { Write-Log "  registered via ScheduledTasks cmdlets." }
    else { Write-Log "  cmdlets reported success but the task is not there." }
}
catch {
    Write-Failure 'ScheduledTasks cmdlets' $_
}

if (-not $registered) {
    Write-Log "  falling back to schtasks + XML..."
    try {
        Register-ViaSchtasks -Name $TaskName -Path $Exe -Account $account -DelaySeconds $Delay
        $registered = Test-TaskExists -Name $TaskName
        if ($registered) { Write-Log "  registered via schtasks." }
    }
    catch {
        Write-Failure 'schtasks + XML' $_
    }
}

if (-not $registered) {
    Write-Log "FAILED to register '$TaskName'. Both paths were tried:"
    foreach ($f in $script:Failures) { Write-Log "  - $f" }
    exit 1
}

if ($Start) {
    $rc = Invoke-Native -File 'schtasks.exe' -Arguments @('/Run', '/TN', $TaskName)
    Write-Log "  start requested (schtasks returned $rc)."
}

Write-Log "OK: '$TaskName' is registered."
exit 0

# SIG # Begin signature block
# MIIb8AYJKoZIhvcNAQcCoIIb4TCCG90CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAkljqJu2pvw3AR
# sF1JqSQfjIrZFnjCZHaIKBOSis2jgaCCFj4wggMAMIIB6KADAgECAhBcf27FFLZ4
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
# AYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQglTfHI7TnQpxb
# 1T6QU4ZsXX+kUwJdFnU6g3xkJMaXfoQwDQYJKoZIhvcNAQEBBQAEggEApFAnZkN1
# mHmyP7V1tWeiutTdlJvfY7FuWuQClKlC7w/Kg8tIy9gO2oewIagjSvFLldtmqHsn
# R9TIkHLviBfOe76m7xYl/xWNhPYAhMFCDbQLucMDPIasIgLlcTqD7pEmBo0p9SXY
# 12iY8H04vh/eKbwlwh2w1GDEJgjjDB48psdIYi19WJpOSVShfr7slUVCpZJQyCQr
# YAkXF2+4/TnxCtwj+W392KYHvlLnvXFAuwyI+IYuBZMC06fH5o0BtugMidGb5B11
# LLGpMFg3E09ihs+yUhyY7ISuskTPMwOHaatB03WAm5ZlPHvm63r0gbKyeYMSWFaS
# 3dnjFfmttNQMvaGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJ
# BgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGln
# aUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAy
# NSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG
# 9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA4MDMyMDQ0MTRa
# MC8GCSqGSIb3DQEJBDEiBCCGirRQ+lKoATFvdcu8niIsvabKuyZrcQP22eN4GnSY
# nTANBgkqhkiG9w0BAQEFAASCAgCg3ThWtcVAKSCbphv63ZVvrbSXEt0S4FgwW6gH
# XQbUOvk0XuiB/o/wQ8+B7K/glmclBAwsZLi1sgpOXiRUgaNg+3NfzlhK1bATF61x
# pWRgtL8TE9fz+jFthLMnZhjc+9bojgalFmqcplWHangn72xlwK8MEzY2liXswiFs
# FsZDTOQKY+LHeMR3Dmqj3wtl5IfmkDgo4d1q8/rEcN3w6fvm5VbasP42WeF5iodH
# WSLaHknXBfu6MwVbynvOjWEbfRgN3w1keJqR9xWjtQ1cuCw1mU/oYn9viMzovERR
# r71nyeXbaR/3MS9yhuawCpfnb52zRPc0n9UsdFxVhAtWZ8XpyDvpgDDS8BlhTvFz
# jP/DlBm/5ZeY4k2tnulDbcrcxjOcwvenoIbuLUORuIM3NUb/XN5RFeG6PZVKMSKt
# GWCZ/0W+T1dvcAEIgvvBisNElw/mVKrcq6rxlhr6jxM7D97NBqu9+Lu0LLEdEY5z
# i9W/wIMu0oraT5AMsK+nzXMyuV1VLUX5j4L1ALUy3xCT0jCQ0kxGppE38yTNED31
# 5ELWbcqHV4cWWtTCML33FQRVG34cIDFxr/g1WwQwsdmML5d7gpkHraWgmvpV55Xs
# 3y4asa6lt+IPeidLvT5CQy5V5LsAdQFtfhKUPF7C8Eael1OGZLYZV6a+F0Cn4OLo
# ddfBnw==
# SIG # End signature block
