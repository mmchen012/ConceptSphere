@echo off

if "%~1"=="__noautorun" goto :start
set "CMDAUTORUNSKIP=1"
"%ComSpec%" /c "%~f0" __noautorun %*
exit /b

:start

setlocal EnableExtensions EnableDelayedExpansion
timeout /t 3 /nobreak >nul

set "VM_NAME=Ubuntu-24.04_EVA-2"
set "VM_PATH=D:\Virtual_Machines\%VM_NAME%\%VM_NAME%.vmx"
set "VM_IP=172.16.0.128"
set "SSH_USER=accuser"

:: Step 1: Check if the VM is powered off
echo Checking VM State for: %VM_NAME%

set "VM_RUNNING="
for /f %%i in ('vmrun list ^| find /i "%VM_NAME%"') do set "VM_RUNNING=true"

if not defined VM_RUNNING (
    echo VM is powered off. Proceeding to start VM...
    set "VM_ACTION=START"
    goto START_VM
) else (
    echo VM is running.
)

:: Step 2: Ping the VM
echo Checking if VM is reachable via ping...
ping -n 1 %VM_IP% | find "Reply from %VM_IP%" >nul
if not errorlevel 1 (
    echo VM is already online.
    goto SSH
) else (
    echo VM is NOT reachable. Attempting forced shutdown...
    goto FORCE_SHUTDOWN
)

:: User prompt for save state and restart or graceful shutdown
:PROMPT
set /p choice=Do you want to suspend the VM? (y/n/c): 
if /i "%choice%"=="y" (
    goto SUSPEND_VM
) else if /i "%choice%"=="n" (
    goto GRACEFUL_SHUTDOWN
) else if /i "%choice%"=="c" (
    timeout /t 3 /nobreak >nul
    exit
) else (
    echo Invalid choice. Please enter y or n or c.
    goto PROMPT
)

:: Step 3-1: Suspend the VM
:SUSPEND_VM
echo Suspending VM...
vmrun -T ws suspend "%VM_PATH%" soft
echo VM suspended successfully.

if /i "%VM_ACTION%"=="EXIT" (
    timeout /t 3 /nobreak >nul
    exit
) else (
    goto START_VM
)

:: Step 3-2: Gracefully shut down the VM
:GRACEFUL_SHUTDOWN
echo Attempting to gracefully shut down %VM_NAME%...
vmrun -T ws stop "%VM_PATH%" soft
timeout /t 10 /nobreak >nul

:: Check if VM stopped
set "VM_RUNNING="
for /f %%i in ('vmrun list ^| find /i "%VM_NAME%"') do set "VM_RUNNING=true"

if not defined VM_RUNNING (
    echo VM has shut down successfully.

    if /i "%VM_ACTION%"=="EXIT" (
        timeout /t 3 /nobreak >nul
        exit
    ) else (
        goto START_VM
    )
) else (
    echo VM did not shut down via soft command. Forcing power off...
    goto FORCE_SHUTDOWN
)

:: Step 3-3: Force shutdown
:FORCE_SHUTDOWN
echo Forcing power off for %VM_NAME%...
vmrun -T ws stop "%VM_PATH%" hard
timeout /t 5 /nobreak >nul
echo VM has been forcibly powered off.

if /i "%VM_ACTION%"=="EXIT" (
    timeout /t 3 /nobreak >nul
    exit
) else (
    goto START_VM
)

:: Step 4: Start VM in no GUI mode
:START_VM
echo Starting VM %VM_NAME% in no GUI mode...
vmrun -T ws start "%VM_PATH%" nogui

:: Step 5: Ping in a loop until VM is reachable
echo Waiting for VM to become reachable at %VM_IP%...

for /f %%T in ('powershell -Command "[int][double]::Parse((Get-Date -UFormat %%s))"') do set START_TIME=%%T

:PING_LOOP
ping -n 1 %VM_IP% | find "Reply from %VM_IP%" >nul
if not errorlevel 1 (
    echo VM is online.
    timeout /t 3 /nobreak >nul
    goto SSH
)

for /f %%T in ('powershell -Command "[int][double]::Parse((Get-Date -UFormat %%s))"') do set END_TIME=%%T
set /a ELAPSED_TIME=END_TIME-START_TIME
echo Elapsed time: %ELAPSED_TIME% seconds

if %ELAPSED_TIME% GTR 120 (
    echo Timeout ^> 120 seconds.
    goto FORCE_SHUTDOWN
) else (
    timeout /t 3 /nobreak >nul
    goto PING_LOOP
)

:SSH
ssh %SSH_USER%@%VM_IP%
set "VM_ACTION=EXIT"
goto PROMPT
