goto :START

tasklist /NH /FI "imagename eq dropbox.exe" 2>nul |find /i "dropbox.exe">nul

If not errorlevel 1 (
    SET dropbox_running=true
    taskkill /im dropbox.exe /f
) else (
    SET dropbox_running=false
)

tasklist /NH /FI "imagename eq teams.exe" 2>nul |find /i "teams.exe">nul

If not errorlevel 1 (
    SET teams_running=true
    taskkill /im teams.exe /f
) else (
    SET teams_running=false
)

tasklist /NH /FI "imagename eq skype.exe" 2>nul |find /i "skype.exe">nul

If not errorlevel 1 (
    SET skype_running=true
    taskkill /im skype.exe /f
) else (
    SET skype_running=false
)

tasklist /NH /FI "imagename eq thunderbird.exe" 2>nul |find /i "thunderbird.exe">nul

If not errorlevel 1 (
    SET thunderbird_running=true
::    taskkill /im thunderbird.exe /f
) else (
    SET thunderbird_running=false
)

:START
taskkill /im explorer.exe /f
start explorer.exe
goto :END

if %dropbox_running%==true (
    start "" "C:\Program Files (x86)\Dropbox\Client\Dropbox.exe"
)

if %teams_running%==true (
    start "" C:\Users\michael\AppData\Local\Microsoft\Teams\Update.exe  --processStart "Teams.exe" --process-start-args "--system-initiated"
)

if %skype_running%==true (
    start "" "C:\Users\michael\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Skype"
)

if %thunderbird_running%==true (
    start "" "D:\Dropbox\Private\ConceptSphere\commands_and_scripts\run_thunderbird_minimized"
)

:END
exit
