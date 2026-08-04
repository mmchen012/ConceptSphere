param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$Ahk2Exe,
    [string]$Base,
    [switch]$Quiet
)

# Compile-AhkV2.ps1
# Stop -> compile (AHK v2, 64-bit) -> start, for the .ahk passed in.
#
# Called from the "Compile Script v2 64-bit" shortcut-menu entry. Because the
# compiled exe may be running elevated (a scheduled task with RunLevel Highest),
# this self-elevates first: a normal-integrity process can't terminate an
# elevated one, which is what makes Ahk2Exe's own "Reload" fail.
#
# Ends with a message box reporting success or failure. -Quiet suppresses it
# for scripted use.

$ErrorActionPreference = 'Stop'

# --- result dialog ----------------------------------------------------------
function Show-Result {
    param(
        [string]$Text,
        [ValidateSet('Info', 'Error')][string]$Kind = 'Info',
        [string]$Caption = 'Compile AHK v2 (64-bit)'
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
        # Fallback if WinForms is unavailable; also a real Win32 message box.
        $flag = if ($Kind -eq 'Error') { 16 } else { 64 }
        [void](New-Object -ComObject WScript.Shell).Popup($Text, 0, $Caption, $flag)
    }
}

function Fail($msg) {
    Write-Host $msg -ForegroundColor Red
    Show-Result -Text "Compile failed.`r`n`r`n$msg" -Kind Error
    exit 1
}

# --- self-elevate -----------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Forward every parameter. The previous version dropped -Ahk2Exe and -Base
    # here, so an explicitly supplied path was silently lost on elevation.
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Script', "`"$Script`""
    )
    if ($Ahk2Exe) { $argList += @('-Ahk2Exe', "`"$Ahk2Exe`"") }
    if ($Base)    { $argList += @('-Base',    "`"$Base`"") }
    if ($Quiet)   { $argList += '-Quiet' }

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    } catch {
        # UAC declined. Without this the script died silently.
        Show-Result -Kind Error -Text @"
Compile failed.

Elevation was declined, so nothing was compiled.
"@
        exit 1
    }
    exit    # the elevated copy shows the result dialog, so this one stays quiet
}

# Everything below runs elevated. The try/catch guarantees a dialog even for
# errors that don't go through Fail() -- with ErrorActionPreference = 'Stop',
# any unexpected terminating error would otherwise end the script in silence.
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

    Write-Host "Script : $Script"
    Write-Host "Output : $exePath"
    Write-Host "Base   : $Base"

    # --- stop the running copy ----------------------------------------------
    # Prefer stopping via its scheduled task, so restarting puts it back at the
    # same integrity level and user context it gets at logon.
    $task = Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.Actions.Execute -like "*\$exeName.exe" } |
            Select-Object -First 1

    $wasRunning = [bool](Get-Process -Name $exeName -ErrorAction SilentlyContinue)

    if ($wasRunning) {
        if ($task) {
            Write-Host "Stopping task: $($task.TaskPath)$($task.TaskName)"
            Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
        }
        Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 400
    } else {
        Write-Host 'Not currently running.'
    }

    # --- compile ------------------------------------------------------------
    # /silent suppresses Ahk2Exe's own error window, so capture its streams --
    # otherwise a failure gives nothing but an exit code.
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

    # --- start it again -----------------------------------------------------
    $restartNote = 'It was not running, so it was not restarted.'
    if ($wasRunning) {
        if ($task) {
            Start-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
            $restartNote = "Restarted via scheduled task $($task.TaskPath)$($task.TaskName)"
            Write-Host 'Restarted via its scheduled task.' -ForegroundColor Green
        } else {
            # No task: started directly. Note this inherits THIS shell's elevation.
            Start-Process -FilePath $exePath
            $restartNote = 'Restarted directly, and therefore elevated, because no scheduled task was found.'
            Write-Host 'Restarted directly (elevated, since no scheduled task was found).' -ForegroundColor Yellow
        }
    }

    Show-Result -Kind Info -Text @"
Compiled successfully.

Script : $Script
Output : $exePath
Size   : $('{0:N0}' -f $size) bytes

$restartNote
"@
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Show-Result -Kind Error -Text "Compile failed.`r`n`r`n$($_.Exception.Message)"
    exit 1
}
