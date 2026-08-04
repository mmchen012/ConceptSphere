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
    goto :Prompt
) else (
    echo VM is NOT reachable via ping. Forcing shutdown...
    goto :FORCE_SHUTDOWN
)

:: User prompt for saving state or shutting down
:Prompt
set /p choice=Do you want to save the VM state? (y/n): 

if /i "%choice%"=="y" (
    GOTO :SAVE_VM_STATE
) else if /i "%choice%"=="n" (
    goto :GRACEFUL_SHUTDOWN
) else (
    echo Invalid choice. Please enter y or n.
    goto :Prompt
)

:: Step 3-1: Save the VM state
: Save_VM_State
echo Saving VM state...
VBoxManage controlvm "%VM_NAME%" savestate
echo VM state saved successfully.
timeout /t 3 /nobreak >nul
exit

:: Step 3-2: Gracefully shut down the VM
:GRACEFUL_SHUTDOWN
echo Attempting to gracefully shut down %VM_NAME%...
VBoxManage controlvm "%VM_NAME%" acpipowerbutton
timeout /t 10 /nobreak >nul
set "VM_RUNNING="

:: Check if VM is running
for /f %%i in ('VBoxManage list runningvms ^| findstr /i "\"%VM_NAME%\""') do set VM_RUNNING=true

if not defined VM_RUNNING (
    echo VM has shut down successfully.
    timeout /t 3 /nobreak >nul
    exit
) else (
    echo VM did not shutdown successfully; force power off VM.
    goto :FORCE_SHUTDOWN
)

:: Step 3-3: Force shutdown
:FORCE_SHUTDOWN
echo Forcing power off for %VM_NAME%...
VBoxManage controlvm "%VM_NAME%" poweroff
timeout /t 5 /nobreak >nul
echo VM has been forcibly powered off.
timeout /t 3 /nobreak >nul
exit

