param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$Ahk2Exe,
    [string]$Base,
    [string]$Destination = 'C:\Program Files\ConceptSphere',
    [switch]$Quiet
)

# Compile-AhkV2-ConceptSphere.ps1
# Compile (AHK v2, 64-bit) -> copy the .exe into C:\Program Files\ConceptSphere,
# replacing what is there -> start the installed copy, always.
#
# Called from the "Compile v2 and copy to ConceptSphere" shortcut-menu entry.
# Sibling of Compile-AhkV2.ps1, which compiles in place and starts nothing. This
# one deploys and then always starts the INSTALLED copy -- whether or not it was
# running beforehand -- so the freshly built version is live when it finishes.
# Only the installed copy is started: launching the dev copy too would leave two
# instances of the same script fighting over the same hotkeys.
#
# Self-elevates: writing to Program Files needs it, and so does terminating an
# exe that runs elevated from a scheduled task.

$ErrorActionPreference = 'Stop'

# --- result dialog ----------------------------------------------------------
function Show-Result {
    param(
        [string]$Text,
        [ValidateSet('Info', 'Error')][string]$Kind = 'Info',
        [string]$Caption = 'Compile v2 and copy to ConceptSphere'
    )
    if ($Quiet) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = if ($Kind -eq 'Error') { [Windows.Forms.MessageBoxIcon]::Error }
                else                   { [Windows.Forms.MessageBoxIcon]::Information }
        # A topmost hidden owner keeps the box from opening behind the Explorer
        # window that launched us.
        $owner = New-Object Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
        [void][Windows.Forms.MessageBox]::Show($owner, $Text, $Caption,
            [Windows.Forms.MessageBoxButtons]::OK, $icon)
        $owner.Dispose()
    } catch {
        $flag = if ($Kind -eq 'Error') { 16 } else { 64 }
        [void](New-Object -ComObject WScript.Shell).Popup($Text, 0, $Caption, $flag)
    }
}

function Fail($msg) {
    Write-Host $msg -ForegroundColor Red
    Show-Result -Text "Compile and copy failed.`r`n`r`n$msg" -Kind Error
    exit 1
}

# --- self-elevate -----------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Script', "`"$Script`""
    )
    if ($Ahk2Exe)     { $argList += @('-Ahk2Exe',     "`"$Ahk2Exe`"") }
    if ($Base)        { $argList += @('-Base',        "`"$Base`"") }
    if ($Destination) { $argList += @('-Destination', "`"$Destination`"") }
    if ($Quiet)       { $argList += '-Quiet' }

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    } catch {
        Show-Result -Kind Error -Text @"
Compile and copy failed.

Elevation was declined, so nothing was compiled or copied.
"@
        exit 1
    }
    exit    # the elevated copy shows the result dialog
}

try {
    if (-not (Test-Path -LiteralPath $Script)) { Fail "Script not found: $Script" }

    # --- locate Ahk2Exe and the v2 64-bit base file -------------------------
    if (-not $Ahk2Exe -or -not (Test-Path -LiteralPath $Ahk2Exe)) {
        $Ahk2Exe = @(
            'C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe'
            'C:\Program Files\AutoHotkey\v2\Compiler\Ahk2Exe.exe'
            "$env:LOCALAPPDATA\Programs\AutoHotkey\Compiler\Ahk2Exe.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $Ahk2Exe) { Fail 'Ahk2Exe.exe not found. Pass -Ahk2Exe <path>.' }

    if (-not $Base -or -not (Test-Path -LiteralPath $Base)) {
        $Base = @(
            'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
            "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $Base) { Fail 'AutoHotkey64.exe (v2 base file) not found. Pass -Base <path>.' }

    $exePath = [IO.Path]::ChangeExtension($Script, '.exe')
    $exeName = [IO.Path]::GetFileNameWithoutExtension($Script)
    $destExe = Join-Path $Destination "$exeName.exe"

    Write-Host "Script : $Script"
    Write-Host "Output : $exePath"
    Write-Host "Deploy : $destExe"
    Write-Host "Base   : $Base"

    # A scheduled task pointing at the INSTALLED exe, so it can be restarted at
    # the same integrity level and user context it gets at logon.
    $installedTask = Get-ScheduledTask -ErrorAction SilentlyContinue |
                     Where-Object { $_.Actions.Execute -eq $destExe } |
                     Select-Object -First 1
    # ...and any task pointing at the dev exe, so stopping it is clean too.
    $devTask = Get-ScheduledTask -ErrorAction SilentlyContinue |
               Where-Object { $_.Actions.Execute -eq $exePath } |
               Select-Object -First 1

    # --- stop every running copy --------------------------------------------
    # Both the dev exe (locked during compile) and the installed exe (locked
    # during the copy) have to be released.
    foreach ($t in @($installedTask, $devTask)) {
        if ($t) {
            Write-Host "Stopping task: $($t.TaskPath)$($t.TaskName)"
            Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        }
    }
    if (Get-Process -Name $exeName -ErrorAction SilentlyContinue) {
        Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 400
    } else {
        Write-Host 'Not currently running.'
    }

    # --- compile ------------------------------------------------------------
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()

    $proc = Start-Process -FilePath $Ahk2Exe -Wait -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList @(
            '/in',   "`"$Script`"",
            '/out',  "`"$exePath`"",
            '/base', "`"$Base`"",
            '/silent'
        )

    $compilerOut = ((Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue),
                    (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)) -join ''
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    $detail = if ($compilerOut.Trim()) { "`r`n`r`n$($compilerOut.Trim())" } else { '' }

    if ($proc.ExitCode -ne 0) {
        Fail "Ahk2Exe failed with exit code $($proc.ExitCode).$detail"
    }
    if (-not (Test-Path -LiteralPath $exePath)) {
        Fail "Compile reported success but no exe was produced.$detail"
    }

    $size = (Get-Item -LiteralPath $exePath).Length
    Write-Host ("Compiled OK  ({0:N0} bytes)" -f $size) -ForegroundColor Green

    # --- copy into ConceptSphere --------------------------------------------
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-Host "Created $Destination"
    }

    # Retry: Windows can hold the old exe briefly after the process exits.
    $copied = $false
    $copyErr = ''
    foreach ($attempt in 1..5) {
        try {
            Copy-Item -LiteralPath $exePath -Destination $destExe -Force -ErrorAction Stop
            $copied = $true
            break
        } catch {
            $copyErr = $_.Exception.Message
            Start-Sleep -Milliseconds 400
        }
    }
    if (-not $copied) {
        Fail "Compiled OK, but could not replace`r`n$destExe`r`n`r`n$copyErr"
    }
    Write-Host "Copied to $destExe" -ForegroundColor Green

    # --- start the installed copy -------------------------------------------
    # Always, whether or not anything was running before. Only the installed
    # copy: starting the dev copy as well would leave two instances of the same
    # script fighting over the same hotkeys.
    if ($installedTask) {
        Start-ScheduledTask -TaskName $installedTask.TaskName -TaskPath $installedTask.TaskPath
        $restartNote = "Started via scheduled task $($installedTask.TaskPath)$($installedTask.TaskName)"
    } else {
        # No task points at it, so this inherits THIS shell's elevation.
        Start-Process -FilePath $destExe
        $restartNote = 'Started directly, and therefore elevated, because no scheduled task points at the installed exe.'
    }
    Write-Host $restartNote -ForegroundColor Green

    Show-Result -Kind Info -Text @"
Compiled and copied successfully.

Script : $Script
Output : $exePath
Copied : $destExe
Size   : $('{0:N0}' -f $size) bytes

$restartNote
"@
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Show-Result -Kind Error -Text "Compile and copy failed.`r`n`r`n$($_.Exception.Message)"
    exit 1
}
