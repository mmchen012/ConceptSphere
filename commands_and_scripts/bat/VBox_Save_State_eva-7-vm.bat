@echo off
setlocal enabledelayedexpansion
timeout /t 5 /nobreak >nul

set "VM_NAME=Ubuntu-24.04_EVA-7"
set "VM_IP=192.168.56.101"

:: Step 1: Check if the VM is running
echo Checking VM State for: %VM_NAME%

for /f %%i in ('VBoxManage list runningvms ^| findstr /i "\"%VM_NAME%\""') do set VM_RUNNING=true

if not defined VM_RUNNING (
    echo VM is not running or does not exist. Exiting.
    timeout /t 3 /nobreak >nul
    exit
) else (
    echo VM is running.
)

:: Step 2: Ping check
echo Checking if VM is reachable via ping...
:PING_CHECK
ping -n 1 %VM_IP% | find "Reply from %VM_IP%" >nul

if not errorlevel 1 (
    echo VM is reachable at %VM_IP%.
    goto :Save_VM_State
) else (
    goto :FORCE_SHUTDOWN
)

:: Step 3-1: Save the VM state
:Save_VM_State
echo Saving VM state...
VBoxManage controlvm "%VM_NAME%" savestate
echo VM state saved successfully.
timeout /t 3 /nobreak >nul
exit

:: Step 3-2: Force shutdown
:FORCE_SHUTDOWN
echo Forcing power off for %VM_NAME%...
VBoxManage controlvm "%VM_NAME%" poweroff
timeout /t 5 /nobreak >nul
echo VM has been forcibly powered off.
timeout /t 3 /nobreak >nul
exit
