: ==================================================================================================
: alias.bat — safe CMD autorun profile
: ==================================================================================================

@echo off

:: guard so tools can start clean shells (your other scripts set CMDAUTORUNSKIP=1)
if defined CMDAUTORUNSKIP goto :end

if "%PROMPT%"=="" prompt $P$G

if not defined WT_SESSION mode con: cols=300 lines=40

:: set "PATH=%PATH%;C:\Program Files\Notepad++"

doskey alias="C:\Program Files\Notepad++\notepad++.exe" "D:\Dropbox\Private\ConceptSphere\commands_and_scripts\.bat\alias.bat"
doskey ra="D:\Dropbox\Private\ConceptSphere\commands_and_scripts\.bat\alias.bat" ^>nul 2^>^&1
doskey npp="C:\Program Files\Notepad++\notepad++.exe" $*
doskey ls=dir /B $*
doskey dir=explorer.exe .
doskey startup_add=reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "$1" /t REG_SZ /d "\"$2\" $3 $4 $5 $6 $7 $8 $9" /f
doskey startup_del=reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "$1" /f

:: Python Virtual Environment
doskey mkvenv=py -m venv .venv
doskey actvenv=call .venv\Scripts\activate.bat
doskey mkreq=.venv\scripts\pip3 freeze ^> requirements.txt
doskey insreq=.venv\scripts\pip3 install -r requirements.txt
doskey pipins=.venv\scripts\pip3 install $*
doskey pyvenv=.venv\scripts\python.exe $*

:: ATLAS shortcuts

doskey simba=cd /d D:\Google_Drive\Git\atlas_gitlab\src\test_suites\simba
doskey ide=cd /d D:\Google_Drive\Git\atlas_ide

doskey gpt-10=title ATLAS IDE Terminal $T D:\Google_Drive\Git\atlas_ide\.venv\Scripts\python.exe ^
    -u D:\Google_Drive\Git\atlas_ide\src\driver.py --inline -ai gpt -w local -tn ntc-s3-tn-10

:end
