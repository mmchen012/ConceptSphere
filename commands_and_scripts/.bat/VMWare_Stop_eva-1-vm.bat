@echo off

if "%~1"=="__noautorun" goto :start
set "CMDAUTORUNSKIP=1"
"%ComSpec%" /c "%~f0" __noautorun %*
exit /b

:start

setlocal enabledelayedexpansion
timeout /t 3 /nobreak >nul

set VM_NAME=Ubuntu-24.04_EVA-1
set VM_PATH="D:\Virtual_Machines\%VM_NAME%\%VM_NAME%.vmx"
set VM_IP=192.168.142.100

:: Step 1: Check if the VM is running
echo Checking VM State for: %VM_NAME%

for /f %%i in ('vmrun list ^| find /i "%VM_NAME%"') do set VM_RUNNING=true

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
    echo VM is NOT reachable. Attempting forced shutdown...
    GOTO :FORCE_SHUTDOWN
)

:: User prompt for suspending or shutting down
:PROMPT
set /p choice=Do you want to suspend the VM? (y/n/c): 

if /i "%choice%"=="y" (
    GOTO :SUSPEND_VM
) else if /i "%choice%"=="n" (
    goto :GRACEFUL_SHUTDOWN
) else if /i "%choice%"=="c" (
    timeout /t 3 /nobreak >nul
    exit
) else (
    echo Invalid choice. Please enter y or n or c.
    goto :PROMPT
)

:: Step 3-1: Suspend the VM
:SUSPEND_VM
echo Suspending VM...
vmrun -T ws suspend %VM_PATH% soft
echo VM suspended successfully.
timeout /t 1 /nobreak >nul
exit

:GRACEFUL_SHUTDOWN
echo Attempting to gracefully shut down %VM_NAME%...
vmrun -T ws stop %VM_PATH% soft
timeout /t 10 /nobreak >nul

:: Check if VM stopped
set VM_RUNNING=
for /f %%i in ('vmrun list ^| find /i "%VM_NAME%"') do set VM_RUNNING=true

if not defined VM_RUNNING (
    echo VM has shut down successfully.
    timeout /t 3 /nobreak >nul
    exit
) else (
    echo VM did not shut down via soft command. Forcing power off...
    goto :FORCE_SHUTDOWN
)

:: Step 3-3: Force shutdown
:FORCE_SHUTDOWN
echo Forcibly powering off %VM_NAME%...
vmrun -T ws stop %VM_PATH% hard
timeout /t 5 /nobreak >nul
echo VM has been forcibly powered off.
timeout /t 3 /nobreak >nul
exit
