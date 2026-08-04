; ConceptSphereTools.nsi -- NSIS 3 installer for the ConceptSphere AHK v2 tools
;
; Build:  makensis ConceptSphereTools.nsi     (works on Linux and Windows)
;
; Two groups of checkboxes on the components page: which tools to install, and
; which to register as an elevated logon scheduled task. See README.md for why
; these cannot be real Windows services.

Unicode true
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "FileFunc.nsh"

; Payload location. build.ps1 stages outside Dropbox and passes the folder in
; as /DPAYLOAD=<path>; File directives resolve at COMPILE time, so the script
; cannot find the staging folder by itself. The fallback keeps a bare
; "makensis ConceptSphereTools.nsi" working against a local payload\ folder.
!ifndef PAYLOAD
  !define PAYLOAD "payload"
!endif

!define APPNAME    "ConceptSphere Tools"
!define APPVERSION "2.0"
!define PUBLISHER  "ConceptSphere"
!define ADDONFILE  "ConceptSphereTools-1.0.0.nvda-addon"
!define REGKEY     "Software\Microsoft\Windows\CurrentVersion\Uninstall\ConceptSphereTools"

Name "${APPNAME}"
OutFile "Output\ConceptSphere-Setup-${APPVERSION}.exe"
InstallDir "$PROGRAMFILES64\ConceptSphere"
InstallDirRegKey HKLM "Software\ConceptSphere" "InstallDir"
RequestExecutionLevel admin   ; Program Files + scheduled tasks
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "2.0.0.0"
VIAddVersionKey "ProductName"     "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME} installer"
VIAddVersionKey "FileVersion"     "${APPVERSION}"
VIAddVersionKey "ProductVersion"  "${APPVERSION}"
VIAddVersionKey "CompanyName"     "${PUBLISHER}"
VIAddVersionKey "LegalCopyright"  "${PUBLISHER}"

!define MUI_ABORTWARNING
!define MUI_ICON   "ConceptSphere.ico"
!define MUI_UNICON "ConceptSphere.ico"
!define MUI_COMPONENTSPAGE_SMALLDESC
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; =============================================================================
;  helpers
; =============================================================================

!macro RunPS Params
  ; 64-bit PowerShell: without this a 32-bit installer gets the SysWOW64 copy.
  ${DisableX64FSRedirection}
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass ${Params}'
  ${EnableX64FSRedirection}
!macroend

!macro StopTool TaskName ExeName
  ${DisableX64FSRedirection}
  !if "${TaskName}" != ""
    nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /End /TN "${TaskName}"'
    Pop $0
  !endif
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /IM "${ExeName}"'
  Pop $0
  ${EnableX64FSRedirection}
!macroend

; Every tool is stopped before any file is copied. A running copy is elevated
; (it comes from its logon task), so it holds its exe open and cannot be
; replaced or reloaded from a normal process. The watchdog goes first, or it
; restarts EnhancedStartMenu in the middle of the install.
!macro StopEverything
  DetailPrint "Stopping any running ConceptSphere tools..."
  ; The watchdog goes first and is now the only one that MUST: it restarts every
  ; other component, so killing anything else while it is alive just gets that
  ; component started again underneath the install.
  !insertmacro StopTool "ConceptSphere Watchdog" "ConceptSphereWatchdog.exe"
  !insertmacro StopTool "Start Menu Watchdog" "StartMenuWatchdog.exe"   ; superseded
  !insertmacro StopTool "Enhanced Start Menu" "EnhancedStartMenu.exe"
  !insertmacro StopTool "MiniTray"            "MiniTray.exe"
  !insertmacro StopTool "Console Select All"  "ConsoleSelectAll.exe"
  !insertmacro StopTool ""                    "DesktopFocus.exe"
  Sleep 500
!macroend

!macro RegisterTask TaskName ExeName Delay
  DetailPrint "Registering logon task: ${TaskName}"
  ${IfNot} ${FileExists} "$INSTDIR\install\Register-ConceptSphereTask.ps1"
    DetailPrint "  ERROR: the task helper is missing from $INSTDIR\install -- cannot register."
  ${Else}
    !insertmacro RunPS '-File "$INSTDIR\install\Register-ConceptSphereTask.ps1" -TaskName "${TaskName}" -Exe "$INSTDIR\${ExeName}" -Delay ${Delay}'
    Pop $0
    ${If} $0 != 0
      DetailPrint "  WARNING: registration returned $0 -- see %TEMP%\ConceptSphere-task-register.log"
    ${EndIf}
  ${EndIf}
!macroend

!macro RunTaskNow TaskName
  ${DisableX64FSRedirection}
  nsExec::ExecToLog '"$SYSDIR\schtasks.exe" /Run /TN "${TaskName}"'
  Pop $0
  ${EnableX64FSRedirection}
!macroend

; =============================================================================
;  sections -- executed in the order they appear
; =============================================================================

Section "-Prepare" SEC_PREP
  SetRegView 64
  InitPluginsDir
  ; The sweep runs before $INSTDIR is populated, so it goes to the temp dir.
  File "/oname=$PLUGINSDIR\Remove-ConceptSphereTasks.ps1" "install\Remove-ConceptSphereTasks.ps1"

  ; The task helper MUST land here, not in -Post: sections run in the order
  ; they are declared, and the "Run at logon" sections below invoke this script
  ; by path. Installing it later meant powershell -File pointed at a file that
  ; did not exist yet -- which exits 1 without writing a log, and registered
  ; nothing. (Inno hid this: there, [Files] always precedes [Run].)
  SetOutPath "$INSTDIR\install"
  File "install\Register-ConceptSphereTask.ps1"
  File "install\Remove-ConceptSphereTasks.ps1"
  SetOutPath "$INSTDIR"

  !insertmacro StopEverything
SectionEnd

Section "Remove existing scheduled tasks (clean install)" SEC_CLEAN
  DetailPrint "Sweeping up old ConceptSphere scheduled tasks..."
  ; Matches on each task's ACTION, so tasks pointing at the old Dropbox copies
  ; are found whatever they were named. Logs to %TEMP%.
  !insertmacro RunPS '-File "$PLUGINSDIR\Remove-ConceptSphereTasks.ps1"'
  Pop $0
SectionEnd

SectionGroup /e "Tools" SEC_GRP_TOOLS

  Section "MiniTray" SEC_MINITRAY
    SetOutPath "$INSTDIR"
    File "${PAYLOAD}\MiniTray.exe"
    File "${PAYLOAD}\MiniTray.ico"
    File "${PAYLOAD}\nvdaControllerClient64.dll"
    ; Settings live in the profile (MiniTray reads %APPDATA%\MiniTray\MiniTray.ini),
    ; because only an elevated instance could write under Program Files -- and a
    ; 64-bit exe gets no UAC file virtualisation to fall back on. Seeded here so
    ; the existing rule set carries over; never overwritten.
    SetOutPath "$APPDATA\MiniTray"
    SetOverwrite off
    File "${PAYLOAD}\MiniTray.ini"
    SetOverwrite on
    SetOutPath "$INSTDIR"
    CreateShortcut "$SMPROGRAMS\ConceptSphere\MiniTray.lnk" "$INSTDIR\MiniTray.exe"
  SectionEnd

  Section "EnhancedStartMenu" SEC_ESM
    SetOutPath "$INSTDIR"
    File "${PAYLOAD}\EnhancedStartMenu.exe"
    CreateShortcut "$SMPROGRAMS\ConceptSphere\EnhancedStartMenu.lnk" "$INSTDIR\EnhancedStartMenu.exe"
  SectionEnd

  Section "ConceptSphereWatchdog" SEC_WATCHDOG
    SetOutPath "$INSTDIR"
    File "${PAYLOAD}\ConceptSphereWatchdog.exe"
    ; It speaks and brailles through NVDA, so it needs the controller client
    ; even when neither MiniTray nor ConsoleSelectAll is selected.
    File "${PAYLOAD}\nvdaControllerClient64.dll"
  SectionEnd

  Section "ConsoleSelectAll" SEC_CONSOLE
    SetOutPath "$INSTDIR"
    File "${PAYLOAD}\ConsoleSelectAll.exe"
    File "${PAYLOAD}\nvdaControllerClient64.dll"
    CreateShortcut "$SMPROGRAMS\ConceptSphere\ConsoleSelectAll.lnk" "$INSTDIR\ConsoleSelectAll.exe"
  SectionEnd

  Section "DesktopFocus" SEC_DESKTOP
    SetOutPath "$INSTDIR"
    File "${PAYLOAD}\DesktopFocus.exe"
    CreateShortcut "$SMPROGRAMS\ConceptSphere\DesktopFocus.lnk" "$INSTDIR\DesktopFocus.exe"
  SectionEnd

  Section "NVDA add-on" SEC_NVDA
    ; Packaged as a real add-on rather than loose scratchpad files: no
    ; "enable custom code" tick required, and it survives NVDA updates.
    SetOutPath "$INSTDIR\nvda"
    File "${PAYLOAD}\nvda\${ADDONFILE}"
    File "${PAYLOAD}\nvda\*.py"
    SetOutPath "$INSTDIR"
  SectionEnd

  Section /o "Source scripts" SEC_SRC
    SetOutPath "$INSTDIR\src"
    File "${PAYLOAD}\*.ahk"
    SetOutPath "$INSTDIR\src\lib"
    File "${PAYLOAD}\lib\*.ahk"
  SectionEnd

SectionGroupEnd

SectionGroup /e "Run at logon (elevated scheduled task)" SEC_GRP_TASKS

  Section "MiniTray" SEC_T_MINITRAY
    ${If} ${FileExists} "$INSTDIR\MiniTray.exe"
      ; 20 s: the shell's notification area has to exist before the tray icon.
      !insertmacro RegisterTask "MiniTray" "MiniTray.exe" 20
    ${Else}
      DetailPrint "Skipping MiniTray task -- MiniTray was not installed."
    ${EndIf}
  SectionEnd

  Section "EnhancedStartMenu" SEC_T_ESM
    ${If} ${FileExists} "$INSTDIR\EnhancedStartMenu.exe"
      ; No delay: it needs to be live before the first Win press.
      !insertmacro RegisterTask "Enhanced Start Menu" "EnhancedStartMenu.exe" 0
    ${Else}
      DetailPrint "Skipping Enhanced Start Menu task -- EnhancedStartMenu was not installed."
    ${EndIf}
  SectionEnd

  Section "ConceptSphereWatchdog" SEC_T_WATCHDOG
    ${If} ${FileExists} "$INSTDIR\ConceptSphereWatchdog.exe"
      ; 10 s only: the script already holds off its first round of pings for
      ; STARTUP_MS (20 s), so the old 45 s just delayed cover for no gain.
      !insertmacro RegisterTask "ConceptSphere Watchdog" "ConceptSphereWatchdog.exe" 10
    ${Else}
      DetailPrint "Skipping the watchdog task -- ConceptSphereWatchdog was not installed."
    ${EndIf}
  SectionEnd

  Section "ConsoleSelectAll" SEC_T_CONSOLE
    ${If} ${FileExists} "$INSTDIR\ConsoleSelectAll.exe"
      !insertmacro RegisterTask "Console Select All" "ConsoleSelectAll.exe" 0
    ${Else}
      DetailPrint "Skipping Console Select All task -- ConsoleSelectAll was not installed."
    ${EndIf}
  SectionEnd

  Section "Start them now (instead of at next logon)" SEC_T_STARTNOW
    ; Started through the task, so each process gets the elevation and user
    ; context it will have at logon -- not the installer's.
    ${If} ${SectionIsSelected} ${SEC_T_MINITRAY}
      !insertmacro RunTaskNow "MiniTray"
    ${EndIf}
    ${If} ${SectionIsSelected} ${SEC_T_ESM}
      !insertmacro RunTaskNow "Enhanced Start Menu"
    ${EndIf}
    ${If} ${SectionIsSelected} ${SEC_T_WATCHDOG}
      !insertmacro RunTaskNow "ConceptSphere Watchdog"
    ${EndIf}
    ${If} ${SectionIsSelected} ${SEC_T_CONSOLE}
      !insertmacro RunTaskNow "Console Select All"
    ${EndIf}
  SectionEnd

SectionGroupEnd

Section "Hand the NVDA add-on to NVDA now" SEC_NVDA_NOW
  ${If} ${SectionIsSelected} ${SEC_NVDA}
    ${If} ${FileExists} "$INSTDIR\nvda\${ADDONFILE}"
      DetailPrint "Opening the add-on in NVDA..."
      ; Through explorer.exe on purpose: the shell is already running as you at
      ; normal integrity, so the file lands in your running NVDA instead of
      ; starting a second, elevated copy of it.
      Exec '"$WINDIR\explorer.exe" "$INSTDIR\nvda\${ADDONFILE}"'
      DetailPrint "  NVDA should ask whether to install it, then offer to restart."
    ${Else}
      DetailPrint "  ERROR: the add-on package is missing from $INSTDIR\nvda."
    ${EndIf}
  ${Else}
    DetailPrint "Skipping: the NVDA add-on component was not selected."
  ${EndIf}
SectionEnd

Section "-Post" SEC_POST
  ; (the install\ helpers were placed in -Prepare, before anything ran them)
  CreateDirectory "$SMPROGRAMS\ConceptSphere"
  SetOutPath "$INSTDIR"
  File "ConceptSphere.ico"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateShortcut "$SMPROGRAMS\ConceptSphere\Uninstall ${APPNAME}.lnk" "$INSTDIR\uninstall.exe" "" "$INSTDIR\ConceptSphere.ico" 0

  SetRegView 64
  WriteRegStr HKLM "Software\ConceptSphere" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${REGKEY}" "DisplayName"     "${APPNAME}"
  WriteRegStr HKLM "${REGKEY}" "DisplayVersion"  "${APPVERSION}"
  WriteRegStr HKLM "${REGKEY}" "Publisher"       "${PUBLISHER}"
  WriteRegStr HKLM "${REGKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${REGKEY}" "DisplayIcon"     "$INSTDIR\ConceptSphere.ico"
  WriteRegStr HKLM "${REGKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${REGKEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${REGKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${REGKEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${REGKEY}" "EstimatedSize" "$0"
SectionEnd

; --- component descriptions --------------------------------------------------
LangString DESC_CLEAN      ${LANG_ENGLISH} "Find and delete every existing scheduled task that launches one of these tools, from any path and under any name. Recommended: a leftover task starts a second copy that fights this one for the same hotkeys."
LangString DESC_MINITRAY   ${LANG_ENGLISH} "Hide windows to the tray with Shift+Esc, plus the window sizing rules. Settings go to %APPDATA%\MiniTray."
LangString DESC_ESM        ${LANG_ENGLISH} "Start menu keyboard navigation: Escape to close, Tab into the app list, type-ahead."
LangString DESC_WATCHDOG   ${LANG_ENGLISH} "One process watching every resident component -- EnhancedStartMenu, ConsoleSelectAll and MiniTray -- and restarting any that wedges or disappears. Replaces StartMenuWatchdog. Ctrl+Alt+Shift+W for status, Ctrl+Alt+Shift+P to pause before you recompile anything."
LangString DESC_CONSOLE    ${LANG_ENGLISH} "Ctrl+Shift+A selects and copies the whole console buffer, announced through NVDA."
LangString DESC_DESKTOP    ${LANG_ENGLISH} "Opens the Desktop folder in Explorer with the item list already focused. Runs once and exits, so it gets no logon task."
LangString DESC_NVDA      ${LANG_ENGLISH} "NVDA add-on with three global plugins: minitrayQuiet (MiniTray's quiet windows), quietFocusAncestry (drops the window/document announcements on focus change, NVDA+Shift+Q), startMenuContextMenuFix (stops 'context menu list' repeating in the Win11 Start context menu). A real add-on, so no Developer Scratchpad tick is needed."
LangString DESC_NVDA_NOW  ${LANG_ENGLISH} "Open the packaged add-on in your running NVDA so it can install it. NVDA asks you to confirm, then offers to restart. Leave this off if you would rather install it yourself later from $INSTDIR\nvda."
LangString DESC_SRC        ${LANG_ENGLISH} "The .ahk sources and Lib\UIA.ahk, for rebuilding. Not needed at runtime -- #include <UIA> is resolved at compile time."
LangString DESC_GRP_TASKS  ${LANG_ENGLISH} "These are interactive apps, so they cannot be Windows services (session 0 has no desktop). Each box registers a per-user logon task with RunLevel Highest instead."
LangString DESC_STARTNOW   ${LANG_ENGLISH} "Run each newly registered task immediately, so you do not have to log out and back in."

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_CLEAN}       $(DESC_CLEAN)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_MINITRAY}    $(DESC_MINITRAY)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_ESM}         $(DESC_ESM)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_WATCHDOG}    $(DESC_WATCHDOG)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_CONSOLE}     $(DESC_CONSOLE)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_DESKTOP}     $(DESC_DESKTOP)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_NVDA}        $(DESC_NVDA)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_NVDA_NOW}    $(DESC_NVDA_NOW)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_SRC}         $(DESC_SRC)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_GRP_TASKS}   $(DESC_GRP_TASKS)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_T_STARTNOW}  $(DESC_STARTNOW)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Function .onInit
  SetRegView 64
FunctionEnd

; =============================================================================
;  uninstall
; =============================================================================

Section "Uninstall"
  SetRegView 64

  ; Unregister first, while the helper script is still on disk.
  !insertmacro RunPS '-File "$INSTDIR\install\Register-ConceptSphereTask.ps1" -Remove -TaskName "ConceptSphere Watchdog" -Exe "$INSTDIR\ConceptSphereWatchdog.exe"'
  Pop $0
  ; Left behind by an install from before the watchdogs were merged.
  !insertmacro RunPS '-File "$INSTDIR\install\Register-ConceptSphereTask.ps1" -Remove -TaskName "Start Menu Watchdog" -Exe "$INSTDIR\StartMenuWatchdog.exe"'
  Pop $0
  !insertmacro RunPS '-File "$INSTDIR\install\Register-ConceptSphereTask.ps1" -Remove -TaskName "Enhanced Start Menu" -Exe "$INSTDIR\EnhancedStartMenu.exe"'
  Pop $0
  !insertmacro RunPS '-File "$INSTDIR\install\Register-ConceptSphereTask.ps1" -Remove -TaskName "MiniTray" -Exe "$INSTDIR\MiniTray.exe"'
  Pop $0
  !insertmacro RunPS '-File "$INSTDIR\install\Register-ConceptSphereTask.ps1" -Remove -TaskName "Console Select All" -Exe "$INSTDIR\ConsoleSelectAll.exe"'
  Pop $0

  !insertmacro StopEverything

  Delete "$INSTDIR\MiniTray.exe"
  Delete "$INSTDIR\MiniTray.ico"
  Delete "$INSTDIR\ConceptSphere.ico"
  Delete "$INSTDIR\EnhancedStartMenu.exe"
  Delete "$INSTDIR\ConceptSphereWatchdog.exe"
  Delete "$INSTDIR\StartMenuWatchdog.exe"      ; pre-merge build, if present
  Delete "$INSTDIR\ConsoleSelectAll.exe"
  Delete "$INSTDIR\DesktopFocus.exe"
  Delete "$INSTDIR\nvdaControllerClient64.dll"
  Delete "$INSTDIR\install\Register-ConceptSphereTask.ps1"
  Delete "$INSTDIR\install\Remove-ConceptSphereTasks.ps1"
  RMDir  "$INSTDIR\install"
  Delete "$INSTDIR\nvda\*.nvda-addon"
  Delete "$INSTDIR\nvda\*.py"
  RMDir  "$INSTDIR\nvda"
  Delete "$INSTDIR\src\lib\*.ahk"
  RMDir  "$INSTDIR\src\lib"
  Delete "$INSTDIR\src\*.ahk"
  RMDir  "$INSTDIR\src"
  Delete "$INSTDIR\uninstall.exe"
  RMDir  "$INSTDIR"

  Delete "$SMPROGRAMS\ConceptSphere\*.lnk"
  RMDir  "$SMPROGRAMS\ConceptSphere"

  DeleteRegKey HKLM "${REGKEY}"
  DeleteRegKey HKLM "Software\ConceptSphere"

  DetailPrint "If the NVDA add-on was installed, remove it in NVDA: Tools > Add-on store > Installed add-ons."

  ; %APPDATA%\MiniTray\MiniTray.ini is deliberately left alone -- losing the
  ; window rules would be worse than leaving a small file behind.
SectionEnd
