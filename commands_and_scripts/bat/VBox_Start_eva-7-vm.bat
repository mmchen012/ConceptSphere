@echo off
setlocal enabledelayedexpansion
timeout /t 5 /nobreak >nul

set "VM_NAME=Ubuntu-24.04_EVA-7"
set "VM_IP=192.168.56.101"
set "TIMEOUT_SECS=120"

:: Step 1: Check if the VM is powered off
echo Checking VM State for: %VM_NAME%

for /f %%i in ('VBoxManage list runningvms ^| findstr /i "\"%VM_NAME%\""') do set VM_RUNNING=true

if not defined VM_RUNNING (
    echo VM is powered off. Proceeding to start VM...
    goto :START_VM
) else (
    echo VM is running.
)

:: Step 2: Ping the VM
echo Checking if VM is reachable via ping...
ping -n 1 %VM_IP% | find "Reply from %VM_IP%" >nul && (
    echo VM is already online.
    GOTO :PROMPT
) || (
    echo VM is NOT reachable. Attempting forced shutdown...
    goto :FORCE_SHUTDOWN
)

:: User prompt for save state and restart or graceful shutdown
:PROMPT
set /p choice=Do you want to save the VM state and restart the VM? (y/n/c): 

if /i "%choice%"=="y" (
    GOTO :SAVE_VM_STATE
) else if /i "%choice%"=="n" (
    goto :GRACEFUL_SHUTDOWN
) else if /i "%choice%"=="c" (
    exit
) else (
    echo Invalid choice. Please enter y or n or c.
    goto :PROMPT
)

:: Step 3-1: Save the VM state
:SAVE_VM_STATE
echo Saving VM state...
VBoxManage controlvm "%VM_NAME%" savestate
echo VM state saved successfully.
goto :START_VM

:: Step 3-2: Gracefully shut down the VM
:GRACEFUL_SHUTDOWN
echo Attempting to gracefully shut down %VM_NAME%...
VBoxManage controlvm "%VM_NAME%" acpipowerbutton
timeout /t 10 /nobreak >nul

:: Check if VM stopped
set "VM_RUNNING="
for /f %%i in ('VBoxManage list runningvms ^| findstr /i "\"%VM_NAME%\""') do set VM_RUNNING=true

if not defined VM_RUNNING (
    echo VM has shut down successfully.
    goto :START_VM
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
goto :START_VM

:: Step 4: Start VM in headless mode
:START_VM
echo Starting VM %VM_NAME% in headless mode...
VBoxManage startvm "%VM_NAME%" --type headless

:: Step 5: Ping in a loop until VM is reachable
echo Waiting for VM to become reachable at %VM_IP%...

for /f %%T in ('powershell -Command "[int][double]::Parse((Get-Date -UFormat %%s))"') do set START_TIME=%%T

:PING_LOOP
ping -n 1 %VM_IP% | find "Reply from %VM_IP%" >nul && (
    echo VM is online.
    timeout /t 3 /nobreak >nul
    exit
)

:: Capture end time
for /f %%T in ('powershell -Command "[int][double]::Parse((Get-Date -UFormat %%s))"') do set END_TIME=%%T

:: Calculate elapsed time (in seconds)
set /a ELAPSED_TIME=END_TIME-START_TIME
echo Elapsed time: %ELAPSED_TIME% seconds

:: Compare elapsed time
if %ELAPSED_TIME% gtr %TIMEOUT_SECS% (
    echo Timeout ^> %TIMEOUT_SECS% seconds.
    goto :FORCE_SHUTDOWN
) else (
    goto :PING_LOOP
)
