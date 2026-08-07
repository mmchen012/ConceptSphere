:: alias.bat — safe CMD autorun profile
@echo off

:: guard so tools can start clean shells (your other scripts set CMDAUTORUNSKIP=1)
if defined CMDAUTORUNSKIP goto :end

if "%PROMPT%"=="" prompt $P$G

if not defined WT_SESSION mode con: cols=300 lines=40

:: set "PATH=%PATH%;C:\Program Files\Notepad++"

doskey npp="C:\Program Files\Notepad++\notepad++.exe" $*
doskey ls=dir /B $*
doskey dir=explorer.exe .
doskey alias="C:\Program Files\Notepad++\notepad++.exe" "D:\Accton\ConceptSphere\commands_and_scripts\.bat\alias_accton.bat"
doskey ra="D:\Accton\ConceptSphere\commands_and_scripts\.bat\alias_accton.bat" ^>nul 2^>^&1

:: Python Virtual Environment
doskey mkvenv=py -m venv .venv
doskey actvenv=call .venv\Scripts\activate.bat
doskey mkreq=.venv\scripts\pip3 freeze ^> requirements.txt
doskey insreq=.venv\scripts\pip3 install -r requirements.txt
doskey pipins=.venv\scripts\pip3 install $*
doskey pyvenv=.venv\scripts\python.exe $*

:: ATLAS shortcuts
doskey atlas=cd /d D:\Accton\Git\atlas_gitlab\src
doskey simba=cd /d D:\Accton\Git\atlas_gitlab\src\test_suites\simba
doskey ide=cd /d D:\Accton\Git\atlas_ide
doskey acc-10=D:\Accton\ConceptSphere\commands_and_scripts\accton_aliases\acc-10.bat
doskey gpt-10=D:\Accton\ConceptSphere\commands_and_scripts\accton_aliases\gpt-10.bat

:end
