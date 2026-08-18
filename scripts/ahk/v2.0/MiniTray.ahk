#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon                     ; icon appears only while windows are hidden

; =============================================================================
;  MiniTray.ahk  -  v2.37 (quiet empty-menu/save/final-restore tray reflow)
;
;  Merged window manager: rule-driven auto-sizing (was WindowSizer v1.1) plus
;  hide-to-tray (was MiniTrayUtil). One process, one WinEvent dispatcher, one
;  INI, one GUI.
;
;  HOTKEYS
;    Ctrl+Alt+5        show the main window
;    Ctrl+Alt+4        create/edit a rule for the active window
;    Ctrl+Alt+Z        apply the matching rule to the active window
;    Ctrl+Alt+M        open the tray menu at the cursor
;    Shift+Esc         hide the active window to the tray
;    Ctrl+Shift+L      restore every hidden window
;    Shift+Alt+Esc     hide all open windows in Alt+Tab order
;    Ctrl+Alt+H        announce what is currently hidden
;    Ctrl+Alt+Shift+Q  quit
;
;  INI (%APPDATA%\MiniTray\MiniTray.ini)
;    Kept in the user profile, not beside the exe: under Program Files only
;    an elevated instance could write it. A MiniTray.ini found beside the
;    script is migrated once, then renamed .migrated so it cannot shadow.
;    [__MiniTray__]     SoundMode=Beep|Wav|None, BeepFreq, BeepDur, WavPath,
;                       HideIconWhenEmpty=0|1 (default 0 - see BuildTrayMenu),
;                       Speak=0|1, ConfirmCloseAll=0|1, AutoApply=0|1,
;                       QuietPlugin=0|1 (default 1; needs the minitrayQuiet
;                         NVDA add-on -- set 0 where it is not installed)
;                       ExplorerSafeHide is retained for INI compatibility.
;                         Explorer folder windows are now hidden only when
;                         hosted outside the desktop-shell Explorer process.
;    [__Hidden__]       crash-recovery record of hidden windows (managed)
;    [<rule name>]      Compare=Class|Title, Class, Title,
;                       TitleMatch=Exact|Contains|Wildcard|RegEx,
;                       W, H, X, Y,
;                       Bounds=Work|Monitor|Virtual   (default Work)
;                       HideOnMinimize=0|1            (default 0)
;                       Enabled=0|1                   (default 1)
; =============================================================================

DetectHiddenWindows true
SetTitleMatchMode 2

; --- change APP_NAME to rename the tool; it is also the tray tooltip, and the
;     tooltip is the only text a screen reader announces on the icon. ---------
global APP_NAME  := "MiniTray"
global INI_DIR   := A_AppData "\" APP_NAME          ; per-user, always writable
global INI_FILE  := INI_DIR "\MiniTray.ini"
global OLD_INI   := A_ScriptDir "\MiniTray.ini"     ; pre-move location, migrated once
global ICON_FILE := A_ScriptDir "\MiniTray.ico"     ; read-only resource, stays by the exe
global LOG_FILE  := A_Temp "\MiniTray.log"
global LOG_MAX_BYTES := 5 * 1024 * 1024
global CFG_SEC   := "__MiniTray__"
global OLD_CFG   := "__WindowSizer__"   ; pre-rename config section, migrated on startup
global HID_SEC   := "__Hidden__"
global MAX_LABEL := 60
global NATIVE_RESTORE_HANDOFF_SETTLE := 25 ; let NVDA consume MTQUIET:0 / MTNATIVERESTORE
global NVDA_MODE_GUARD_SETTLE := 8     ; let NVDA disable automatic browse/focus-mode switching before a hide moves focus
global NVDA_MODE_GUARD_TIMEOUT := 1800 ; failsafe; explicit release normally happens much sooner
global SPEECH_SETTLE := 350       ; ms to let focus changes and notification-area
                                  ;   reflow finish before we speak. Anything that
                                  ;   talks AFTER us cancels us, so we go last.
global g_SoonSay := ""            ; text queued by SaySoon
global QUIET_CHUNK   := 1200      ; ms asked for per sentinel. The plugin caps
                                  ;   any single window at 1500 ms, so this must
                                  ;   stay under that or the request is clamped.
global QUIET_REFRESH := 900       ; ms between re-sends while still quiet. MUST
                                  ;   be < QUIET_CHUNK, or the window lapses
                                  ;   between refreshes and chatter gets out.
global QUIET_MAX     := 4000      ; our own hard stop, so a lost flush cannot
                                  ;   keep re-arming the window forever
global QUIET_FINAL_TAIL := 700     ; keep dropping focus chatter after the privileged
                                  ;   "... hidden" line has started speaking
global g_QuietUntil  := 0         ; tick count to stay quiet until, 0 = not quiet
global ANNOUNCE_AFTER_HIDE := 250 ; ms after the icon is removed before we speak,
                                  ;   so our line lands after the shell's
                                  ;   notification-area re-read, not under it
global g_PendingSay := ""         ; queued line ("" = cancel only)
global g_PendingArmed := false    ; whether anything is queued at all
global g_StartedAt := A_Now       ; so the diagnostic can prove which build is live
global ICON_HIDE_RETRY   := 700 ; ms between re-checks while the tray still has focus
global ICON_HIDE_RETRIES := 30  ; give up re-checking after this many (~21s), in
                                ;   case the focus test ever misreads and would
                                ;   otherwise strand the icon on screen forever
global ICON_HIDE_DELAY := 900  ; ms to wait before removing the tray icon, so the
                               ;   notification area does not reflow under focus

; Alt+Tab first focuses the task-switcher selection, then commits the real
; foreground window when Alt is released. Applying a geometry rule inside that
; transition can provoke a second foreground/title announcement. Let the new
; foreground settle before MiniTray moves it.
global FOREGROUND_RULE_SETTLE := 2500

;@Ahk2Exe-SetMainIcon MiniTray.ico

; --- WinEvent constants ------------------------------------------------------
global EV_FOREGROUND    := 0x0003
global EV_MOVESIZEEND   := 0x000B
global EV_MINIMIZESTART := 0x0016
global EV_NAMECHANGE    := 0x800C

; Private message posted by the NVDA plugin after the explicit app/title
; announcement reaches the end of the speech queue. Only then do we put the
; keyboard focus back into the control where the user left it.
global WM_MT_RESTORE_FOCUS := 0x8154
global WM_MT_HIDE_ICON := 0x8155
global RESTORE_FOCUS_PRIME_SETTLE := 90
global RESTORE_FOCUS_NATIVE_DELAY := 100
global RESTORE_FOCUS_VERIFY_DELAY := 120
global RESTORE_FOCUS_LINE_DELAY := 220 ; let the final ControlFocus and NVDA caret object settle before reading the line
global RESTORE_FOCUS_TIMEOUT := 8000

; --- state -------------------------------------------------------------------
global g_Rules    := []         ; parsed rule cache
global g_Stamp    := ""         ; INI mtime|size, to know when to reparse
global g_Cfg      := Map()      ; parsed [__MiniTray__]
global g_Hidden   := []         ; [{hwnd, pid, proc, title, how}] oldest first
global g_NvdaModeGuardSerial := 1
global g_PopupGui  := 0           ; the tray popup, replacing AHK's tray menu
global g_PopupLabel := 0          ; accessible label for the current list level
global g_PopupLB    := 0
global g_PopupItems := []         ; row index -> {kind, proc, hwnd}
global g_PopupProc  := ""         ; "" = apps, "__settings__" = settings, else app submenu
global g_PopupMode  := "browse"
global g_PopupContextHwnd := 0     ; target window while showing Restore/Close context
global g_PopupContextParent := "" ; "" = top level, otherwise owning app submenu
global g_PopupOpening := false    ; opening announcement still pending
global g_LastUserForegroundHwnd := 0
global g_LastUserFocusCtrl := 0
global g_PopupReturnHwnd := 0
global g_PopupReturnCtrl := 0
global POPUP_OPEN_SETTLE := 0     ; announce immediately after the popup receives focus
global POPUP_OPEN_TAIL := 1000    ; protect the complete opening phrase from late
                                  ;   popup/list focus events and slow synth cancellation
global g_Queue    := []         ; WinEvent queue, drained off the hook thread
global g_Seen     := Map()      ; hwnd -> last auto-apply tick (per-window debounce)
global g_Hooks    := []
global g_CbProc   := 0
global g_ForegroundRuleSerial := 0
global g_ForegroundRuleHwnd := 0
global g_ForegroundRuleUntil := 0
global g_Restoring := false     ; suppress auto-apply while we un-hide things
global g_Transitioning := Map()  ; hwnd -> start tick; blocks re-entrant hide/apply
global g_ShellPid := 0           ; invalidates cached shell COM after Explorer restarts
global g_DeferredFocus := Map()  ; token -> {hwnd, pid, ctrl, fallback}
global g_NextFocusToken := 1
global g_FocusBridgeGui := 0      ; off-screen ToolWindow used to force a real
global g_FocusBridgeEdit := 0     ; cross-window keyboard-focus transition
global g_SoonFocus := 0          ; focus record paired with g_SoonSay
global g_PendingFocus := 0       ; focus record paired with g_PendingSay

global g_EditSec  := ""        ; section being edited ("" = not yet written)
global g_EditNew  := false     ; true while the dialog is a Create, not an Edit
global g_EditHwnd := 0         ; window the dialog was invoked from
global g_EditClass := ""       ; both match values live here while the dialog is
global g_EditTitle := ""       ;   open; only one is shown in the shared box
global g_EditMode  := ""       ; which one the box currently holds: class|title
global g_SyncGuard := false    ; stops the edit/slider pair echoing each other

global g_MainGui  := 0
global g_MainTab  := 0          ; Rules / Hidden windows / Options tab control
global g_EditGui  := 0
global g_LVOpen   := 0
global g_LVRules  := 0
global g_LVHidden := 0

; =============================================================================
;  STARTUP
; =============================================================================
InitDebugLog()
DebugLog("Starting MiniTray: pid=" ProcessExist() " compiled=" (A_IsCompiled ? "yes" : "no")
    " elevated=" (A_IsAdmin ? "yes" : "no") " script=" A_ScriptFullPath
    " args=" (A_Args.Length ? Join(A_Args, " | ") : "(none)"), "INFO")
MigrateIniLocation()
EnsureIni()
MigrateOldSection()
LoadConfig()
LoadRules()

; Compiled, Ahk2Exe embeds MiniTray.ico as the exe's main icon and the tray
; picks it up automatically - so never fall back to shell32 in that case, or we
; would replace a good embedded icon with a generic one.
if FileExist(ICON_FILE)
    TraySetIcon(ICON_FILE)
else if (!A_IsCompiled)
    TraySetIcon("shell32.dll", 44)
A_IconTip := APP_NAME           ; CONSTANT - never append counts or titles

; MiniTray owns its notification-area icon directly (see MTIcon_* at the end
; of this file). Normal hide/show uses NIM_MODIFY + NIS_HIDDEN, and shutdown
; deliberately does NOT send NIM_DELETE. The Explorer crash path reached
; NotificationAreaIconManager2::DeleteIcon -> NotificationAreaIcon2::Close, so
; this build never explicitly enters that path.
MTIcon_Init()

; AHK's own main window is normally hidden, but the shell can foreground and
; show it when hosting a tray menu. WS_EX_TOOLWINDOW keeps it out of Alt+Tab
; whatever happens; applied now, while it is still hidden, so it is in force
; before anything can show it.
MakeToolWindow(A_ScriptHwnd)
HideScriptEdit()

; AHK's own tray menu is never shown -- see the TRAY POPUP section for why.
A_TrayMenu.Delete()
OnMessage(0x404, TrayIconMsg)     ; AHK_NOTIFYICON: the shell's tray-icon click
OnMessage(WM_MT_HIDE_ICON, CompleteDeferredTrayIconHide)
OnMessage(0x0202, PopupListMouseUp) ; make ListBox rows activate like menu items
OnMessage(WM_MT_RESTORE_FOCUS, RestoreFocusAfterSpeechMessage)

AdoptOrphans()                  ; recover windows stranded by a previous crash
RefreshTray()
RefreshShellIdentity()
InstallHooks()
DebugLog("Startup complete: hidden=" g_Hidden.Length " rules=" g_Rules.Length
    " shellPid=" g_ShellPid " ini=" INI_FILE, "INFO")
SetTimer(Prune, 5000)
OnExit(HandleExit)

if (A_Args.Length >= 1 && IsShowArg(A_Args[1]))
    ShowMainGui()

; =============================================================================
;  HOTKEYS
; =============================================================================
^!5::ShowMainGui()
^!4::RuleFlowForActiveWindow()
^!z::ApplyRuleToActiveWindow()
^!m::BeginTrayPopupOpen()       ; reachable even when the icon is auto-hidden
^!h::AnnounceHidden()

#HotIf (IsObject(g_PopupGui) && WinActive("ahk_id " g_PopupGui.Hwnd))
Up::PopupMove(-1)
Down::PopupMove(1)
+Enter::PopupActivate(true)
+NumpadEnter::PopupActivate(true)
Enter::PopupActivate(false)
NumpadEnter::PopupActivate(false)
AppsKey::PopupOpenKeyboardContext()
+F10::PopupOpenKeyboardContext()
Right::PopupDrillIn()
Left::PopupBack()
Delete::PopupCloseSelected()
#HotIf

; When no ordinary Alt+Tab window exists, consume the gesture and leave the
; MiniTray popup focused. Hiding the popup before an empty native Alt+Tab leaves
; Windows with no destination and causes keyboard focus to disappear.
#HotIf (IsObject(g_PopupGui)
    && WinActive("ahk_id " g_PopupGui.Hwnd)
    && !PopupHasAltTabTarget())
!Tab::PopupAltTabNoTarget()
+!Tab::PopupAltTabNoTarget()
#HotIf

; Pass Alt+Tab through only when Windows has a real destination. The tilde
; preserves the native task-switch operation; +ToolWindow keeps MiniTray itself
; out of the Alt+Tab list.
#HotIf (IsObject(g_PopupGui)
    && WinActive("ahk_id " g_PopupGui.Hwnd)
    && PopupHasAltTabTarget())
~!Tab::PopupAltTabClose()
~+!Tab::PopupAltTabClose()
#HotIf
+Esc::HideActiveToTray()
^l::RestoreLast()
^+l::RestoreAll()
!+Esc::HideAllOpenWindows()
^!+q::QuitMiniTray()

IsShowArg(a) {
    a := StrLower(Trim(a))
    return (a = "--show" || a = "/show" || a = "-show" || a = "show")
}

; =============================================================================
;  FEEDBACK  (sound + optional NVDA speech)
; =============================================================================
; v1 recomputed the sound config from the INI on every single beep. Config is
; now parsed once in LoadConfig().
Feedback() {
    global g_Cfg
    mode := StrLower(g_Cfg.Get("SoundMode", "Wav"))
    if (mode = "none")
        return
    if (mode = "beep") {
        SoundBeep g_Cfg.Get("BeepFreq", 400), g_Cfg.Get("BeepDur", 40)
        return
    }
    wav := g_Cfg.Get("WavPath", "")
    if (wav != "" && FileExist(wav))
        SoundPlay(wav)                              ; non-blocking
    else
        SoundBeep g_Cfg.Get("BeepFreq", 400), g_Cfg.Get("BeepDur", 40)
}

Nope() {
    SoundBeep 750, 150
}

SpeakUnableToHideWindow(alreadyQuiet := false) {
    if !alreadyQuiet
        StartQuiet(900)
    SayQuietFinal("unable to hide window", 700)
}

; Speaks through NVDA when it is running and Speak=1; silently does nothing
; otherwise, so the script has no hard dependency on the controller client.
; Protected MiniTray status phrases are serialized by conceptSphereQuiet.
; Controller-level cancellation is avoided for those phrases because it cannot
; distinguish ordinary NVDA speech from a MiniTray result already in progress.
NvdaDllPath() => A_ScriptDir "\nvdaControllerClient64.dll"

Announce(text, cancel := true) {
    global g_Cfg
    static dll := 0
    if (g_Cfg.Get("Speak", "0") != "1")
        return
    ; Only a SUCCESSFUL handle is cached. The previous version cached the
    ; failure too, so one missing-DLL start meant silence for the whole session
    ; even after the file appeared.
    if (!dll)
        dll := DllCall("LoadLibrary", "Str", NvdaDllPath(), "Ptr")
    if (!dll)
        return
    if (DllCall("nvdaControllerClient64\nvdaController_testIfRunning", "UInt") != 0)
        return
    if (cancel)
        DllCall("nvdaControllerClient64\nvdaController_cancelSpeech", "UInt")
    if (text != "")                      ; empty text = cancel only, which cuts
        DllCall("nvdaControllerClient64" ;   the shell off without adding noise
              . "\nvdaController_speakText", "Str", text, "UInt")
}
SendPluginControl(text) {
    global g_Cfg
    if (g_Cfg.Get("QuietPlugin", "1") != "1")
        return false

    ; Control sentinels are protocol, not user-facing MiniTray status speech.
    ; Send them even when Speak=0 so the NVDA add-on can still distinguish a
    ; native restore handoff from its independent new-window/close logic.
    savedSpeak := g_Cfg.Get("Speak", "0")
    g_Cfg["Speak"] := "1"
    try {
        Announce(text, false)
        return true
    } finally {
        g_Cfg["Speak"] := savedSpeak
    }
}

SignalNativeNvdaRestore(e, spokenPrefix := "") {
    if !e
        return false

    payload := Chr(1) "MTNATIVERESTORE:" e.hwnd ":" e.pid
    if (spokenPrefix != "")
        payload .= ":" spokenPrefix
    payload .= Chr(1)
    return SendPluginControl(payload)
}

AnnounceHidden() {
    global g_Hidden
    if (g_Hidden.Length = 0) {
        Say("Nothing hidden")
        return
    }
    parts := []
    i := g_Hidden.Length
    while (i >= 1) {
        e := g_Hidden[i]
        parts.Push(e.proc " " e.title)
        i--
    }
    Say(g_Hidden.Length " hidden: " Join(parts, ", "))
}

; Announce() honours the Speak setting; Say() is for explicit user requests,
; where staying silent would look like the hotkey did nothing.
Say(text) {
    global g_Cfg
    saved := g_Cfg.Get("Speak", "0")
    g_Cfg["Speak"] := "1"
    Announce(text)
    g_Cfg["Speak"] := saved
    if (saved != "1") {
        ToolTip(text)
        SetTimer(ClearToolTip, -2500)
    }
}

ClearToolTip() {
    ToolTip()
}

JoinFrom(arr, start, sep) {
    out := "", i := start
    while (i <= arr.Length) {
        out .= (i > start ? sep : "") . arr[i]
        i++
    }
    return out
}

Join(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i > 1 ? sep : "") v
    return out
}


; =============================================================================
;  DEBUG LOGGING
; =============================================================================
; The active session is appended to %TEMP%\MiniTray.log. When the file exceeds
; 5 MB, the previous content is moved to MiniTray.log.1 before the new session
; starts. Logging is deliberately best-effort and never interrupts MiniTray.
InitDebugLog() {
    global LOG_FILE, LOG_MAX_BYTES
    try {
        if (FileExist(LOG_FILE) && FileGetSize(LOG_FILE) > LOG_MAX_BYTES) {
            backup := LOG_FILE ".1"
            try FileDelete(backup)
            FileMove(LOG_FILE, backup, 1)
        }
    }
    DebugLog("================ session start ================", "INFO")
}

DebugLog(message, level := "DEBUG") {
    global LOG_FILE
    try {
        stamp := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        line := stamp "." Format("{:03}", A_MSec) " [" level "] " message "`r`n"
        FileAppend(line, LOG_FILE, "UTF-8")
    }
}

DebugException(context, err) {
    details := context
    try details .= ": " err.Message
    try details .= " | what=" err.What
    try details .= " | line=" err.Line
    try details .= " | extra=" err.Extra
    DebugLog(details, "ERROR")
}

DebugWindow(hwnd) {
    if (!hwnd)
        return "hwnd=0"
    title := "", proc := "", pid := 0, cls := ""
    try title := WinGetTitle("ahk_id " hwnd)
    try proc := WinGetProcessName("ahk_id " hwnd)
    try pid := WinGetPID("ahk_id " hwnd)
    try cls := WinGetClass("ahk_id " hwnd)
    return "hwnd=" hwnd " pid=" pid " exe=" proc " class=" cls " title=" title
}

; =============================================================================
;  INI  -  parsed once into memory, reparsed only when the file changes
; =============================================================================
; v1 called GetIniSections() (a full line-by-line read) plus 2-4 IniRead calls
; per section on EVERY foreground and title-change event. Notepad++ fires a
; name-change on every dirty-flag flip, so typing meant rescanning the file
; several times a second. Now the whole file is parsed once, and only when its
; timestamp or size has moved.
IniStamp() {
    global INI_FILE
    if !FileExist(INI_FILE)
        return ""
    return FileGetTime(INI_FILE, "M") "|" FileGetSize(INI_FILE)
}

ParseIni() {
    global INI_FILE
    order := [], data := Map()
    data.CaseSense := false
    if !FileExist(INI_FILE)
        return { order: order, data: data }

    cur := ""
    for line in StrSplit(FileRead(INI_FILE, "UTF-8"), "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        if RegExMatch(line, "^\[([^\]]+)\]$", &m) {
            cur := Trim(m[1])
            if (cur != "" && !data.Has(cur)) {
                kv := Map()
                kv.CaseSense := false
                data[cur] := kv
                order.Push(cur)
            }
            continue
        }
        if (cur = "")
            continue
        if (p := InStr(line, "="))
            data[cur][Trim(SubStr(line, 1, p - 1))] := Trim(SubStr(line, p + 1))
    }
    return { order: order, data: data }
}

; The config section was called [__WindowSizer__] before the rename. Copy it
; across once and drop the old one, so an existing INI keeps its settings.
MigrateOldSection() {
    global INI_FILE, CFG_SEC, OLD_CFG
    if !FileExist(INI_FILE)
        return
    ini := ParseIni()
    if (!ini.data.Has(OLD_CFG) || ini.data.Has(CFG_SEC))
        return
    for k, v in ini.data[OLD_CFG]
        IniWrite(v, INI_FILE, CFG_SEC, k)
    try IniDelete(INI_FILE, OLD_CFG)
}

LoadConfig() {
    global g_Cfg, CFG_SEC
    ini := ParseIni()
    if ini.data.Has(CFG_SEC) {
        g_Cfg := ini.data[CFG_SEC]      ; ParseIni already made it case-insensitive
    } else {
        g_Cfg := Map()                  ; CaseSense is only assignable while empty
        g_Cfg.CaseSense := false
    }
    for k, v in Map("SoundMode","Wav", "BeepFreq","400", "BeepDur","40"
                  , "WavPath","C:\Windows\Media\Speech Misrecognition.wav"
                  , "Speak","0", "ConfirmCloseAll","1", "AutoApply","1"
                  , "HideIconWhenEmpty","0", "QuietPlugin","1"
                  , "ExplorerSafeHide","1")
        if !g_Cfg.Has(k)
            g_Cfg[k] := v
    DebugLog("Config loaded: Speak=" g_Cfg.Get("Speak", "0")
        " QuietPlugin=" g_Cfg.Get("QuietPlugin", "1")
        " AutoApply=" g_Cfg.Get("AutoApply", "1")
        " HideIconWhenEmpty=" g_Cfg.Get("HideIconWhenEmpty", "0"), "INFO")
}

LoadRules(force := false) {
    global g_Rules, g_Stamp, CFG_SEC, OLD_CFG, HID_SEC
    stamp := IniStamp()
    if (!force && stamp = g_Stamp && g_Rules.Length)
        return
    g_Stamp := stamp

    ini := ParseIni()
    rules := []
    for sec in ini.order {
        if (sec = CFG_SEC || sec = OLD_CFG || sec = HID_SEC)
            continue
        kv := ini.data[sec]
        rules.Push({ name  : sec
                   , cmp   : StrLower(kv.Get("Compare", "Class")) = "title" ? "title" : "class"
                   , cls   : Trim(kv.Get("Class", ""))
                   , title : Trim(kv.Get("Title", ""))
                   , match : StrLower(kv.Get("TitleMatch", "Exact"))
                   , w     : kv.Get("W", ""), h : kv.Get("H", "")
                   , x     : kv.Get("X", ""), y : kv.Get("Y", "")
                   , bounds: StrLower(kv.Get("Bounds", "work"))
                   , hom   : kv.Get("HideOnMinimize", "0") = "1"
                   , on    : kv.Get("Enabled", "1") != "0" })
    }
    g_Rules := rules
    DebugLog("Rules loaded: count=" g_Rules.Length " stamp=" g_Stamp, "INFO")
}

WriteRule(sec, r) {
    global INI_FILE
    IniWrite(r.cmp = "title" ? "Title" : "Class", INI_FILE, sec, "Compare")
    IniWrite(r.cls,    INI_FILE, sec, "Class")
    IniWrite(r.title,  INI_FILE, sec, "Title")
    IniWrite(r.match,  INI_FILE, sec, "TitleMatch")
    IniWrite(r.w,      INI_FILE, sec, "W")
    IniWrite(r.h,      INI_FILE, sec, "H")
    IniWrite(r.x,      INI_FILE, sec, "X")
    IniWrite(r.y,      INI_FILE, sec, "Y")
    IniWrite(r.bounds, INI_FILE, sec, "Bounds")
    IniWrite(r.hom ? "1" : "0", INI_FILE, sec, "HideOnMinimize")
    IniWrite(r.on  ? "1" : "0", INI_FILE, sec, "Enabled")
    LoadRules(true)
}

; Move a settings file left beside the script into the profile, once. Only
; when there is nothing in the profile yet -- the profile copy always wins,
; so a stale file beside an old exe can never resurrect old settings.
MigrateIniLocation() {
    global INI_FILE, INI_DIR, OLD_INI
    if (OLD_INI = INI_FILE) || FileExist(INI_FILE) || !FileExist(OLD_INI)
        return
    try {
        DirCreate(INI_DIR)
        FileCopy(OLD_INI, INI_FILE, false)
    } catch
        return                      ; profile unwritable: EnsureIni writes defaults
    ; Rename rather than delete, and never fail startup over it: under Program
    ; Files a non-elevated instance cannot touch the old file.
    try FileMove(OLD_INI, OLD_INI ".migrated", true)
}

EnsureIni() {
    global INI_FILE, INI_DIR, CFG_SEC
    try DirCreate(INI_DIR)
    if FileExist(INI_FILE)
        return
    ; Built by concatenation rather than a continuation section: inside a
    ; continuation section the text is literal, so CFG_SEC would not expand.
    nl  := "`r`n"
    txt := "; MiniTray.ini" nl nl
    txt .= "[" CFG_SEC "]" nl
    txt .= "; SoundMode: Beep, Wav or None" nl
    txt .= "SoundMode=Wav" nl
    txt .= "BeepFreq=400" nl
    txt .= "BeepDur=40" nl
    txt .= "WavPath=C:\Windows\Media\Speech Misrecognition.wav" nl
    txt .= "; Speak=1 routes confirmations through NVDA when it is running" nl
    txt .= "Speak=0" nl
    txt .= "; QuietPlugin=1 holds the floor via the minitrayQuiet NVDA add-on." nl
    txt .= "; Set 0 where the add-on is not installed, or the sentinel is read out." nl
    txt .= "QuietPlugin=1" nl
    txt .= "ConfirmCloseAll=1" nl
    txt .= "; AutoApply=1 enables automatic matching globally. Each rule's" nl
    txt .= "; Enabled value can independently opt that rule in or out." nl
    txt .= "AutoApply=1" nl
    txt .= "; Explorer windows require Folder Options > Launch folder windows" nl
    txt .= "; in a separate process. Shell-owned Explorer windows are refused." nl
    txt .= "ExplorerSafeHide=1" nl
    FileAppend(txt, INI_FILE, "UTF-8")
}

; =============================================================================
;  MATCHING  -  title rules first, then class rules (v1 semantics preserved)
; =============================================================================
FindRule(cls, title) {
    global g_Rules
    LoadRules()
    cls := Trim(cls), title := Trim(title)

    for r in g_Rules
        if (r.on && r.cmp = "title" && r.title != "" && TitleMatches(title, r))
            return r
    for r in g_Rules
        if (r.on && r.cmp = "class" && r.cls != "" && r.cls = cls)
            return r
    return 0
}

; Contains stayed a literal InStr, as in v1 - existing rules behave exactly as
; before. Wildcard and RegEx are new opt-ins.
TitleMatches(title, r) {
    switch r.match {
        case "contains": return InStr(title, r.title, false) > 0
        case "wildcard": return RegExMatch(title, "i)^" WildcardToRegEx(r.title) "$") > 0
        case "regex":
            try
                return RegExMatch(title, r.title) > 0
            catch
                return false
        default:         return (title = r.title)   ; = is case-insensitive
    }
}

WildcardToRegEx(pat) {
    out := ""
    for ch in StrSplit(pat) {
        if (ch = "*")
            out .= ".*"
        else if (ch = "?")
            out .= "."
        else
            out .= RegExReplace(ch, "([\\.^$|()\[\]{}+*?])", "\$1")
    }
    return out
}

; =============================================================================
;  BOUNDS  -  per-rule: work area, whole monitor, or the virtual desktop
; =============================================================================
; v1 always clamped to the monitor WORK AREA. That made the [Shell_TrayWnd]
; rule unappliable (the work area is the screen minus the taskbar, so a rule
; positioning the taskbar was clamped away from its own target) and silently
; capped the 4096-wide Notepad++ rule at one monitor.
GetBounds(hwnd, mode) {
    if (mode = "virtual") {
        vx := SysGet(76), vy := SysGet(77)
        return { l: vx, t: vy, r: vx + SysGet(78), b: vy + SysGet(79) }
    }
    hMon := hwnd ? DllCall("User32\MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr") : 0
    if (hMon) {
        mi := Buffer(40, 0)
        NumPut("UInt", 40, mi, 0)
        if DllCall("User32\GetMonitorInfo", "Ptr", hMon, "Ptr", mi, "Int") {
            off := (mode = "monitor") ? 4 : 20      ; rcMonitor : rcWork
            return { l: NumGet(mi, off,      "Int"), t: NumGet(mi, off +  4, "Int")
                   , r: NumGet(mi, off + 8,  "Int"), b: NumGet(mi, off + 12, "Int") }
        }
    }
    ; Fallback. v1 read SysGet 78/79 as right/bottom, but they are WIDTH and
    ; HEIGHT - wrong the moment a monitor sits left of or above the primary.
    vx := SysGet(76), vy := SysGet(77)
    return { l: vx, t: vy, r: vx + SysGet(78), b: vy + SysGet(79) }
}

ClampRect(&w, &h, &x, &y, hwnd, mode) {
    if !(IsInt(w) && IsInt(h) && IsInt(x) && IsInt(y))
        return false
    w += 0, h += 0, x += 0, y += 0
    if (w <= 0 || h <= 0)
        return false

    b := GetBounds(hwnd, mode)

    ; Rule coordinates are always non-negative. A monitor that lies entirely
    ; left of or above the primary origin has no usable non-negative area for
    ; this rule, so decline to move the window rather than writing a negative
    ; coordinate back into the rule or silently placing it off-screen.
    left := Max(0, b.l), top := Max(0, b.t)
    bw := b.r - left, bh := b.b - top
    if (bw <= 0 || bh <= 0)
        return false

    if (w > bw)
        w := bw
    if (h > bh)
        h := bh

    x := Max(0, x), y := Max(0, y)
    if (x < left)
        x := left
    if (y < top)
        y := top
    if (x + w > b.r)
        x := Max(left, b.r - w)
    if (y + h > b.b)
        y := Max(top, b.b - h)
    return true
}

IsInt(v) => RegExMatch(Trim(v . ""), "^-?\d+$") > 0

; =============================================================================
;  APPLY
; =============================================================================
ApplyRule(r, hwnd, automatic := false) {
    if !hwnd || !WinExist("ahk_id " hwnd)
        return false

    ; Automatic matching must respect an intentional maximized or minimized
    ; state. It resumes when Windows reports the window back in normal/restored
    ; state. Explicit commands such as Apply now may still restore and apply.
    try state := WinGetMinMax("ahk_id " hwnd)
    catch
        return false
    if (automatic && state != 0)
        return false

    w := r.w, h := r.h, x := r.x, y := r.y
    if !ClampRect(&w, &h, &x, &y, hwnd, r.bounds)
        return false

    try WinGetPos(&cx, &cy, &cw, &ch, "ahk_id " hwnd)
    catch
        return false
    if (cw = w && ch = h && cx = x && cy = y)
        return false                                 ; already there; stay quiet

    try {
        if (!automatic && state != 0)
            WinRestore("ahk_id " hwnd)
        WinMove(x, y, w, h, "ahk_id " hwnd)
    } catch
        return false

    try WinGetPos(&nx, &ny, &nw, &nh, "ahk_id " hwnd)
    catch
        return false
    return !(nw = cw && nh = ch && nx = cx && ny = cy)
}

ApplyRuleToActiveWindow() {
    hwnd := WinExist("A")
    if !hwnd
        return
    r := FindRule(WinGetClass(hwnd), WinGetTitle(hwnd))
    if (r && ApplyRule(r, hwnd))
        Feedback()
}

TryAutoApply(hwnd) {
    global g_Cfg
    if (g_Cfg.Get("AutoApply", "1") = "0")
        return
    try {
        cls := WinGetClass("ahk_id " hwnd)
        ttl := WinGetTitle("ahk_id " hwnd)
    } catch
        return
    r := FindRule(cls, ttl)
    if (r && ApplyRule(r, hwnd, true))
        Feedback()
}

; =============================================================================
;  WINEVENT HOOKS
; =============================================================================
; v1 registered the callback "Fast" and then did a full INI scan, a WinMove and
; a SoundPlay inside it - i.e. heavy work on the system's hook delivery path.
; The callback now only queues the event and asks for a one-shot timer; all
; real work happens on a normal script thread in DrainEvents().
InstallHooks() {
    global g_Hooks, g_CbProc, EV_FOREGROUND, EV_MOVESIZEEND
    global EV_MINIMIZESTART, EV_NAMECHANGE
    if (g_CbProc)
        return
    g_CbProc := CallbackCreate(WinEventProc, "F", 7)
    for ev in [EV_FOREGROUND, EV_MOVESIZEEND, EV_MINIMIZESTART, EV_NAMECHANGE] {
        h := DllCall("User32\SetWinEventHook", "UInt", ev, "UInt", ev
                   , "Ptr", 0, "Ptr", g_CbProc, "UInt", 0, "UInt", 0
                   , "UInt", 0x2, "Ptr")             ; OUTOFCONTEXT | SKIPOWNPROCESS
        if (h)
            g_Hooks.Push(h)
    }
    DebugLog("WinEvent hooks installed: count=" g_Hooks.Length, g_Hooks.Length = 4 ? "INFO" : "WARN")
}

RemoveHooks() {
    global g_Hooks, g_CbProc
    DebugLog("Removing WinEvent hooks: count=" g_Hooks.Length, "INFO")
    for h in g_Hooks
        DllCall("User32\UnhookWinEvent", "Ptr", h)
    g_Hooks := []
    if (g_CbProc) {
        CallbackFree(g_CbProc)
        g_CbProc := 0
    }
}

WinEventProc(hHook, event, hwnd, idObject, idChild, thread, evtTime) {
    global g_Queue
    if (!hwnd || idObject != 0)                      ; OBJID_WINDOW only
        return
    if (g_Queue.Length > 64)                         ; never let a burst pile up
        return
    g_Queue.Push({ ev: event, hwnd: hwnd })
    SetTimer(DrainEvents, -1)
}

DrainEvents() {
    global g_Queue
    while (g_Queue.Length) {
        e := g_Queue.RemoveAt(1)
        try HandleEvent(e.ev, e.hwnd)
        catch as err
            DebugException("HandleEvent ev=" e.ev " " DebugWindow(e.hwnd), err)
    }
}

HandleEvent(ev, hwnd) {
    global EV_FOREGROUND, EV_MOVESIZEEND, EV_MINIMIZESTART, EV_NAMECHANGE
    global g_Restoring, g_ForegroundRuleHwnd, g_ForegroundRuleUntil

    ; WinEvents may re-enter while an earlier event is still being handled.
    ; Never auto-apply or queue another hide against a window in the middle of
    ; a hide/restore transaction, or against one already owned by MiniTray.
    if (g_Restoring || IsOwnWindow(hwnd) || IsTransitioning(hwnd) || FindHidden(hwnd))
        return

    if (ev = EV_FOREGROUND) {
        RememberUserForeground(hwnd)
        if Debounced(hwnd, 250)
            return
        QueueForegroundRuleApply(hwnd)
    } else if (ev = EV_MOVESIZEEND) {
        ; Ignore geometry churn generated while Alt+Tab is still committing
        ; this foreground window. The one deferred application below will use
        ; the final stable bounds.
        if (hwnd = g_ForegroundRuleHwnd && A_TickCount < g_ForegroundRuleUntil)
            return

        ; Maximize ends here too, but TryAutoApply deliberately ignores every
        ; non-normal state. Restoring the window to normal resumes the rule.
        if Debounced(hwnd, 120)
            return
        TryAutoApply(hwnd)
    } else if (ev = EV_NAMECHANGE) {
        if (DllCall("User32\GetForegroundWindow", "Ptr") != hwnd)
            return

        ; Title and accessibility-name changes are common during the same
        ; Alt+Tab commit. Do not let one move the window early and generate
        ; another title/focus announcement.
        if (hwnd = g_ForegroundRuleHwnd && A_TickCount < g_ForegroundRuleUntil)
            return

        ; v1 debounced name-changes GLOBALLY, so a burst in one window could
        ; swallow a legitimate apply in another. Now it is per-window.
        if Debounced(hwnd, 150)
            return
        TryAutoApply(hwnd)
    } else if (ev = EV_MINIMIZESTART) {
        MaybeHideOnMinimize(hwnd)
    }
}

QueueForegroundRuleApply(hwnd) {
    global FOREGROUND_RULE_SETTLE
    global g_ForegroundRuleSerial, g_ForegroundRuleHwnd, g_ForegroundRuleUntil

    g_ForegroundRuleSerial++
    serial := g_ForegroundRuleSerial
    g_ForegroundRuleHwnd := hwnd
    g_ForegroundRuleUntil := A_TickCount + FOREGROUND_RULE_SETTLE

    SetTimer(
        ApplyForegroundRuleAfterSettle.Bind(hwnd, serial),
        -FOREGROUND_RULE_SETTLE
    )
}

ApplyForegroundRuleAfterSettle(hwnd, serial, *) {
    global g_ForegroundRuleSerial, g_ForegroundRuleHwnd, g_ForegroundRuleUntil

    if (serial != g_ForegroundRuleSerial || hwnd != g_ForegroundRuleHwnd)
        return

    g_ForegroundRuleHwnd := 0
    g_ForegroundRuleUntil := 0

    if !WinExist("ahk_id " hwnd)
        return
    if (DllCall("User32\GetForegroundWindow", "Ptr") != hwnd)
        return
    if (IsOwnWindow(hwnd) || IsTransitioning(hwnd) || FindHidden(hwnd))
        return

    DebugLog(
        "Applying foreground rule after Alt+Tab/focus settle: "
        DebugWindow(hwnd),
        "DEBUG"
    )
    TryAutoApply(hwnd)
}


; WS_EX_TOOLWINDOW removes a window from the Alt+Tab list regardless of whether
; it is visible.
; AHK's main window hosts a large multiline Edit, used only to display
; ListLines / ListVars / KeyHistory output -- none of which this script ever
; shows. Left in place it can take keyboard focus while the window is hosting
; the tray menu, and a screen reader then announces the window title followed
; by "edit multiline blank". Hiding it removes it as a focus target.
HideScriptEdit() {
    try {
        for c in WinGetControlsHwnd("ahk_id " A_ScriptHwnd) {
            if (WinGetClass("ahk_id " c) = "Edit")
                DllCall("User32\ShowWindow", "Ptr", c, "Int", 0)     ; SW_HIDE
        }
    } catch {
        ; nothing enumerated; nothing to hide
    }
}
MakeToolWindow(hwnd) {
    static GWL_EXSTYLE := -20, WS_EX_TOOLWINDOW := 0x80
    fnGet := (A_PtrSize = 8) ? "User32\GetWindowLongPtrW" : "User32\GetWindowLongW"
    fnSet := (A_PtrSize = 8) ? "User32\SetWindowLongPtrW" : "User32\SetWindowLongW"
    ex := DllCall(fnGet, "Ptr", hwnd, "Int", GWL_EXSTYLE, "Ptr")
    DllCall(fnSet, "Ptr", hwnd, "Int", GWL_EXSTYLE, "Ptr", ex | WS_EX_TOOLWINDOW)
    ; An extended-style change is not committed until the frame is recalculated.
    ; Without this the taskbar and Alt+Tab can keep the old classification.
    DllCall("User32\SetWindowPos", "Ptr", hwnd, "Ptr", 0
          , "Int", 0, "Int", 0, "Int", 0, "Int", 0
          , "UInt", 0x37)                ; NOMOVE|NOSIZE|NOZORDER|NOACTIVATE|FRAMECHANGED
}

Debounced(hwnd, ms) {
    global g_Seen
    now := A_TickCount
    if (g_Seen.Has(hwnd) && (now - g_Seen[hwnd]) < ms)
        return true
    g_Seen[hwnd] := now
    if (g_Seen.Count > 256)
        g_Seen := Map()
    return false
}

BeginTransition(hwnd) {
    global g_Transitioning
    if g_Transitioning.Has(hwnd)
        return false
    g_Transitioning[hwnd] := A_TickCount
    return true
}

EndTransition(hwnd) {
    global g_Transitioning
    if g_Transitioning.Has(hwnd)
        g_Transitioning.Delete(hwnd)
}

IsTransitioning(hwnd) {
    global g_Transitioning
    return g_Transitioning.Has(hwnd)
}

IsOwnWindow(hwnd) {
    global g_MainGui, g_EditGui
    ; Every AHK script owns a normally-hidden main window whose title is the
    ; script (or exe) path. Hiding it and later showing it again is what
    ; produces a blank Alt+Tab entry called "...\MiniTray.exe".
    if (hwnd = A_ScriptHwnd)
        return true
    if (g_MainGui && hwnd = g_MainGui.Hwnd)
        return true
    if (g_EditGui && hwnd = g_EditGui.Hwnd)
        return true
    return false
}

MaybeHideOnMinimize(hwnd) {
    try {
        r := FindRule(WinGetClass("ahk_id " hwnd), WinGetTitle("ahk_id " hwnd))
    } catch
        return
    if (!r || !r.hom)
        return
    SetTimer(HideMinimizedByRule.Bind(hwnd), -150)   ; let the minimise finish
}

HideMinimizedByRule(hwnd, *) {
    HideToTray(hwnd, false, 0, 0, true, 0, "", true, false)
}

; =============================================================================
;  PROCESS IDENTITY
; =============================================================================
; Every packaged app reports ApplicationFrameHost.exe, which would collapse
; Settings, Calculator and Photos into one menu group. The real owner is the
; process behind the child CoreWindow.
ProcNameFor(hwnd) {
    name := ""
    try name := WinGetProcessName("ahk_id " hwnd)
    if (name != "ApplicationFrameHost.exe")
        return StripExe(name)
    try {
        for c in WinGetControlsHwnd("ahk_id " hwnd) {
            if (WinGetClass("ahk_id " c) = "Windows.UI.Core.CoreWindow")
                return StripExe(ProcessGetName(WinGetPID("ahk_id " c)))
        }
    } catch {
        ; frame has no realised CoreWindow child right now
    }
    return StripExe(name)                            ; frame is cloaked; best effort
}

StripExe(n) => RegExReplace(n, "i)\.exe$")

; "msedge" -> "Microsoft Edge". The FileDescription string in an executable's
; version resource is the same friendly name Task Manager shows. Falls back to
; the bare file name for executables that carry no version resource at all.
AppNameFor(hwnd) {
    if ((path := ProcPathFor(hwnd)) != "") {
        if ((d := FileDescription(path)) != "")
            return d
        SplitPath(path, &leaf)
        return StripExe(leaf)
    }
    return ProcNameFor(hwnd)
}

; Same UWP dance as ProcNameFor: a packaged app's frame belongs to
; ApplicationFrameHost, so resolve the process behind the child CoreWindow.
ProcPathFor(hwnd) {
    path := ""
    try path := WinGetProcessPath("ahk_id " hwnd)
    if (path != "" && !InStr(path, "\ApplicationFrameHost.exe"))
        return path
    try {
        for c in WinGetControlsHwnd("ahk_id " hwnd) {
            if (WinGetClass("ahk_id " c) = "Windows.UI.Core.CoreWindow")
                return ProcessGetPath(WinGetPID("ahk_id " c))
        }
    } catch {
        ; frame is cloaked; fall through to whatever we already have
    }
    return path
}

; Cached per path - the version resource of a given exe never changes while it
; is running, and this is called on every hide.
FileDescription(path) {
    static cache := Map()
    if cache.Has(path)
        return cache[path]

    desc := "", dummy := 0
    size := DllCall("Version\GetFileVersionInfoSizeW", "Str", path, "UInt*", &dummy, "UInt")
    if (size) {
        buf := Buffer(size, 0)
        if DllCall("Version\GetFileVersionInfoW", "Str", path, "UInt", 0
                 , "UInt", size, "Ptr", buf) {
            pTrans := 0, tLen := 0
            ; an exe can carry several translations; use the first one it lists
            if (DllCall("Version\VerQueryValueW", "Ptr", buf
                      , "Str", "\VarFileInfo\Translation"
                      , "Ptr*", &pTrans, "UInt*", &tLen, "Int") && tLen >= 4) {
                sub := Format("\StringFileInfo\{:04X}{:04X}\FileDescription"
                            , NumGet(pTrans, 0, "UShort"), NumGet(pTrans, 2, "UShort"))
                pVal := 0, vLen := 0
                if (DllCall("Version\VerQueryValueW", "Ptr", buf, "Str", sub
                          , "Ptr*", &pVal, "UInt*", &vLen, "Int") && vLen)
                    desc := StrGet(pVal, vLen, "UTF-16")
            }
        }
    }
    desc := Trim(desc, " `t`r`n" . Chr(0))
    cache[path] := desc
    return desc
}

; =============================================================================
;  HIDE / RESTORE
; =============================================================================
; ITaskbarList, for windows that refuse WinHide (UWP frames are DWM-cloaked and
; ApplicationFrameHost puts them straight back). For those we minimise instead
; and drop the taskbar button, which does stick.
TaskbarList(reset := false) {
    static tb := 0
    if reset {
        tb := 0
        return 0
    }
    if !tb {
        try {
            tb := ComObject("{56FDF344-FD6D-11d0-958A-006097C9A090}"
                          , "{56FDF342-FD6D-11d0-958A-006097C9A090}")
            ComCall(3, tb)                           ; HrInit
        } catch
            tb := 0
    }
    return tb
}

TaskbarTab(hwnd, add) {
    ; ITaskbarList is implemented by Explorer. A shell restart invalidates the
    ; cached COM object, so discard it on failure and retry once with a fresh one.
    Loop 2 {
        tb := TaskbarList()
        if !tb
            return false
        try {
            ComCall(add ? 4 : 5, tb, "Ptr", hwnd)    ; AddTab : DeleteTab
            return true
        } catch {
            TaskbarList(true)
            if (A_Index = 1)
                Sleep 75
        }
    }
    return false
}

GetDesktopShellPid() {
    ; GetShellWindow is the authoritative desktop-shell HWND. Shell_TrayWnd can
    ; be temporarily unavailable while Explorer/taskbar components restart,
    ; which previously left g_ShellPid at zero and caused every Explorer folder
    ; window to be rejected as unsafe.
    shellHwnd := 0
    try shellHwnd := DllCall("User32\GetShellWindow", "Ptr")
    if shellHwnd {
        shellPid := 0
        try DllCall("User32\GetWindowThreadProcessId", "Ptr", shellHwnd, "UInt*", &shellPid)
        if shellPid
            return shellPid
    }

    ; Fallback for unusual shell replacements/builds.
    try {
        trayHwnd := WinExist("ahk_class Shell_TrayWnd")
        if trayHwnd
            return WinGetPID("ahk_id " trayHwnd)
    }
    return 0
}

RefreshShellIdentity() {
    global g_ShellPid
    pid := GetDesktopShellPid()
    if (pid != g_ShellPid) {
        oldPid := g_ShellPid
        changed := (g_ShellPid != 0 && pid != 0)
        g_ShellPid := pid
        DebugLog("Desktop shell PID changed: old=" oldPid " new=" pid, pid ? "INFO" : "WARN")
        TaskbarList(true)
        return changed
    }
    return false
}

ReapplyHiddenTaskbarTabs() {
    global g_Hidden
    for e in g_Hidden
        if (e.how = "min" && WindowMatchesRecord(e))
            TaskbarTab(e.hwnd, false)
}

IsShellWindow(hwnd) {
    static skipClasses := [
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW",
        "Windows.UI.Core.CoreWindow", "MultitaskingViewFrame",
        "Windows.UI.Composition.DesktopWindowContentBridge",
        "NotifyIconOverflowWindow", "XamlExplorerHostIslandWindow",
        "TaskSwitcherWnd", "ForegroundStaging", "DV2ControlHost"
    ]
    static skipProcesses := [
        "startmenuexperiencehost.exe", "searchhost.exe",
        "shellexperiencehost.exe", "textinputhost.exe",
        "lockapp.exe", "widgets.exe", "widgetservice.exe"
    ]

    try cls := WinGetClass("ahk_id " hwnd)
    catch
        return true
    for c in skipClasses
        if (StrLower(cls) = StrLower(c))
            return true

    proc := ""
    try proc := StrLower(WinGetProcessName("ahk_id " hwnd))
    for p in skipProcesses
        if (proc = p)
            return true
    return false
}

WindowExStyle(hwnd) {
    fn := (A_PtrSize = 8) ? "User32\GetWindowLongPtrW"
        : "User32\GetWindowLongW"
    try return DllCall(fn, "Ptr", hwnd, "Int", -20, "Ptr")
    catch
        return 0
}

VisibleActiveDialog(hwnd) {
    static GW_OWNER := 4, GA_ROOTOWNER := 3
    if !hwnd
        return 0

    ; GetLastActivePopup is the authoritative modal-popup path for classic,
    ; Win32, wxWidgets and many browser-owned dialogs.
    popup := 0
    try popup := DllCall(
        "User32\GetLastActivePopup",
        "Ptr", hwnd,
        "Ptr"
    )
    if (
        popup
        && popup != hwnd
        && DllCall("User32\IsWindowVisible", "Ptr", popup)
    ) {
        popupClass := ""
        try popupClass := StrLower(WinGetClass("ahk_id " popup))
        ; Explorer's transient input helper is not a modal dialog.
        if (popupClass != "inputsitewindowclass")
            return popup
    }

    ; Some frameworks do not update GetLastActivePopup reliably. When the owner
    ; is disabled, find its visible owned/root-owner window explicitly.
    ownerDisabled := false
    try ownerDisabled := !DllCall("User32\IsWindowEnabled", "Ptr", hwnd)
    for candidate in WinGetList() {
        if (candidate = hwnd)
            continue
        if !DllCall("User32\IsWindowVisible", "Ptr", candidate)
            continue

        cls := ""
        try cls := StrLower(WinGetClass("ahk_id " candidate))
        if (
            cls = "tooltips_class32"
            || cls = "#32768"
            || cls = "sysshadow"
            || cls = "inputsitewindowclass"
        )
            continue

        owner := 0
        rootOwner := 0
        try owner := DllCall(
            "User32\GetWindow",
            "Ptr", candidate,
            "UInt", GW_OWNER,
            "Ptr"
        )
        try rootOwner := DllCall(
            "User32\GetAncestor",
            "Ptr", candidate,
            "UInt", GA_ROOTOWNER,
            "Ptr"
        )

        if (
            owner = hwnd
            || (rootOwner = hwnd && candidate != hwnd)
        ) {
            if (ownerDisabled || cls = "#32770")
                return candidate
        }
    }
    return 0
}

WindowHideBlockReason(hwnd) {
    static WS_EX_TOOLWINDOW := 0x00000080
    static WS_EX_APPWINDOW := 0x00040000
    static dialogClasses := [
        "#32770", "#32768", "tooltips_class32", "SysShadow",
        "Shell_Dialog", "ComboLBox"
    ]

    if !hwnd
        return "no active window"
    if IsShellWindow(hwnd)
        return "shell or special system surface"

    cls := ""
    try cls := WinGetClass("ahk_id " hwnd)
    catch
        return "unavailable window"
    for dialogClass in dialogClasses
        if (StrLower(cls) = StrLower(dialogClass))
            return "dialog, menu, or transient popup"

    ex := WindowExStyle(hwnd)
    owner := 0
    try owner := DllCall(
        "User32\GetWindow",
        "Ptr", hwnd,
        "UInt", 4,
        "Ptr"
    )

    if ((ex & WS_EX_TOOLWINDOW) && !(ex & WS_EX_APPWINDOW))
        return "tool or popup window"
    if (owner && !(ex & WS_EX_APPWINDOW))
        return "owned dialog or secondary window"

    if !DllCall("User32\IsWindowEnabled", "Ptr", hwnd)
        return "application disabled by active dialog"

    if (popup := VisibleActiveDialog(hwnd))
        return "application has active dialog: " DebugWindow(popup)

    return ""
}

IsExplorerFileWindow(hwnd) {
    if !hwnd
        return false
    try {
        if (StrLower(WinGetProcessName("ahk_id " hwnd)) != "explorer.exe")
            return false
        if (WinGetClass("ahk_id " hwnd) != "CabinetWClass")
            return false
    } catch {
        return false
    }
    return IsAltTabWindow(hwnd)
}

ResolveExplorerActiveWindow(hwnd) {
    global g_LastUserForegroundHwnd

    if !hwnd
        return 0

    ; A normal application HWND needs no correction.
    if IsAltTabWindow(hwnd)
        return hwnd

    proc := "", cls := "", pid := 0
    try proc := StrLower(WinGetProcessName("ahk_id " hwnd))
    try cls := StrLower(WinGetClass("ahk_id " hwnd))
    try pid := WinGetPID("ahk_id " hwnd)

    ; This is the transient HWND observed in the logs immediately after
    ; restoring a File Explorer CabinetWClass. Do not reinterpret unrelated
    ; Explorer shell surfaces such as the desktop, taskbar, Start, or Task View.
    if (proc != "explorer.exe" || cls != "inputsitewindowclass")
        return hwnd

    static GW_OWNER := 4, GA_ROOTOWNER := 3

    ; First prefer an explicit Win32 ownership relationship if Windows exposes
    ; one for this build of Explorer.
    owner := 0
    rootOwner := 0
    try owner := DllCall(
        "User32\GetWindow",
        "Ptr", hwnd,
        "UInt", GW_OWNER,
        "Ptr"
    )
    try rootOwner := DllCall(
        "User32\GetAncestor",
        "Ptr", hwnd,
        "UInt", GA_ROOTOWNER,
        "Ptr"
    )
    for candidate in [owner, rootOwner] {
        if (
            candidate
            && candidate != hwnd
            && IsExplorerFileWindow(candidate)
            && !FindHidden(candidate)
        ) {
            DebugLog(
                "Resolved Explorer helper via owner/root-owner: helper="
                DebugWindow(hwnd) " target=" DebugWindow(candidate),
                "DEBUG"
            )
            return candidate
        }
    }

    ; RestoreOne explicitly remembers its real CabinetWClass target. Preserve
    ; that identity when Explorer subsequently foregrounds InputSiteWindowClass.
    candidate := g_LastUserForegroundHwnd
    if (
        candidate
        && candidate != hwnd
        && WinExist("ahk_id " candidate)
        && IsExplorerFileWindow(candidate)
        && !FindHidden(candidate)
    ) {
        candidatePid := 0
        try candidatePid := WinGetPID("ahk_id " candidate)
        if (!pid || candidatePid = pid) {
            DebugLog(
                "Resolved Explorer helper via last real foreground: helper="
                DebugWindow(hwnd) " target=" DebugWindow(candidate),
                "DEBUG"
            )
            return candidate
        }
    }

    ; Last resort: use the topmost visible Alt+Tab Explorer CabinetWClass in
    ; the same process. WinGetList is Z-order, so this selects the file window
    ; Explorer most recently placed behind its transient input helper.
    for candidate in WinGetList() {
        if (candidate = hwnd || FindHidden(candidate))
            continue
        candidatePid := 0
        try candidatePid := WinGetPID("ahk_id " candidate)
        if (pid && candidatePid != pid)
            continue
        if !IsExplorerFileWindow(candidate)
            continue

        DebugLog(
            "Resolved Explorer helper via Z-order fallback: helper="
            DebugWindow(hwnd) " target=" DebugWindow(candidate),
            "DEBUG"
        )
        return candidate
    }

    DebugLog(
        "Explorer helper could not be resolved to CabinetWClass: "
        DebugWindow(hwnd),
        "WARN"
    )
    return hwnd
}


FindHidden(hwnd) {
    global g_Hidden
    for i, e in g_Hidden
        if (e.hwnd = hwnd)
            return i
    return 0
}

; During very rapid consecutive Shift+Escape presses, Windows can briefly keep
; GetForegroundWindow/WinExist("A") on the Explorer HWND that MiniTray just hid.
; That HWND is already present in g_Hidden, so treating it as the new target
; produces a false "unable to hide window". Recover only this impossible/stale
; state by selecting the first still-visible native Alt+Tab destination.
ResolveStaleHiddenHideTarget(hwnd) {
    if (!hwnd || !FindHidden(hwnd))
        return hwnd

    for candidate in GetNativeAltTabChain() {
        if (!candidate || candidate = hwnd || FindHidden(candidate))
            continue
        DebugLog(
            "Recovered stale hidden foreground for hide: stale="
            DebugWindow(hwnd) " target=" DebugWindow(candidate),
            "INFO"
        )
        return candidate
    }

    return hwnd
}

HideActiveToTray() {
    rawHwnd := WinExist("A")
    hwnd := ResolveExplorerActiveWindow(rawHwnd)
    hwnd := ResolveStaleHiddenHideTarget(hwnd)
    blockReason := hwnd ? WindowHideBlockReason(hwnd) : "no active window"

    if (hwnd != rawHwnd) {
        DebugLog(
            "Hide hotkey normalized active HWND: raw="
            DebugWindow(rawHwnd) " resolved=" DebugWindow(hwnd),
            "INFO"
        )
    } else {
        DebugLog("Hide hotkey requested: " DebugWindow(hwnd), "INFO")
    }

    ; AHK briefly foregrounds its own main window to display a popup menu, so
    ; "A" really can be us for an instant after Ctrl+Alt+M or a tray click.
    if (
        !hwnd
        || IsOwnWindow(hwnd)
        || blockReason != ""
        || FindHidden(hwnd)
        || !IsAltTabWindow(hwnd)
    ) {
        ; "No windows open" is reserved for a genuinely empty native task list.
        ; An app with a modal dialog is still an Alt+Tab destination; it is just
        ; intentionally not hideable.
        if (GetNativeAltTabChain().Length = 0) {
            DebugLog("Hide rejected: no open Alt+Tab windows", "INFO")
            StartQuiet(700)
            SayQuietFinal("no windows open", 500)
            return
        }

        if (!hwnd)
            DebugLog("Hide rejected: no active window", "WARN")
        else if IsOwnWindow(hwnd)
            DebugLog("Hide rejected: MiniTray-owned window " DebugWindow(hwnd), "WARN")
        else if (blockReason != "")
            DebugLog("Hide rejected: " blockReason " " DebugWindow(hwnd), "WARN")
        else if FindHidden(hwnd)
            DebugLog("Hide rejected: window already hidden " DebugWindow(hwnd), "WARN")
        else
            DebugLog("Hide rejected: window is not Alt+Tab eligible " DebugWindow(hwnd), "WARN")
        SpeakUnableToHideWindow()
        return
    }
    HideToTray(hwnd)
}

; Snapshot the windows in the same top-to-bottom Z-order used by Alt+Tab.
; Hidden windows, MiniTray's own helper GUIs, and shell surfaces are excluded.
; Taking the snapshot before a batch hide is important: every hide changes the
; live Z-order, but it must not change the order selected at hotkey time.
GetNativeAltTabChain() {
    chain := []
    for hwnd in WinGetList() {
        if (IsOwnWindow(hwnd) || FindHidden(hwnd) || IsShellWindow(hwnd))
            continue
        if !IsAltTabWindow(hwnd)
            continue
        chain.Push(hwnd)
    }
    return chain
}

GetHideableAltTabChain() {
    chain := []
    for hwnd in GetNativeAltTabChain() {
        if (WindowHideBlockReason(hwnd) != "")
            continue
        chain.Push(hwnd)
    }
    return chain
}

HideAllOpenWindows(*) {
    global g_Hidden, QUIET_MAX, g_FocusBridgeGui

    startedAt := A_TickCount
    chain := GetHideableAltTabChain()    ; foreground -> bottom of Alt+Tab chain
    DebugLog("Hide-all requested: candidates=" chain.Length, "INFO")
    if (!chain.Length) {
        if GetNativeAltTabChain().Length {
            DebugLog(
                "Hide-all rejected: only dialogs, modal owners, or special windows remain",
                "INFO"
            )
            SpeakUnableToHideWindow()
        } else {
            StartQuiet(700)
            SayQuietFinal("no windows open", 500)
        }
        return
    }

    ; Tag this contiguous group. The records are appended in the snapshot's
    ; Alt+Tab order. Restore-all reverses the block: bottom-most first and the
    ; original foreground last, recreating the old Z-order.
    batchId := A_NowUTC "-" A_TickCount
    originalHwnd := chain[1]
    originalPid := 0
    originalFocus := 0
    originalFocusClass := ""
    try originalPid := WinGetPID("ahk_id " originalHwnd)
    try originalFocus := ControlGetFocus("ahk_id " originalHwnd)
    if originalFocus {
        try originalFocusClass := ControlGetClassNN(originalFocus)
    }

    ; Cache NVDA only once, while the user's original foreground window still
    ; owns focus. Activating every member of the chain was both slow and caused
    ; Edge to bounce repeatedly between browse and focus mode.
    StartQuiet(Max(QUIET_MAX, chain.Length * 160 + 1500))
    if originalPid
        RememberNvdaFocus(originalHwnd, originalPid)

    ; Park focus on MiniTray's off-screen ToolWindow once. Every target can now
    ; be hidden directly by HWND without foregrounding it first. This removes
    ; the per-window activation waits and repeated browser mode changes.
    bridgePrimed := PrimeBatchFocusBridge()
    if !bridgePrimed
        FocusDesktop()

    hiddenCount := 0
    hiddenDetails := []
    rank := 0
    for hwnd in chain {
        rank++
        if (
            !WinExist("ahk_id " hwnd)
            || IsOwnWindow(hwnd)
            || FindHidden(hwnd)
            || WindowHideBlockReason(hwnd) != ""
        )
            continue

        before := g_Hidden.Length
        isOriginal := hwnd = originalHwnd
        HideToTray(hwnd, true, batchId, rank, false
            , isOriginal ? originalFocus : 0
            , isOriginal ? originalFocusClass : ""
            , false)
        if (g_Hidden.Length > before) {
            hiddenCount++
            e := g_Hidden[g_Hidden.Length]
            hiddenDetails.Push(e.proc " " e.title)
        }
    }

    ; Put keyboard focus on the desktop before announcing completion. INI
    ; persistence and tray rebuilding are deliberately deferred to the next
    ; message-loop turn: the in-memory stack is already authoritative, so they
    ; must not hold up the result speech.
    FocusDesktop()
    if IsObject(g_FocusBridgeGui)
        try g_FocusBridgeGui.Hide()

    if (hiddenCount) {
        summary := (hiddenCount = 1) ? "1 window hidden. desktop list"
            : hiddenCount " windows hidden. desktop list"
        ; Desktop focus events can arrive after the controller command and
        ; cancel an ordinary MTFINAL utterance. Use the same deferred NVDA-side
        ; delivery as the reliable single-final-window hide path.
        SayDeferredHideFinal(summary, 1200)
        SetTimer(FinalizeHideAllBatch.Bind(startedAt, hiddenCount
            , bridgePrimed, hiddenDetails), -1)
    } else {
        if GetNativeAltTabChain().Length {
            SpeakUnableToHideWindow()
            DebugLog(
                "Hide-all completed with no hides because remaining windows became protected",
                "WARN"
            )
        } else {
            StartQuiet(700)
            SayQuietFinal("no windows open", 500)
        }
        DebugLog("Hide-all completed: hidden=0 totalTracked=" g_Hidden.Length
            " bridgePrimed=" bridgePrimed
            " elapsedMs=" (A_TickCount - startedAt), "WARN")
    }
}

FinalizeHideAllBatch(startedAt, hiddenCount, bridgePrimed, hiddenDetails, *) {
    global g_Hidden
    try {
        ; One disk write and one tray rebuild for the complete batch, after the
        ; completion announcement has already been handed to NVDA.
        SaveHidden()
        RefreshTray()
    } catch Error as err {
        DebugException("Deferred hide-all finalization failed", err)
    }
    if hiddenDetails.Length
        DebugLog("Hide-all windows: " Join(hiddenDetails, " | "), "DEBUG")
    DebugLog("Hide-all completed: hidden=" hiddenCount
        " totalTracked=" g_Hidden.Length
        " bridgePrimed=" bridgePrimed
        " elapsedMs=" (A_TickCount - startedAt), "INFO")
}

HideToTray(hwnd, batchMode := false, batchId := 0, batchRank := 0
        , cacheNvdaFocus := true, presetFocus := 0
        , presetFocusClass := "", captureWin32Focus := true
        , announceFailure := true) {
    global g_Hidden, g_Cfg, g_ShellPid
    if !batchMode
        DebugLog("HideToTray entered: " DebugWindow(hwnd), "INFO")
    ; Also guarded here, not just in the caller: MaybeHideOnMinimize reaches
    ; this directly from the WinEvent dispatcher. The transition guard is set
    ; before any operation that can generate another WinEvent.
    blockReason := hwnd ? WindowHideBlockReason(hwnd) : "no active window"
    if (
        !WinExist("ahk_id " hwnd)
        || IsOwnWindow(hwnd)
        || FindHidden(hwnd)
        || blockReason != ""
    ) {
        if blockReason != ""
            DebugLog(
                "HideToTray safety rejection: " blockReason " " DebugWindow(hwnd),
                "WARN"
            )
        if (!batchMode && announceFailure)
            SpeakUnableToHideWindow()
        return
    }
    if !BeginTransition(hwnd)
        return

    recorded := false
    taskbarRemoved := false
    speechHandedOff := false
    modeGuardToken := 0

    ; Open the NVDA quiet window BEFORE WinMinimize/WinHide. Previously this
    ; happened after Explorer had already moved focus, so NVDA had time to queue
    ; the transient "<page title> document" and "same page link" lines. A
    ; hide-all batch owns one longer quiet window around the complete sequence.
    if !batchMode {
        StartQuiet()
        ; Unlike restore, a hide can transfer foreground as part of WinHide or
        ; WinMinimize itself. Arm the mode guard before either API is touched.
        modeGuardToken := BeginNvdaModeGuard()
    }

    try {
        try {
            title := WinGetTitle("ahk_id " hwnd)
            pid   := WinGetPID("ahk_id " hwnd)
            exe   := StrLower(WinGetProcessName("ahk_id " hwnd))
        } catch {
            if (!batchMode && announceFailure) {
                SpeakUnableToHideWindow(true)
                speechHandedOff := true
            } else {
                Nope()
            }
            return
        }
        proc := AppNameFor(hwnd)
        if (title = "")
            title := "(untitled)"
        if !batchMode
            DebugLog("Hide target resolved: hwnd=" hwnd " pid=" pid " exe=" exe
                " app=" proc " title=" title, "DEBUG")

        ; Single-window hides cache NVDA and query the focused Win32 child as
        ; before. Hide-all caches only its original foreground window before
        ; parking focus; background windows must not be activated merely to
        ; obtain an accessibility object.
        if cacheNvdaFocus
            RememberNvdaFocus(hwnd, pid)

        focus := presetFocus
        focusClass := presetFocusClass
        if (captureWin32Focus && !focus) {
            try focus := ControlGetFocus("ahk_id " hwnd)
            if focus {
                try focusClass := ControlGetClassNN(focus)
            }
        }

        how := "hide"

        if (exe = "explorer.exe") {
            ; Never manipulate a folder window hosted by the desktop-shell
            ; Explorer process. The captured crashes occurred inside Explorer's
            ; own windows.storage registry watcher, and the most reliable way to
            ; contain that Windows race is to isolate folder windows from the
            ; shell before MiniTray touches them.
            RefreshShellIdentity()
            ; Block only when we positively identify this window as belonging
            ; to the desktop-shell Explorer process. A temporary failure to
            ; resolve the shell PID must not reject every Explorer window.
            if (g_ShellPid && pid = g_ShellPid) {
                DebugLog("Explorer hide blocked: targetPid=" pid " shellPid=" g_ShellPid
                    " title=" title, "WARN")
                if (!batchMode && announceFailure) {
                    SayQuietFinal("unable to hide window")
                    speechHandedOff := true
                }
                return
            }

            ; An isolated folder process can use an ordinary visibility change.
            ; Do not call ITaskbarList::DeleteTab for Explorer: that COM service
            ; is implemented by the desktop shell and was the remaining direct
            ; cross-process shell manipulation in the previous safe path.
            ; ShowWindow(SW_HIDE) is synchronous and avoids AutoHotkey's
            ; per-window command delay.  The visibility check immediately below
            ; is the success test for both batch and single-window hides.
            DllCall("User32\ShowWindow", "Ptr", hwnd, "Int", 0)
            if DllCall("User32\IsWindowVisible", "Ptr", hwnd) {
                try WinShow("ahk_id " hwnd)
                if (!batchMode && announceFailure) {
                    SayQuietFinal("unable to hide window")
                    speechHandedOff := true
                }
                return
            }
        } else {
            ; Use the same synchronous no-delay hide for single-window and
            ; batch paths.  If a window refuses SW_HIDE, the existing minimize
            ; fallback below remains unchanged.
            DllCall("User32\ShowWindow", "Ptr", hwnd, "Int", 0)
            if DllCall("User32\IsWindowVisible", "Ptr", hwnd) {
                try WinMinimize("ahk_id " hwnd)
                if !WaitForMinimized(hwnd, 700) {
                    if announceFailure {
                        SayQuietFinal("unable to hide window")
                        speechHandedOff := true
                    } else {
                        Nope()
                    }
                    return
                }
                if !TaskbarTab(hwnd, false) {
                    try WinRestore("ahk_id " hwnd)
                    if announceFailure {
                        SayQuietFinal("unable to hide window")
                        speechHandedOff := true
                    } else {
                        Nope()
                    }
                    return
                }
                taskbarRemoved := true
                how := "min"
            }
        }

        if !WinExist("ahk_id " hwnd)
            return

        g_Hidden.Push({ hwnd: hwnd, pid: pid, proc: proc, title: title
                      , how: how, focus: focus, focusClass: focusClass
                      , batchId: batchId, batchRank: batchRank })
        recorded := true
        if !batchMode
            DebugLog("Window hidden: hwnd=" hwnd " pid=" pid " app=" proc " method=" how
                " savedFocus=" focus " focusClass=" focusClass " hiddenCount=" g_Hidden.Length
                " batchId=" batchId " batchRank=" batchRank " title=" title, "INFO")

        if batchMode {
            ; HideAllOpenWindows owns persistence, tray rebuilding, focus
            ; movement, and the one final summary for the whole batch.
            return
        }

        ; Persistence and tray rebuilding are not on the critical focus/speech
        ; path.  The in-memory g_Hidden stack is already authoritative, so hand
        ; NVDA the newly exposed window first and flush disk/tray state on the
        ; next AHK message-loop turn.

        ; Move focus away while NVDA is already quiet, then explicitly include
        ; that destination after the hide result. Native focus chatter remains
        ; suppressed, so the user hears one deterministic sequence.
        nextHwnd := FocusNextWindow(hwnd)
        if nextHwnd {
            nextFocus := FocusedWindowAnnouncement(nextHwnd)
            nextPid := 0
            try nextPid := WinGetPID("ahk_id " nextHwnd)
            ; The hidden window contributes only "<app> hidden". The title and
            ; focused-control speech that follow belong to the newly exposed
            ; window identified by nextHwnd/nextPid. Send MTHIDEFOCUS while the
            ; pre-hide guard is still held so there is no gap in which a browser
            ; can auto-switch mode or start page-load Say All. The NVDA plugin's
            ; target-specific transaction then overlaps the guard before release.
            SayDeferredHideFocus(proc " hidden. " nextFocus, nextHwnd, nextPid, 1200)
            EndNvdaModeGuard(modeGuardToken)
            modeGuardToken := 0
        } else {
            FocusDesktop()
            EndNvdaModeGuard(modeGuardToken)
            modeGuardToken := 0
            ; Desktop focus emits a late burst of Explorer accessibility events.
            ; Let NVDA cancel those events on its own main thread, then speak the
            ; final-window result on the next event-loop turn. This mirrors the
            ; reliable deferred MiniTray-menu announcement path.
            SayDeferredHideFinal(proc " hidden. desktop list")
        }
        speechHandedOff := true
        SetTimer(FinalizeSingleHideState, -1)
    } finally {
        EndTransition(hwnd)
        if modeGuardToken {
            EndNvdaModeGuard(modeGuardToken)
            modeGuardToken := 0
        }

        ; Any failed/aborted single-hide path must reopen NVDA immediately. A
        ; successful single hide hands ownership to its protected final
        ; announcement helper. A batch
        ; deliberately leaves the shared quiet window under HideAllOpenWindows.
        if (!batchMode && !speechHandedOff)
            EndQuiet()

        if !recorded
            DebugLog("Hide transaction did not commit: " DebugWindow(hwnd), "WARN")

        ; Roll back a taskbar deletion if the transaction failed before the
        ; window was committed to g_Hidden. Never leave an untracked window.
        if (!recorded && taskbarRemoved && WinExist("ahk_id " hwnd))
            TaskbarTab(hwnd, true)
    }
}

FinalizeSingleHideState(*) {
    try {
        SaveHidden()
        RefreshTray()
    } catch Error as err {
        DebugException("Deferred single-hide finalization failed", err)
    }
}

WaitForMinimized(hwnd, timeoutMs := 700) {
    deadline := A_TickCount + timeoutMs
    while WinExist("ahk_id " hwnd) {
        try {
            if (WinGetMinMax("ahk_id " hwnd) = -1)
                return true
        }
        if (A_TickCount >= deadline)
            break
        Sleep 25
    }
    return false
}

; True if focus never left this window while it was hidden.
;
; WinHide does not move the foreground on, so the window can remain the
; foreground window while invisible. Showing it again is then NOT a focus
; change, and a screen reader announces nothing at all -- so in that case we
; have to say the title ourselves. When focus HAS moved elsewhere, restoring
; does produce a focus change and the reader announces it, so we stay quiet.
StillFocused(hwnd) {
    return DllCall("User32\GetForegroundWindow", "Ptr") = hwnd
}

; Focus the desktop. Used when the window just hidden was the last one on
; screen, so there is nothing else to hand the foreground to -- better the
; desktop than a window that is no longer visible.
;
; The icon list is a SysListView32 that normally lives under Progman, but the
; wallpaper slideshow reparents it under one of the WorkerW windows, so both
; have to be searched and the right one is whichever actually has that child.
FocusDesktop() {
    for cls in ["Progman", "WorkerW"] {
        for hwnd in WinGetList("ahk_class " cls) {
            lv := 0
            try lv := ControlGetHwnd("SysListView321", "ahk_id " hwnd)
            catch
                continue
            if !lv
                continue
            try {
                DllCall("User32\SetForegroundWindow", "Ptr", hwnd)
                ; ControlFocus supplies the accessible desktop-list focus, but
                ; without WinActivate's default 100 ms post-command delay.
                ControlFocus(lv)
            }
            return hwnd
        }
    }
    return 0
}

; Hand the foreground to the next Alt+Tab-eligible window.
;
; WinHide does not move the foreground on, so without this the hidden window
; keeps keyboard focus: arrow keys and typing still go into a window that is
; invisible and unreachable by Alt+Tab. WinGetList returns windows in Z-order,
; topmost first, so the first eligible one is what Alt+Tab would have picked.
; Returns its hwnd, or 0 if there was nothing to move to.
FocusNextWindow(skip) {
    ; A hidden foreground window often leaves GetForegroundWindow pointing at
    ; the old HWND briefly. The previous implementation waited up to 500 ms for
    ; WinWaitActive after every candidate activation, and the log showed that
    ; full timeout was being paid on nearly every Shift+Escape. Use a native,
    ; bounded foreground handoff instead: normally this completes in one message
    ; turn; the attached-input fallback is still limited to a few milliseconds.

    fg := DllCall("User32\GetForegroundWindow", "Ptr")
    if (fg && fg != skip && !IsOwnWindow(fg) && !FindHidden(fg)
            && IsAltTabWindow(fg)) {
        DebugLog("Focus handoff reused foreground: " DebugWindow(fg), "DEBUG")
        return fg
    }

    for hwnd in WinGetList() {
        if (hwnd = skip || IsOwnWindow(hwnd) || FindHidden(hwnd))
            continue
        if !IsAltTabWindow(hwnd)
            continue

        if FastActivateForHide(hwnd, skip) {
            actual := DllCall("User32\GetForegroundWindow", "Ptr")
            if (actual && actual != skip && !IsOwnWindow(actual)
                    && !FindHidden(actual) && IsAltTabWindow(actual)) {
                DebugLog("Focus handoff selected: " DebugWindow(actual), "DEBUG")
                return actual
            }
        }
    }
    DebugLog("Focus handoff found no eligible window; desktop fallback", "DEBUG")
    return 0
}

FastActivateForHide(hwnd, skip := 0) {
    if (!hwnd || !WinExist("ahk_id " hwnd))
        return false

    ; If the next Alt+Tab candidate is minimized, restore it synchronously.
    ; Visible candidates skip this entirely.
    mm := 0
    try mm := WinGetMinMax("ahk_id " hwnd)
    if (mm = -1)
        DllCall("User32\ShowWindow", "Ptr", hwnd, "Int", 9) ; SW_RESTORE

    ; First try the cheap native foreground request.
    DllCall("User32\BringWindowToTop", "Ptr", hwnd)
    DllCall("User32\SetForegroundWindow", "Ptr", hwnd)
    Loop 4 {
        actual := DllCall("User32\GetForegroundWindow", "Ptr")
        if (actual = hwnd)
            return true
        if (actual && actual != skip && !IsOwnWindow(actual)
                && !FindHidden(actual) && IsAltTabWindow(actual))
            return true
        Sleep 4
    }

    ; Bounded attached-input fallback for Windows foreground-lock cases. Unlike
    ; WinWaitActive, this never burns a fixed 500 ms timeout.
    currentThread := DllCall("Kernel32\GetCurrentThreadId", "UInt")
    targetThread := DllCall("User32\GetWindowThreadProcessId"
        , "Ptr", hwnd, "Ptr", 0, "UInt")
    foreground := DllCall("User32\GetForegroundWindow", "Ptr")
    foregroundThread := foreground ? DllCall("User32\GetWindowThreadProcessId"
        , "Ptr", foreground, "Ptr", 0, "UInt") : 0
    attachedTarget := false, attachedForeground := false

    try {
        if (targetThread && targetThread != currentThread)
            attachedTarget := !!DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", targetThread, "Int", true)
        if (foregroundThread && foregroundThread != currentThread
                && foregroundThread != targetThread)
            attachedForeground := !!DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", foregroundThread, "Int", true)

        DllCall("User32\BringWindowToTop", "Ptr", hwnd)
        DllCall("User32\SetForegroundWindow", "Ptr", hwnd)
        DllCall("User32\SetActiveWindow", "Ptr", hwnd)
    } finally {
        if attachedForeground
            DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", foregroundThread, "Int", false)
        if attachedTarget
            DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", targetThread, "Int", false)
    }

    Loop 6 {
        actual := DllCall("User32\GetForegroundWindow", "Ptr")
        if (actual = hwnd)
            return true
        if (actual && actual != skip && !IsOwnWindow(actual)
                && !FindHidden(actual) && IsAltTabWindow(actual))
            return true
        Sleep 4
    }
    return false
}

FocusedWindowAnnouncement(hwnd) {
    if (!hwnd || !WinExist("ahk_id " hwnd))
        return "desktop list"

    title := ""
    try title := Trim(WinGetTitle("ahk_id " hwnd))

    ; Hide announcements identify the newly focused window by title only.
    ; Do not prepend the application name, even when it differs from the title.
    return (title != "") ? title : "window"
}

WindowMatchesRecord(e) {
    if !WinExist("ahk_id " e.hwnd)
        return false
    try {
        return WinGetPID("ahk_id " e.hwnd) = e.pid
    } catch {
        return false
    }
}

Reveal(e, activate := false, focusNow := true) {
    if !WindowMatchesRecord(e)
        return
    if (e.how = "min") {
        TaskbarTab(e.hwnd, true)
        try WinRestore("ahk_id " e.hwnd)
    } else {
        try WinShow("ahk_id " e.hwnd)
    }
    if (activate) {
        try WinActivate("ahk_id " e.hwnd)
        if focusNow
            ReturnFocus(e)
    }
}

; Fast restore-all reveal. AutoHotkey's WinShow/WinRestore commands apply a
; built-in post-command delay, which becomes noticeable across many windows.
; SetWindowPos rebuilds the saved Z-order without activating each intermediate
; application, and SW_SHOWNOACTIVATE restores minimize-backed entries without
; generating a foreground transition.
RevealBatchFast(e) {
    if !WindowMatchesRecord(e)
        return false

    if (e.how = "min") {
        TaskbarTab(e.hwnd, true)
        ; SW_SHOWNOACTIVATE = 4: restore the window without taking focus.
        DllCall("User32\ShowWindow", "Ptr", e.hwnd, "Int", 4)
    }

    ; HWND_TOP plus SWP_SHOWWINDOW rebuilds the chain bottom-to-top while
    ; SWP_NOACTIVATE prevents Edge/browse-mode churn during the batch.
    static flags := 0x0001 | 0x0002 | 0x0010 | 0x0040
    return !!DllCall("User32\SetWindowPos"
        , "Ptr", e.hwnd, "Ptr", 0
        , "Int", 0, "Int", 0, "Int", 0, "Int", 0
        , "UInt", flags)
}

; Activate the final restored window without AutoHotkey's per-command sleeps.
; MiniTray owns foreground through the focus bridge, so SetForegroundWindow
; normally succeeds immediately; attached input queues are a bounded fallback.
ActivateEntryBatchFast(e) {
    if !WindowMatchesRecord(e)
        return false

    hwnd := e.hwnd
    DllCall("User32\BringWindowToTop", "Ptr", hwnd)
    DllCall("User32\SetForegroundWindow", "Ptr", hwnd)
    DllCall("User32\SetActiveWindow", "Ptr", hwnd)

    if (DllCall("User32\GetForegroundWindow", "Ptr") != hwnd) {
        currentThread := DllCall("Kernel32\GetCurrentThreadId", "UInt")
        targetThread := DllCall("User32\GetWindowThreadProcessId"
            , "Ptr", hwnd, "Ptr", 0, "UInt")
        foreground := DllCall("User32\GetForegroundWindow", "Ptr")
        foregroundThread := foreground ? DllCall("User32\GetWindowThreadProcessId"
            , "Ptr", foreground, "Ptr", 0, "UInt") : 0
        attachedTarget := false, attachedForeground := false
        try {
            if (targetThread && targetThread != currentThread)
                attachedTarget := !!DllCall("User32\AttachThreadInput"
                    , "UInt", currentThread, "UInt", targetThread, "Int", true)
            if (foregroundThread && foregroundThread != currentThread
                    && foregroundThread != targetThread)
                attachedForeground := !!DllCall("User32\AttachThreadInput"
                    , "UInt", currentThread, "UInt", foregroundThread, "Int", true)
            DllCall("User32\BringWindowToTop", "Ptr", hwnd)
            DllCall("User32\SetForegroundWindow", "Ptr", hwnd)
            DllCall("User32\SetActiveWindow", "Ptr", hwnd)
        } finally {
            if attachedForeground
                DllCall("User32\AttachThreadInput"
                    , "UInt", currentThread, "UInt", foregroundThread, "Int", false)
            if attachedTarget
                DllCall("User32\AttachThreadInput"
                    , "UInt", currentThread, "UInt", targetThread, "Int", false)
        }
    }

    ctrl := 0
    if (e.HasOwnProp("focus") && e.focus
            && DllCall("User32\IsWindow", "Ptr", e.focus))
        ctrl := e.focus
    else if (e.HasOwnProp("focusClass") && e.focusClass != "") {
        try ctrl := ControlGetHwnd(e.focusClass, "ahk_id " hwnd)
    }
    if ctrl
        FocusControlBatchFast(ctrl)

    return DllCall("User32\GetForegroundWindow", "Ptr") = hwnd
}

FocusControlBatchFast(ctrl) {
    if (!ctrl || !DllCall("User32\IsWindow", "Ptr", ctrl))
        return false

    currentThread := DllCall("Kernel32\GetCurrentThreadId", "UInt")
    targetThread := DllCall("User32\GetWindowThreadProcessId"
        , "Ptr", ctrl, "Ptr", 0, "UInt")
    attached := false
    try {
        if (targetThread && targetThread != currentThread)
            attached := !!DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", targetThread, "Int", true)
        return !!DllCall("User32\SetFocus", "Ptr", ctrl)
    } finally {
        if attached
            DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", targetThread, "Int", false)
    }
}

; Showing a window does not restore the keyboard focus that was inside it -
; most apps focus their default control instead. Non-announcing bulk restores
; still use this ordinary deferred path. An individually restored window uses
; QueueFocusAfterTitle(), below, so its app/title is heard before this focus.
ReturnFocus(e) {
    global SPEECH_SETTLE
    if (!e.HasOwnProp("focus") || !e.focus)
        return
    ; ONE attempt, not an immediate one plus a retry: each ControlFocus is a
    ; focus change the reader announces. Deferred well before SPEECH_SETTLE so
    ; the announcement it provokes still lands ahead of our own line, which
    ; cancels and has the last word.
    SetTimer(TryFocus.Bind(e.hwnd, e.focus), -80)
}

TryFocus(winHwnd, ctrl, *) {
    if (!ctrl || !DllCall("User32\IsWindow", "Ptr", ctrl))
        return                           ; the control went away with a re-layout
    if !WinExist("ahk_id " winHwnd)
        return
    try ControlFocus(ctrl)
}

; Speak the app/title first. When NVDA reaches the callback marker,
; MiniTray moves keyboard focus to an off-screen ToolWindow while speech is
; still quiet. Speech is then reopened and the target window is activated.
; Because focus is crossing from another GUI/thread into the application, the
; restored child receives a genuine native gainFocus event even when it was
; already the application's internally remembered focus. Terminals can then
; announce their current caret line/prompt through NVDA's normal event path.
QueueFocusAfterTitle(text, e) {
    global g_Cfg, g_DeferredFocus, g_NextFocusToken, g_QuietUntil
    global RESTORE_FOCUS_TIMEOUT, QUIET_REFRESH

    if (!e) {
        SayQuietFinal(text)
        return
    }

    ; Without speech there is nothing to wait for. Without the plugin there
    ; is no completion callback, so use a conservative timer approximation.
    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        SetTimer(ActivateAndRestoreNativeFocus.Bind(e), -80)
        return
    }
    if (g_Cfg.Get("QuietPlugin", "1") != "1") {
        EndQuiet()
        Announce(text)
        delay := Min(6500, Max(1200, 500 + StrLen(text) * 45))
        SetTimer(ActivateAndRestoreNativeFocus.Bind(e), -delay)
        return
    }

    token := g_NextFocusToken
    g_NextFocusToken := (g_NextFocusToken >= 0x7FFFFFFE) ? 1 : g_NextFocusToken + 1
    fallback := RestoreFocusFallback.Bind(token)
    g_DeferredFocus[token] := {
        hwnd: e.hwnd,
        pid: e.pid,
        ctrl: e.HasOwnProp("focus") ? e.focus : 0,
        focusClass: e.HasOwnProp("focusClass") ? e.focusClass : "",
        fallback: fallback
    }

    ; Keep refreshing the quiet window until MiniTray has activated and primed
    ; the restored window. The plugin intentionally leaves the gate closed when
    ; it posts WM_MT_RESTORE_FOCUS; MiniTray opens it immediately before the
    ; final ControlFocus that should produce NVDA's native gainFocus speech.
    g_QuietUntil := A_TickCount + RESTORE_FOCUS_TIMEOUT
    SetTimer(QuietRefresh, -QUIET_REFRESH)
    SetTimer(fallback, -RESTORE_FOCUS_TIMEOUT)

    Announce(Chr(1) "MTFINALFOCUS:" A_ScriptHwnd ":" token ":" text Chr(1), true)
}

; Speak a restore-all summary to completion, then ask conceptSphereQuiet to
; rebuild NVDA's cached focus object. Unlike QueueFocusAfterTitle(), this does
; not move physical keyboard focus through MiniTray's helper window; the final
; restored window already owns foreground focus. The existing MTFINALFOCUS
; callback is used solely as a reliable "speech finished" signal.
QueueSavedFocusAfterTitle(text, e) {
    global g_Cfg, g_DeferredFocus, g_NextFocusToken, g_QuietUntil
    global RESTORE_FOCUS_TIMEOUT, QUIET_REFRESH

    if (!e) {
        SayQuietFinal(text)
        return
    }

    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        return
    }

    if (g_Cfg.Get("QuietPlugin", "1") != "1") {
        EndQuiet()
        Announce(text)
        return
    }

    token := g_NextFocusToken
    g_NextFocusToken := (g_NextFocusToken >= 0x7FFFFFFE) ? 1 : g_NextFocusToken + 1
    fallback := RestoreFocusFallback.Bind(token)
    g_DeferredFocus[token] := {
        hwnd: e.hwnd,
        pid: e.pid,
        ctrl: e.HasOwnProp("focus") ? e.focus : 0,
        focusClass: e.HasOwnProp("focusClass") ? e.focusClass : "",
        title: e.HasOwnProp("title") ? e.title : "",
        savedFocusOnly: true,
        fallback: fallback
    }

    ; Keep late shell/focus chatter suppressed for the complete utterance.
    ; NVDA posts WM_MT_RESTORE_FOCUS only after its synth reaches the callback.
    g_QuietUntil := A_TickCount + RESTORE_FOCUS_TIMEOUT
    SetTimer(QuietRefresh, -QUIET_REFRESH)
    SetTimer(fallback, -RESTORE_FOCUS_TIMEOUT)

    Announce(Chr(1) "MTFINALFOCUS:" A_ScriptHwnd ":" token ":" text Chr(1), true)
}

RestoreFocusAfterSpeechMessage(wParam, lParam, msg, hwnd) {
    CompleteDeferredFocus(wParam)
    return 0
}

RestoreFocusFallback(token, *) {
    CompleteDeferredFocus(token)
}

CompleteDeferredFocus(token) {
    global g_DeferredFocus, RESTORE_FOCUS_PRIME_SETTLE
    global g_QuietUntil, QUIET_CHUNK, QUIET_REFRESH
    if !g_DeferredFocus.Has(token)
        return

    rec := g_DeferredFocus[token]
    g_DeferredFocus.Delete(token)
    try SetTimer(rec.fallback, 0)

    if !WindowMatchesFocusRecord(rec) {
        EndQuiet()
        return
    }

    if (rec.HasOwnProp("savedFocusOnly") && rec.savedFocusOnly) {
        ; The restore summary has now genuinely finished. Keep one short quiet
        ; guard around NVDA's focus-cache reconstruction, then let the plugin's
        ; focused-control/terminal report reopen speech itself.
        g_QuietUntil := A_TickCount + 1600
        SendQuiet(QUIET_CHUNK)
        SetTimer(QuietRefresh, -QUIET_REFRESH)
        SetTimer(EndQuiet, -1600)
        RequestNvdaSavedFocusRestore(rec)
        return
    }

    ; A top-level HWND is not a reliable ControlFocus target. In the previous
    ; build that call often left the saved child focused, so focusing it again
    ; generated no EVENT_OBJECT_FOCUS for NVDA. Move focus to our own off-screen
    ; edit control instead. Its ToolWindow never enters Alt+Tab and all of its
    ; accessibility chatter is still behind the quiet gate.
    if !PrimeNativeFocusBridge() {
        ; Fallback for unusual systems where the helper GUI cannot activate.
        EndQuiet()
        SetTimer(ActivateAndRestoreNativeFocus.Bind(rec), -RESTORE_FOCUS_NATIVE_DELAY)
        return
    }

    SetTimer(OpenSpeechThenRestoreNativeFocus.Bind(rec), -RESTORE_FOCUS_PRIME_SETTLE)
}

EnsureNativeFocusBridge() {
    global g_FocusBridgeGui, g_FocusBridgeEdit, APP_NAME
    if IsObject(g_FocusBridgeGui)
        return true
    try {
        g := Gui("+ToolWindow -Caption +AlwaysOnTop", APP_NAME " focus bridge")
        g.MarginX := 0
        g.MarginY := 0
        g_FocusBridgeEdit := g.Add("Edit", "w2 h2")
        g_FocusBridgeGui := g
        return true
    } catch {
        g_FocusBridgeGui := 0
        g_FocusBridgeEdit := 0
        return false
    }
}


PrimeBatchFocusBridge() {
    global g_FocusBridgeGui, g_FocusBridgeEdit
    if !EnsureNativeFocusBridge()
        return false
    try {
        g_FocusBridgeGui.Show("x-32000 y-32000 w2 h2")
        DllCall("User32\SetForegroundWindow", "Ptr", g_FocusBridgeGui.Hwnd)
        DllCall("User32\SetFocus", "Ptr", g_FocusBridgeEdit.Hwnd)
        return DllCall("User32\GetForegroundWindow", "Ptr") = g_FocusBridgeGui.Hwnd
    } catch {
        try g_FocusBridgeGui.Hide()
        return false
    }
}

PrimeNativeFocusBridge() {
    global g_FocusBridgeGui, g_FocusBridgeEdit
    if !EnsureNativeFocusBridge()
        return false
    try {
        ; Keep it physically outside the virtual desktop but nonzero/focusable.
        g_FocusBridgeGui.Show("x-32000 y-32000 w2 h2")
        WinActivate("ahk_id " g_FocusBridgeGui.Hwnd)
        WinWaitActive("ahk_id " g_FocusBridgeGui.Hwnd, , 0.8)
        g_FocusBridgeEdit.Focus()
        return DllCall("User32\GetForegroundWindow", "Ptr") = g_FocusBridgeGui.Hwnd
    } catch {
        try g_FocusBridgeGui.Hide()
        return false
    }
}

OpenSpeechThenRestoreNativeFocus(rec, *) {
    global RESTORE_FOCUS_NATIVE_DELAY, g_FocusBridgeGui

    if !WindowMatchesFocusRecord(rec) {
        EndQuiet()
        try g_FocusBridgeGui.Hide()
        return
    }

    ; Process MTQUIET:0 before activating the target. This activation—not a
    ; repeated ControlFocus on an already-focused child—creates the native
    ; foreground/focus events that NVDA handles normally.
    EndQuiet()
    SetTimer(ActivateAndRestoreNativeFocus.Bind(rec), -RESTORE_FOCUS_NATIVE_DELAY)
}

ActivateAndRestoreNativeFocus(rec, *) {
    global RESTORE_FOCUS_VERIFY_DELAY, g_FocusBridgeGui
    if !WindowMatchesFocusRecord(rec) {
        try g_FocusBridgeGui.Hide()
        return
    }

    try WinActivate("ahk_id " rec.hwnd)
    try WinWaitActive("ahk_id " rec.hwnd, , 0.8)
    try g_FocusBridgeGui.Hide()

    if (DllCall("User32\GetForegroundWindow", "Ptr") != rec.hwnd)
        return

    ; Most applications restore their own last child automatically. Verify
    ; after activation and apply the recorded control only when the app chose a
    ; different child. Either path is a genuine native focus transition from
    ; the bridge, so NVDA can announce the object and terminal prompt.
    SetTimer(VerifyRestoredNativeFocus.Bind(rec), -RESTORE_FOCUS_VERIFY_DELAY)
}

VerifyRestoredNativeFocus(rec, *) {
    global RESTORE_FOCUS_LINE_DELAY
    if (!WindowMatchesFocusRecord(rec)
            || DllCall("User32\GetForegroundWindow", "Ptr") != rec.hwnd)
        return

    ctrl := ResolveFocusControl(rec)
    if ctrl {
        current := 0
        try current := ControlGetFocus("ahk_id " rec.hwnd)
        if (current != ctrl) {
            try ControlFocus(ctrl)
        }
    }

    ; Replaying gainFocus is not enough when NVDA still considers the same
    ; logical UIA object focused: duplicate-event suppression can discard it.
    ; Instead, ask the NVDA add-on to execute the same caret-line reporting
    ; algorithm as NVDA+L / NVDA+Up Arrow against the now-restored focus. For
    ; terminals this reads the current prompt line directly from NVDA's text
    ; provider instead of waiting for a Windows focus event.
    SetTimer(RequestNvdaFocusedLine.Bind(rec), -RESTORE_FOCUS_LINE_DELAY)
}

RequestNvdaFocusedLine(rec, *) {
    if (!WindowMatchesFocusRecord(rec)
            || DllCall("User32\GetForegroundWindow", "Ptr") != rec.hwnd)
        return

    ; nvdaControllerClient64.dll transports this private command to the add-on.
    ; The DLL itself cannot query the caret line; conceptSphereQuiet does that
    ; inside NVDA, where api.getFocusObject() and TextInfo are available.
    Announce(Chr(1) "MTREPORTLINE:" rec.hwnd ":" rec.pid Chr(1), false)
}

WindowMatchesFocusRecord(rec) {
    if (!rec || !rec.HasOwnProp("hwnd") || !WinExist("ahk_id " rec.hwnd))
        return false
    if (rec.HasOwnProp("pid")) {
        try {
            if (WinGetPID("ahk_id " rec.hwnd) != rec.pid)
                return false
        } catch {
            return false
        }
    }
    return true
}

ResolveFocusControl(rec) {
    ctrl := rec.HasOwnProp("ctrl") ? rec.ctrl : 0
    if ((!ctrl || !DllCall("User32\IsWindow", "Ptr", ctrl))
            && rec.HasOwnProp("focusClass") && rec.focusClass != "") {
        try ctrl := ControlGetHwnd(rec.focusClass, "ahk_id " rec.hwnd)
    }
    return (ctrl && DllCall("User32\IsWindow", "Ptr", ctrl)) ? ctrl : 0
}

FocusRecordNow(rec, *) {
    if !WindowMatchesFocusRecord(rec)
        return

    ctrl := ResolveFocusControl(rec)
    if ctrl {
        try ControlFocus(ctrl)
    }
    ; With no saved/recreated child, WinActivate itself supplies the native
    ; focus event. Do not focus the top-level HWND: it is not a reliable child
    ; control target and can suppress rather than create the event we need.
}

ActivateEntryNow(e) {
    if !WindowMatchesRecord(e)
        return false

    if !ForceForegroundWindow(e.hwnd)
        return false

    ctrl := 0
    if (e.HasOwnProp("focus") && e.focus
            && DllCall("User32\IsWindow", "Ptr", e.focus))
        ctrl := e.focus
    else if (e.HasOwnProp("focusClass") && e.focusClass != "") {
        try ctrl := ControlGetHwnd(e.focusClass, "ahk_id " e.hwnd)
    }

    if ctrl
        ForceControlFocus(e.hwnd, ctrl)
    return DllCall("User32\GetForegroundWindow", "Ptr") = e.hwnd
}

; WinActivate from inside a tray/ListBox callback can be undone when Windows
; returns from that callback. PopupThen already moves us to the next message
; turn; this helper then verifies foreground ownership and uses attached input
; queues as a bounded fallback rather than accepting an arbitrary destination.
ForceForegroundWindow(hwnd, waitSeconds := 0.25) {
    if (!hwnd || !WinExist("ahk_id " hwnd))
        return false

    try WinShow("ahk_id " hwnd)
    try WinRestore("ahk_id " hwnd)
    try WinActivate("ahk_id " hwnd)
    try WinWaitActive("ahk_id " hwnd, , waitSeconds)
    if (DllCall("User32\GetForegroundWindow", "Ptr") = hwnd)
        return true

    currentThread := DllCall("Kernel32\GetCurrentThreadId", "UInt")
    targetThread := DllCall("User32\GetWindowThreadProcessId", "Ptr", hwnd, "Ptr", 0, "UInt")
    foreground := DllCall("User32\GetForegroundWindow", "Ptr")
    foregroundThread := foreground ? DllCall("User32\GetWindowThreadProcessId"
        , "Ptr", foreground, "Ptr", 0, "UInt") : 0
    attachedTarget := false, attachedForeground := false

    try {
        if (targetThread && targetThread != currentThread)
            attachedTarget := !!DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", targetThread, "Int", true)
        if (foregroundThread && foregroundThread != currentThread
                && foregroundThread != targetThread)
            attachedForeground := !!DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", foregroundThread, "Int", true)

        DllCall("User32\BringWindowToTop", "Ptr", hwnd)
        DllCall("User32\SetForegroundWindow", "Ptr", hwnd)
        DllCall("User32\SetActiveWindow", "Ptr", hwnd)
    } finally {
        if attachedForeground
            DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", foregroundThread, "Int", false)
        if attachedTarget
            DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", targetThread, "Int", false)
    }

    try WinWaitActive("ahk_id " hwnd, , 0.5)
    return DllCall("User32\GetForegroundWindow", "Ptr") = hwnd
}

ForceControlFocus(winHwnd, ctrl) {
    if (!ctrl || !DllCall("User32\IsWindow", "Ptr", ctrl)
            || !WinExist("ahk_id " winHwnd))
        return false

    try ControlFocus(ctrl)
    Sleep 10
    current := 0
    try current := ControlGetFocus("ahk_id " winHwnd)
    if (current = ctrl)
        return true

    currentThread := DllCall("Kernel32\GetCurrentThreadId", "UInt")
    targetThread := DllCall("User32\GetWindowThreadProcessId", "Ptr", ctrl, "Ptr", 0, "UInt")
    attached := false
    try {
        if (targetThread && targetThread != currentThread)
            attached := !!DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", targetThread, "Int", true)
        DllCall("User32\SetFocus", "Ptr", ctrl)
    } finally {
        if attached
            DllCall("User32\AttachThreadInput"
                , "UInt", currentThread, "UInt", targetThread, "Int", false)
    }

    try current := ControlGetFocus("ahk_id " winHwnd)
    return current = ctrl
}

Dismiss(e) {
    if !WindowMatchesRecord(e)
        return
    if (e.how = "min")
        TaskbarTab(e.hwnd, true)
    try WinShow("ahk_id " e.hwnd)                    ; unhide first, so a
    try WinClose("ahk_id " e.hwnd)                   ; save prompt is visible
}

Forget(hwnd) {
    global g_Hidden
    if (i := FindHidden(hwnd))
        g_Hidden.RemoveAt(i)
}

RememberNvdaFocus(hwnd, pid) {
    global g_Cfg
    if (g_Cfg.Get("Speak", "0") != "1"
            || g_Cfg.Get("QuietPlugin", "1") != "1")
        return

    DebugLog("Caching NVDA focus before hide: hwnd=" hwnd " pid=" pid, "DEBUG")
    Announce(Chr(1) "MTSAVEFOCUS:" hwnd ":" pid Chr(1), false)
}

RequestNvdaSavedFocusRestore(e) {
    global g_Cfg
    if (!e || g_Cfg.Get("Speak", "0") != "1"
            || g_Cfg.Get("QuietPlugin", "1") != "1")
        return

    DebugLog("Requesting cached NVDA focus restore: hwnd=" e.hwnd
        " pid=" e.pid " title=" e.title, "DEBUG")
    Announce(Chr(1) "MTRESTORESAVEDFOCUS:" e.hwnd ":" e.pid Chr(1), false)
}

RestoreOne(hwnd, announceWindow := false, *) {
    global g_Hidden, SPEECH_SETTLE, g_FocusBridgeGui, NATIVE_RESTORE_HANDOFF_SETTLE
    startedAt := A_TickCount
    DebugLog("RestoreOne requested: hwnd=" hwnd " hiddenCount=" g_Hidden.Length, "INFO")
    if !(i := FindHidden(hwnd)) {
        DebugLog("RestoreOne ignored: hwnd not tracked=" hwnd, "WARN")
        return
    }

    e := g_Hidden[i]
    DebugLog("RestoreOne target: app=" e.proc " title=" e.title " method=" e.how, "DEBUG")

    ; Keep every MiniTray-owned side effect behind the quiet gate. The hidden
    ; focus bridge makes the upcoming target activation a genuine cross-window
    ; foreground/focus transition instead of a repeated SetFocus on an object
    ; NVDA may already consider focused.
    StartQuiet(SPEECH_SETTLE + 500)
    bridgePrimed := PrimeBatchFocusBridge()
    RevealBatchFast(e)
    Forget(hwnd)

    ; Finish persistence/tray reflow *before* handing focus back to the app.
    ; Once speech is reopened, target activation is the final focus-affecting
    ; operation and NVDA owns the resulting foreground/gainFocus speech natively.
    try {
        SaveHidden()
        ; If this was the final hidden window, hide the icon now while the
        ; focus bridge and MTQUIET still own the transition. A delayed hide
        ; after target activation lets Explorer move accessibility focus to the
        ; next tray icon (for example Network) and creates post-restore chatter.
        RefreshTray(true)
    } catch Error as err {
        DebugException("Native individual restore finalization failed", err)
    }

    EndQuiet()
    SignalNativeNvdaRestore(e)
    Sleep NATIVE_RESTORE_HANDOFF_SETTLE

    activated := ActivateEntryBatchFast(e)
    if (!activated)
        activated := ForceForegroundWindow(e.hwnd, 0.06)
    if activated
        RememberUserForeground(e.hwnd)
    if IsObject(g_FocusBridgeGui)
        try g_FocusBridgeGui.Hide()

    DebugLog("RestoreOne native handoff completed: hwnd=" hwnd
        " bridgePrimed=" bridgePrimed
        " activated=" activated
        " foreground=" DllCall("User32\GetForegroundWindow", "Ptr")
        " elapsedMs=" (A_TickCount - startedAt), "INFO")
}

CloseOne(
    hwnd,
    announceResult := true,
    refreshNow := true,
    quietClose := false,
    *
) {
    global g_Hidden
    DebugLog("CloseOne requested: hwnd=" hwnd " hiddenCount=" g_Hidden.Length, "INFO")
    said := ""
    if (i := FindHidden(hwnd)) {
        e := g_Hidden[i]
        if quietClose
            StartQuiet(8000)
        Dismiss(e)
        said := "Closed " e.proc " " e.title
    }
    Forget(hwnd)
    SaveHidden()
    if refreshNow
        RefreshTray()
    if (announceResult && said != "")
        SayAfterTrayChange(said)
    DebugLog("CloseOne completed: hwnd=" hwnd " remainingHidden=" g_Hidden.Length, "INFO")
    return said
}

RestoreGroup(proc, *) {
    global g_Hidden, g_Restoring, g_FocusBridgeGui, NATIVE_RESTORE_HANDOFF_SETTLE
    DebugLog("RestoreGroup requested: app=" proc " hiddenCount=" g_Hidden.Length, "INFO")

    matches := []
    for e in g_Hidden.Clone() {
        if (e.proc = proc)
            matches.Push(e)
    }
    if (!matches.Length) {
        EndQuiet()
        return
    }

    StartQuiet()
    last := matches[matches.Length]
    g_Restoring := true
    for i, e in matches {
        if (i = matches.Length)
            continue
        RevealBatchFast(e)
    }
    g_Restoring := false

    bridgePrimed := PrimeBatchFocusBridge()
    RevealBatchFast(last)
    ForgetProc(proc)
    try {
        SaveHidden()
        RefreshTray(true)
    } catch Error as err {
        DebugException("Native group restore finalization failed", err)
    }

    EndQuiet()
    SignalNativeNvdaRestore(last)
    Sleep NATIVE_RESTORE_HANDOFF_SETTLE
    activated := ActivateEntryBatchFast(last)
    if (!activated)
        activated := ForceForegroundWindow(last.hwnd, 0.06)
    if activated
        RememberUserForeground(last.hwnd)
    if IsObject(g_FocusBridgeGui)
        try g_FocusBridgeGui.Hide()

    DebugLog("RestoreGroup native handoff completed: app=" proc
        " remainingHidden=" g_Hidden.Length
        " bridgePrimed=" bridgePrimed
        " activated=" activated, "INFO")
}

CloseGroup(
    proc,
    announceResult := true,
    refreshNow := true,
    quietClose := false,
    *
) {
    global g_Hidden, g_Cfg, APP_NAME
    DebugLog("CloseGroup requested: app=" proc " hiddenCount=" g_Hidden.Length, "INFO")
    if (g_Cfg.Get("ConfirmCloseAll", "1") = "1") {
        n := 0
        for e in g_Hidden
            if (e.proc = proc)
                n++
        if (MsgBox("Close " n " hidden " proc " window(s)?", APP_NAME, "YesNo Icon!") != "Yes")
            return ""
    }
    if quietClose
        StartQuiet(8000)
    for e in g_Hidden.Clone()
        if (e.proc = proc)
            Dismiss(e)
    ForgetProc(proc)
    SaveHidden()
    if refreshNow
        RefreshTray()
    said := "Closed all " proc " windows"
    if announceResult
        SayAfterTrayChange(said)
    DebugLog("CloseGroup completed: app=" proc " remainingHidden=" g_Hidden.Length, "INFO")
    return said
}

CloseAllHidden(
    announceResult := true,
    refreshNow := true,
    quietClose := true,
    *
) {
    global g_Hidden, g_Cfg, APP_NAME
    n := g_Hidden.Length
    DebugLog("CloseAllHidden requested: count=" n, "INFO")
    if (!n) {
        Nope()
        return ""
    }

    if (g_Cfg.Get("ConfirmCloseAll", "1") = "1"
            && MsgBox("Close all " n " hidden window(s)?", APP_NAME, "YesNo Icon!") != "Yes")
        return ""

    if quietClose
        StartQuiet(8000)
    for e in g_Hidden.Clone()
        Dismiss(e)
    g_Hidden := []
    SaveHidden()
    if refreshNow
        RefreshTray()
    said := "Closed all hidden windows"
    if announceResult
        SayAfterTrayChange(said)
    DebugLog("CloseAllHidden completed", "INFO")
    return said
}

ForgetProc(proc) {
    global g_Hidden
    i := g_Hidden.Length
    while (i >= 1) {
        if (g_Hidden[i].proc = proc)
            g_Hidden.RemoveAt(i)
        i--
    }
}

RestoreAll(*) {
    RestoreEverything(true)
}

; The body of RestoreAll. `full` chooses the wording, not whether to speak.
;
; Ctrl+Shift+L does not provoke the notification-area re-read when the icon is
; removed, while restoring the last window one at a time did. Reusing this exact
; sequence but staying SILENT still chattered -- which identifies the mechanism:
; it is the speaking, not the reveal order. That was diagnosed back when holding
; the floor meant cancelSpeech, which needs something of ours in progress to cut
; the shell off with. The quiet window does not need it, but the utterance stays
; -- it is also what tells you the restore happened.
;
; `saySummary` says whether THIS caller needs an utterance to cover the
; notification-area reflow.
;
; Ctrl+Shift+L is empirically quiet without one, so it passes false. Restoring
; the last window from the popup is not, so it passes true. (The sentence used
; to have to be a long one, since cancelSpeech only held the floor while we were
; still speaking. The quiet window removed that constraint; the wording is left
; alone because nothing depends on shortening it.)
; Either way nothing is said when HideIconWhenEmpty is off, since
; then no icon is removed and there is no reflow to cover.
; NB: the parameter is NOT called "announce" -- AHK variable names are
; case-insensitive, so that would shadow the global Announce() function and
; calling it below fails with "type Integer has no method named Call".
BuildRestoreAllOrder(entries) {
    ordered := []
    i := 1

    ; Individually hidden windows retain their normal oldest-to-newest order.
    ; A contiguous hide-all batch was recorded foreground-to-bottom; reverse
    ; only that block so it is shown bottom-to-top. The original foreground is
    ; therefore activated last and the original Alt+Tab Z-order is rebuilt.
    while (i <= entries.Length) {
        e := entries[i]
        batchId := e.HasOwnProp("batchId") ? e.batchId : 0
        if (!batchId) {
            ordered.Push(e)
            i++
            continue
        }

        block := []
        while (i <= entries.Length) {
            candidate := entries[i]
            candidateBatch := candidate.HasOwnProp("batchId") ? candidate.batchId : 0
            if (candidateBatch != batchId)
                break
            block.Push(candidate)
            i++
        }
        j := block.Length
        while (j >= 1) {
            ordered.Push(block[j])
            j--
        }
    }
    return ordered
}

RestoreEverything(saySummary) {
    global g_Hidden, g_Restoring, g_Cfg, g_FocusBridgeGui, NATIVE_RESTORE_HANDOFF_SETTLE
    startedAt := A_TickCount
    DebugLog("RestoreEverything requested: count=" g_Hidden.Length
        " nativeHandoff=1", "INFO")

    ; No foreground change will occur when there is nothing to restore, so the
    ; ordinary explicit result remains useful here. Successful restores below
    ; deliberately have no MiniTray-authored speech at all.
    if (!g_Hidden.Length) {
        if (saySummary) {
            StartQuiet(700)
            SayQuietFinal("no windows hidden", 500)
        } else {
            EndQuiet()
            Nope()
        }
        return
    }

    StartQuiet()
    entries := BuildRestoreAllOrder(g_Hidden.Clone())
    n := entries.Length
    last := n ? entries[n] : 0

    ; Reveal every non-final window without activation so neither Windows nor
    ; NVDA has to process a chain of intermediate foreground changes.
    g_Restoring := true
    for i, e in entries {
        if (i = n)
            continue
        RevealBatchFast(e)
    }
    g_Restoring := false

    g_Hidden := []
    bridgePrimed := false
    if last {
        ; Cross the hidden bridge, reveal the intended final foreground window
        ; without activating it, then complete all MiniTray-owned tray/disk work
        ; while NVDA is still quiet and the bridge still owns foreground.
        bridgePrimed := PrimeBatchFocusBridge()
        RevealBatchFast(last)
    }

    try {
        SaveHidden()
        RefreshTray(true)
    } catch Error as err {
        DebugException("Native restore-all finalization failed", err)
    }

    if last {
        ; This is the handoff boundary. No custom restore title/focus sequence,
        ; cache replay, browser guard, or delayed focus report follows it.
        EndQuiet()
        ; Ctrl+Shift+L restores the entire stack. Let the NVDA plugin prepend
        ; this result to the same deterministic title/focus sequence so no
        ; separate utterance can be interrupted by the foreground transition.
        SignalNativeNvdaRestore(last, saySummary ? "all windows restored" : "")
        Sleep NATIVE_RESTORE_HANDOFF_SETTLE
        activated := ActivateEntryBatchFast(last)
        if (!activated)
            activated := ForceForegroundWindow(last.hwnd, 0.06)
        if activated
            RememberUserForeground(last.hwnd)
        if IsObject(g_FocusBridgeGui)
            try g_FocusBridgeGui.Hide()

        DebugLog("Restore-all native final activation: hwnd=" last.hwnd
            " bridgePrimed=" bridgePrimed
            " activated=" activated
            " actualForeground=" DllCall("User32\GetForegroundWindow", "Ptr"), "DEBUG")
    } else {
        EndQuiet()
    }

    DebugLog("RestoreEverything native handoff completed: restored=" n
        " foreground=" DllCall("User32\GetForegroundWindow", "Ptr")
        " elapsedMs=" (A_TickCount - startedAt), "INFO")
}

FinalizeRestoreAllBatch(startedAt, restoredCount, *) {
    global g_Hidden
    try {
        SaveHidden()
        RefreshTray()
    } catch Error as err {
        DebugException("Deferred restore-all finalization failed", err)
    }
    DebugLog("RestoreEverything completed: restored=" restoredCount
        " remainingHidden=" g_Hidden.Length
        " elapsedMs=" (A_TickCount - startedAt), "INFO")
}

RestoreLast(*) {
    global g_Hidden
    if (g_Hidden.Length = 0) {
        StartQuiet(700)
        SayQuietFinal("no windows hidden", 500)
        return
    }
    ; Hotkey and tray restores intentionally share one activation path.
    RestoreOne(g_Hidden[g_Hidden.Length].hwnd, true)
}

Prune() {
    global g_Hidden, g_Transitioning
    ; Self-heal: our main window must never be visible. If anything has shown
    ; it, put it back rather than leaving a blank window in the Alt+Tab list.
    if DllCall("User32\IsWindowVisible", "Ptr", A_ScriptHwnd)
        try WinHide("ahk_id " A_ScriptHwnd)

    ; Explorer owns ITaskbarList. Recreate the COM object after a shell restart
    ; and re-delete taskbar buttons for surviving minimize-backed entries.
    if RefreshShellIdentity()
        SetTimer(ReapplyHiddenTaskbarTabs, -700)

    changed := false
    i := g_Hidden.Length
    while (i >= 1) {
        if !WindowMatchesRecord(g_Hidden[i]) {
            g_Hidden.RemoveAt(i)
            changed := true
        }
        i--
    }

    ; A transition should normally be removed by finally. Drop stale entries
    ; if a target vanished during the operation so future events are not muted.
    staleTransitions := []
    for hwnd, started in g_Transitioning
        if (!WinExist("ahk_id " hwnd) || A_TickCount - started > 10000)
            staleTransitions.Push(hwnd)
    for hwnd in staleTransitions
        g_Transitioning.Delete(hwnd)

    if (changed)
        SaveHidden(), RefreshTray()
}

; =============================================================================
;  CRASH RECOVERY
; =============================================================================
; OnExit covers clean exits and reloads. It does not cover a crash or a kill
; from Task Manager - and a window left hidden that way is unreachable by any
; means short of killing its process. The hidden set is mirrored to the INI on
; every change and re-adopted at startup.
SaveHidden() {
    global g_Hidden, INI_FILE, HID_SEC
    try IniDelete(INI_FILE, HID_SEC)
    for i, e in g_Hidden {
        batchId := e.HasOwnProp("batchId") ? e.batchId : 0
        batchRank := e.HasOwnProp("batchRank") ? e.batchRank : 0
        ; v2 keeps hide-all batch order across a MiniTray restart. The title is
        ; still the final field and may contain additional pipe characters.
        IniWrite("v2|" e.hwnd "|" e.pid "|" e.how "|" e.focus "|"
               batchId "|" batchRank "|" e.proc "|" e.title
               , INI_FILE, HID_SEC, "W" i)
    }
}

AdoptOrphans() {
    global g_Hidden, INI_FILE, HID_SEC
    raw := ""
    try raw := IniRead(INI_FILE, HID_SEC)
    catch
        return
    for line in StrSplit(raw, "`n", "`r") {
        if !(p := InStr(line, "="))
            continue
        f := StrSplit(SubStr(line, p + 1), "|")
        if (f.Length < 5)
            continue

        ; v2: v2|hwnd|pid|how|focus|batchId|batchRank|proc|title
        ; Older records remain accepted. In both formats the title is the last
        ; logical field and may itself contain pipe characters.
        if (f[1] = "v2" && f.Length >= 9) {
            hwnd := f[2] + 0
            pid := f[3] + 0
            how := f[4]
            focus := f[5] + 0
            batchId := f[6]
            batchRank := f[7] + 0
            proc := f[8]
            title := JoinFrom(f, 9, "|")
        } else if (f.Length >= 6) {
            hwnd := f[1] + 0
            pid := f[2] + 0
            how := f[3]
            focus := f[4] + 0
            batchId := 0
            batchRank := 0
            proc := f[5]
            title := JoinFrom(f, 6, "|")
        } else {
            hwnd := f[1] + 0
            pid := f[2] + 0
            how := f[3]
            focus := 0
            batchId := 0
            batchRank := 0
            proc := f[4]
            title := JoinFrom(f, 5, "|")
        }

        if (!WinExist("ahk_id " hwnd) || IsOwnWindow(hwnd))
            continue                     ; a recycled HWND could now be ours
        ; the HWND could have been recycled by an unrelated window
        try {
            if (WinGetPID("ahk_id " hwnd) != pid)
                continue
            exe := StrLower(WinGetProcessName("ahk_id " hwnd))
        } catch
            continue

        ; Do not re-adopt an Explorer window hidden by the old minimize plus
        ; DeleteTab strategy. Put it back on the taskbar and restore it once,
        ; then require process isolation for future Explorer hides.
        if (exe = "explorer.exe" && how = "min") {
            TaskbarTab(hwnd, true)
            try WinRestore("ahk_id " hwnd)
            continue
        }

        if DllCall("User32\IsWindowVisible", "Ptr", hwnd) && how != "min"
            continue                                  ; not actually hidden
        g_Hidden.Push({ hwnd: hwnd, pid: pid, how: how, proc: proc
                      , title: title, focus: focus
                      , batchId: batchId, batchRank: batchRank })
    }
    SaveHidden()
}

; =============================================================================
;  HELPERS  (grouping, speech timing, tray icon state)
; =============================================================================
; =============================================================================
;  TRAY MENU
; =============================================================================
GroupByProcess() {
    global g_Hidden
    order := [], groups := Map()
    groups.CaseSense := false

    ; Render the hidden-window stack newest-first. The underlying array remains
    ; oldest-first so RestoreLast(), crash recovery, and restore-all activation
    ; semantics stay unchanged. Walking backward makes the top tray item the
    ; window/application most recently hidden, and also orders each app's
    ; submenu with its newest hidden window first.
    i := g_Hidden.Length
    while (i >= 1) {
        e := g_Hidden[i]
        if !groups.Has(e.proc) {
            groups[e.proc] := []
            order.Push(e.proc)
        }
        groups[e.proc].Push(e)
        i--
    }
    return { order: order, groups: groups }
}

; Speak once the dust has settled. Activating a window, restoring the focused
; control inside it, and adding or removing our tray icon all make the shell
; raise events that a screen reader announces - and each of those cancels
; whatever it was already saying. Speaking immediately therefore gets us talked
; over; waiting means we are the last one to the microphone. Stay quiet for the
; whole gap, so the first thing actually heard is ours.
;
; WHY NOT cancelSpeech
;   It can only INTERRUPT, never pre-empt. NVDA queues an announcement the
;   instant focus lands, and with a synth that renders on a background feeder
;   thread (SAPI5 mixers, dual-voice add-ons) the audio is already on its way
;   out before the next cancel arrives -- the log shows the render happening
;   for utterances we thought we had cancelled. No tick interval wins that
;   race; the old 10 ms one only shortened each fragment.
;
; HOW THIS WORKS INSTEAD
;   Suppression happens inside NVDA. We "speak" a sentinel through the same
;   controller client, and the minitrayQuiet global plugin drops speech before
;   anything is synthesised:
;
;       Chr(1) "MTQUIET:1200" Chr(1)    open a 1200 ms quiet window
;       Chr(1) "MTQUIET:0"    Chr(1)    close it now
;       Chr(1) "MTFINAL:text" Chr(1)    speak text without reopening the floor
;       Chr(1) "MTFINALFOCUS:hwnd:token:text" Chr(1)
;                                          speak text, then post focus callback
;       Chr(1) "MTREPORTLINE:hwnd:pid" Chr(1)
;                                          ask NVDA to read the focused caret line
;       Chr(1) "MTNATIVERESTORE:hwnd:pid" Chr(1)
;                                          release MiniTray speech ownership; the
;                                          next real activation is native NVDA
;
;   The plugin never voices the control sentinels. MTFINAL is the one exception:
;   its payload is spoken through the original NVDA speech function while the
;   quiet window remains active, so later focus events cannot overtake it.
;   The plugin also caps any single window at
;   1500 ms, which is why a longer quiet period is held open by RE-SENDING
;   rather than by asking for one big window: if this script dies between open
;   and close, NVDA is back to normal within a second and a half instead of
;   staying mute. NVDA+Shift+M reports the state and clears it by hand.
;
;   QuietPlugin=0 in the INI disables all of it. Do that on any machine where
;   the add-on is not installed -- without the plugin the sentinel is just text,
;   and NVDA reads it out.
StartQuiet(maxMs := 0, cancelCurrent := true) {
    global g_QuietUntil, QUIET_MAX, QUIET_CHUNK, QUIET_REFRESH, g_Cfg
    ; A previous privileged-announcement tail may still have an EndQuiet timer.
    ; Cancel it before arming a new transaction, or a rapid second Shift+Escape
    ; could have its quiet window closed by the first transaction's timer.
    SetTimer(EndQuiet, 0)
    if (g_Cfg.Get("Speak", "0") != "1")
        return                           ; without speech of our own, going
    if (g_Cfg.Get("QuietPlugin", "1") != "1")  ;   quiet would just delete
        return                                 ;   other people's announcements
    if (!maxMs)
        maxMs := QUIET_MAX
    g_QuietUntil := A_TickCount + maxMs

    ; Always use the original MTQUIET protocol. Every conceptSphereQuiet build
    ; understands it, so a temporary script/plugin version mismatch can never
    ; expose a private control token or the internal focus bridge to speech.
    ; The protected result command performs cancellation or queue insertion
    ; inside NVDA, where active MiniTray speech can be identified safely.
    SendQuiet(QUIET_CHUNK)
    SetTimer(QuietRefresh, -QUIET_REFRESH)
}

; Closing is not optional. Our own Announce() goes through the very speak() the
; plugin is wrapping, so a window left open swallows the line it existed to
; protect. Every path must either hand the quiet window on to something that
; closes it, or close it here.
EndQuiet() {
    global g_QuietUntil
    SetTimer(EndQuiet, 0)
    if (!g_QuietUntil)
        return
    g_QuietUntil := 0
    SetTimer(QuietRefresh, 0)
    SendQuiet(0)
}

QuietRefresh() {
    global g_QuietUntil, QUIET_CHUNK, QUIET_REFRESH
    if (!g_QuietUntil)
        return
    if (A_TickCount >= g_QuietUntil) {
        EndQuiet()
        return
    }
    SendQuiet(QUIET_CHUNK)
    SetTimer(QuietRefresh, -QUIET_REFRESH)
}

; cancel=false: a refresh must not interrupt anything. There is nothing of ours
; playing to protect, and cancelling on every tick was the old mistake.
SendQuiet(ms) {
    Announce(Chr(1) "MTQUIET:" ms Chr(1), false)
}

; The popup's keyboard gestures are implemented as AHK hotkeys, so NVDA does
; not receive AppsKey, Up, Down, Left or Right through its normal input hook.
; Tell conceptSphereQuiet explicitly that genuine popup navigation is about to
; occur. It can then cancel only the protected opening item phrase and let
; the newly navigated ListBox item speak immediately.
ReleasePopupSpeech() {
    Announce(Chr(1) "MTNAV" Chr(1), false)
}

SendCloseMenuResult(text) {
    global g_PopupGui, g_Cfg
    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        return
    }
    if (g_Cfg.Get("QuietPlugin", "1") != "1") {
        EndQuiet()
        Announce(text)
        return
    }
    Announce(
        Chr(1) "MTCLOSEMENU:" g_PopupGui.Hwnd ":" text Chr(1),
        false
    )
}

SendCloseTrayResult(text, removeIcon) {
    global g_Cfg
    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        if removeIcon
            CompleteDeferredTrayIconHide()
        return
    }
    if (g_Cfg.Get("QuietPlugin", "1") != "1") {
        EndQuiet()
        Announce(text)
        Send "#b"
        if removeIcon
            SetTimer(CompleteDeferredTrayIconHide, -300)
        return
    }
    Announce(
        Chr(1) "MTCLOSETRAY:" A_ScriptHwnd ":" (removeIcon ? 1 : 0)
            ":" text Chr(1),
        false
    )
}

CompleteDeferredTrayIconHide(wParam := 0, lParam := 0, msg := 0, hwnd := 0) {
    global g_Hidden, g_Cfg
    if (!g_Hidden.Length && g_Cfg.Get("HideIconWhenEmpty", "0") = "1") {
        MTIcon_SetHidden(true, "deferred hide: list empty")
        DebugLog("Deferred MiniTray icon hide completed after tray focus moved", "INFO")
    } else {
        MTIcon_SetHidden(false, "deferred hide skipped: icon still required")
        DebugLog("Deferred MiniTray icon hide skipped; icon still required", "DEBUG")
    }
    return 0
}

; Speak one command-result announcement through conceptSphereQuiet without
; dropping the quiet window first. This closes the race in EndQuiet()+Announce(),
; where queued foreground speech could enter between those two controller calls.
SayQuietFinal(text, tailMs := -1, cancel := false) {
    global g_QuietUntil, QUIET_FINAL_TAIL, g_Cfg

    if (tailMs < 0)
        tailMs := QUIET_FINAL_TAIL

    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        return
    }

    ; Without the plugin this sentinel would be read literally, so use the
    ; ordinary path when QuietPlugin has been disabled.
    if (g_Cfg.Get("QuietPlugin", "1") != "1") {
        EndQuiet()
        Announce(text)
        return
    }

    g_QuietUntil := A_TickCount + tailMs
    ; The plugin owns cancellation and queueing. A controller-level cancel here
    ; would truncate the previous protected MiniTray announcement before the
    ; plugin had a chance to preserve it.
    Announce(Chr(1) "MTFINAL:" text Chr(1), false)
    SetTimer(EndQuiet, -tailMs)
}

; Arm NVDA before a single-window hide can transfer foreground. This prevents
; a browser revealed underneath from automatically switching between browse and
; focus mode merely because MiniTray moved Windows focus. The plugin reference-
; counts this guard with its existing browser restore guard, so rapid queued
; hide/restore actions cannot restore the user's settings too early.
BeginNvdaModeGuard(timeoutMs := 0) {
    global g_NvdaModeGuardSerial, g_Cfg
    global NVDA_MODE_GUARD_SETTLE, NVDA_MODE_GUARD_TIMEOUT

    if (g_Cfg.Get("QuietPlugin", "1") != "1")
        return 0
    if !timeoutMs
        timeoutMs := NVDA_MODE_GUARD_TIMEOUT

    token := g_NvdaModeGuardSerial
    g_NvdaModeGuardSerial := (g_NvdaModeGuardSerial >= 0x7FFFFFFE) ? 1 : g_NvdaModeGuardSerial + 1
    Announce(Chr(1) "MTMODEGUARD:" token ":" timeoutMs Chr(1), false)
    Sleep NVDA_MODE_GUARD_SETTLE
    return token
}

EndNvdaModeGuard(token) {
    if !token
        return
    Announce(Chr(1) "MTMODEGUARD:" token ":0" Chr(1), false)
}

; The desktop is unusually noisy after the last ordinary window is hidden.
; MTHIDEFINAL is retained for desktop/hide-all results. Single-window hides
; that expose another real window use MTHIDEFOCUS instead, passing that window's
; HWND/PID so NVDA can append its focused control deterministically.
SayDeferredHideFinal(text, tailMs := 1000) {
    global g_QuietUntil, g_Cfg

    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        return
    }

    if (g_Cfg.Get("QuietPlugin", "1") != "1") {
        EndQuiet()
        Announce(text)
        return
    }

    g_QuietUntil := A_TickCount + tailMs
    Announce(Chr(1) "MTHIDEFINAL:" tailMs ":" text Chr(1), false)
    SetTimer(EndQuiet, -tailMs)
}

; Single-window hide handoff. ``text`` already contains
;     <hidden app> hidden. <newly exposed title>
; and targetHwnd/targetPid identify ONLY the newly exposed window. NVDA uses
; those identifiers to append that window's focused control after a fixed gap.
SayDeferredHideFocus(text, targetHwnd, targetPid, tailMs := 1200) {
    global g_QuietUntil, g_Cfg

    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        return
    }

    if (!targetHwnd || g_Cfg.Get("QuietPlugin", "1") != "1") {
        EndQuiet()
        Announce(text)
        return
    }

    g_QuietUntil := A_TickCount + tailMs
    Announce(
        Chr(1) "MTHIDEFOCUS:" tailMs ":" targetHwnd ":" targetPid ":" text Chr(1),
        false
    )
    SetTimer(EndQuiet, -tailMs)
}

; Legacy compatibility helper. Native restore paths no longer call this.
; The dual-voice synthesizer can accept CallbackCommand without ever executing
; it, truncating the surrounding speech. MTRESTOREFINAL contains plain text
; only; the plugin silently fixes NVDA's caches before speaking it.
SayDeferredRestoreFinal(text, e, tailMs := 1500) {
    global g_QuietUntil, g_Cfg

    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        return
    }

    if (!e || g_Cfg.Get("QuietPlugin", "1") != "1") {
        EndQuiet()
        Announce(text)
        return
    }

    g_QuietUntil := A_TickCount + tailMs
    Announce(
        Chr(1) "MTRESTOREFINAL:" tailMs ":" e.hwnd ":" e.pid ":" text Chr(1),
        false
    )
    SetTimer(EndQuiet, -tailMs)
}

SaySoon(text, focusEntry := 0) {
    global g_SoonSay, g_SoonFocus, SPEECH_SETTLE, g_Cfg
    if (g_Cfg.Get("Speak", "0") != "1") {
        if focusEntry
            SetTimer(FocusRecordNow.Bind(focusEntry), -80)
        return
    }
    g_SoonSay := text
    g_SoonFocus := focusEntry
    StartQuiet(SPEECH_SETTLE + 200)
    SetTimer(FlushSoonSay, -SPEECH_SETTLE)
}

FlushSoonSay() {
    global g_SoonSay, g_SoonFocus
    if (g_SoonSay = "")
        return
    text := g_SoonSay
    focusEntry := g_SoonFocus
    g_SoonSay := "", g_SoonFocus := 0
    if focusEntry
        QueueFocusAfterTitle(text, focusEntry)
    else
        SayQuietFinal(text)              ; bypass the gate for this result only
}

; Speaking at the moment of the restore LOSES the race: the icon is not removed
; until ICON_HIDE_DELAY later, so the shell's notification-area re-read starts
; after we have already finished talking. The line is queued instead and spoken
; just after the icon actually goes, where cancelSpeech can cut the shell off.
; Every path out of here must either hand the quiet window on to something that
; will close it, or close it here -- a window left open mutes the screen reader
; until QUIET_MAX expires, and swallows our own line with it.
SayAfterTrayChange(text, focusEntry := 0) {
    global g_PendingSay, g_PendingFocus, g_PendingArmed, g_Hidden, g_Cfg
    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        if focusEntry
            SetTimer(FocusRecordNow.Bind(focusEntry), -80)
        return
    }

    removing := (!g_Hidden.Length && g_Cfg.Get("HideIconWhenEmpty", "0") = "1")
    if (!removing) {
        if (text != "")                  ; nothing to talk over; just say it,
            SaySoon(text, focusEntry)    ;   once the focus events have settled
        else {
            EndQuiet()
            if focusEntry
                SetTimer(FocusRecordNow.Bind(focusEntry), -80)
        }
        return
    }
    ; The icon is about to go, and that reflow is what the shell reads aloud.
    ; Queue for just after the removal: speak if we have something to say,
    ; otherwise cancel silently - which suppresses the re-read on its own.
    g_PendingSay := text
    g_PendingFocus := focusEntry
    g_PendingArmed := true
    StartQuiet()                         ; closed in FlushPendingSay
}

FlushPendingSay() {
    global g_PendingSay, g_PendingFocus, g_PendingArmed
    if (!g_PendingArmed)
        return
    text := g_PendingSay
    focusEntry := g_PendingFocus
    g_PendingSay := "", g_PendingFocus := 0, g_PendingArmed := false
    if (text != "") {
        if focusEntry
            QueueFocusAfterTitle(text, focusEntry)
        else
            SayQuietFinal(text)
    } else {
        ; Nothing is being announced, so simply close the established MTQUIET
        ; window. Do not emit a second private cancellation protocol: the focus
        ; bridge and tray reflow are already covered by the quiet transaction.
        EndQuiet()
        if focusEntry
            SetTimer(FocusRecordNow.Bind(focusEntry), -80)
    }
}

; Idempotent: if something was hidden again inside the delay window, this
; correctly leaves the icon showing.
UpdateTrayIcon() {
    global g_Hidden, g_Cfg, g_PendingSay, ANNOUNCE_AFTER_HIDE
    global ICON_HIDE_RETRY, ICON_HIDE_RETRIES
    static tries := 0

    if (g_Hidden.Length || g_Cfg.Get("HideIconWhenEmpty", "0") != "1") {
        tries := 0
        MTIcon_SetHidden(false, "windows hidden, or hide-when-empty off")
        FlushPendingSay()                ; nothing was removed; no need to wait
        return
    }
    ; Don't delete the icon out from under the notification area while focus is
    ; sitting there - that reflow is what a screen reader reads aloud. Wait for
    ; focus to move on instead; the icon lingering a few seconds costs nothing.
    if (TrayHasFocus() && ++tries <= ICON_HIDE_RETRIES) {
        SetTimer(UpdateTrayIcon, -ICON_HIDE_RETRY)
        return
    }
    tries := 0
    MTIcon_SetHidden(true, "list empty, tray focus clear")
    if (g_PendingSay != "")
        SetTimer(FlushPendingSay, -ANNOUNCE_AFTER_HIDE)
}

; True while keyboard focus is inside the taskbar or the notification area,
; including the Windows 11 overflow flyout (a XAML island, not the old
; NotifyIconOverflowWindow).
TrayHasFocus() {
    return IsTrayWindow(FocusedWindow())
}

; True if hwnd is, or sits inside, the taskbar or notification area.
IsTrayWindow(hwnd) {
    static TRAY := ["Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow"
                  , "TopLevelWindowForOverflowXamlIsland", "XamlExplorerHostIslandWindow"]
    static GA_ROOT := 2

    if !hwnd
        return false
    root := DllCall("User32\GetAncestor", "Ptr", hwnd, "UInt", GA_ROOT, "Ptr")
    if !root
        root := hwnd
    try cls := WinGetClass("ahk_id " root)
    catch
        return false
    for c in TRAY
        if (cls = c)
            return true
    return false
}

; GetForegroundWindow alone isn't enough: while a tray flyout is up, the focused
; control belongs to the shell thread, so ask GUITHREADINFO for the foreground
; thread's focus and fall back only if that is unavailable.
FocusedWindow() {
    size := 8 + (A_PtrSize * 6) + 16     ; cbSize, flags, 6 HWNDs, RECT
    gti  := Buffer(size, 0)
    NumPut("UInt", size, gti, 0)
    if !DllCall("User32\GetGUIThreadInfo", "UInt", 0, "Ptr", gti)
        return DllCall("User32\GetForegroundWindow", "Ptr")
    hwnd := NumGet(gti, 8 + A_PtrSize, "Ptr")        ; hwndFocus
    if !hwnd
        hwnd := NumGet(gti, 8, "Ptr")                ; hwndActive
    if !hwnd
        hwnd := DllCall("User32\GetForegroundWindow", "Ptr")
    return hwnd
}

MenuLabel(title) {
    global MAX_LABEL
    if (StrLen(title) > MAX_LABEL)
        title := SubStr(title, 1, MAX_LABEL - 3) "..."
    return title
}

; =============================================================================
;  TRAY POPUP
; =============================================================================
; AutoHotkey's own tray menu is deliberately NOT used.
;
; A Win32 popup menu has to be owned by a foreground window, and the only
; window this script owns is AHK's message window: unnamed, contentless, and
; titled with the full exe path. Hosting a menu there is what made a screen
; reader announce "D:\...\MiniTray.exe  edit multiline blank" every time the
; menu was dismissed -- and hiding, renaming or restyling that window cannot
; fix it, because the accessibility tree does not care whether a window is
; visible. The window has to exist, has to take the foreground to show a menu,
; and cannot be renamed (AHK identifies a previous instance by its title).
;
; So the tray click is intercepted and a real Gui is shown instead: class
; AutoHotkeyGUI, titled "MiniTray".
;
; The popup presents one flat accessible level at a time.
;   Top level
;     - an app with exactly one hidden window is represented by that window title;
;     - an app with two or more hidden windows is represented as "<app> menu";
;     - Settings is always the final row.
;   App context level
;     - hidden window titles, then Restore all and Close all.
;   Window context level
;     - Restore and Close.
;   Settings level
;     - Window rules, Options, and Exit.
;
;   Up / Down                       move within the current level and wrap
;   Enter / left click              restore a window or restore all app windows
;   Shift+Enter / Shift+left click  close a window or close all app windows
;   Right on an app                 open its app context level
;   Right-click / Applications      open app, window, or Settings context
;   Left / Escape                   return one level (Escape closes at top)

TrayIconMsg(wParam, lParam, msg, hwnd) {
    static WM_LBUTTONUP := 0x202
    static WM_LBUTTONDBLCLK := 0x203
    static WM_RBUTTONUP := 0x205
    static WM_RBUTTONDBLCLK := 0x206

    ; With NOTIFYICON_VERSION_4 the icon ID may occupy the high word, so use
    ; only the low-word notification code.
    event := lParam & 0xFFFF
    DebugLog("Tray icon notification: event=0x" Format("{:04X}", event), "DEBUG")

    ; Open the application list immediately. No double-click interval or
    ; accessibility-settle timer is allowed to delay the popup or its directly
    ; focused first-item announcement.
    if (event = WM_RBUTTONUP) {
        BeginTrayPopupOpen()
        return 0
    }

    ; The first right-click already opens the popup immediately. Ignore the
    ; follow-up double-click notification rather than replacing the new menu
    ; with the obsolete global-action context level.
    if (event = WM_RBUTTONDBLCLK)
        return 0

    if (event = WM_LBUTTONUP || event = WM_LBUTTONDBLCLK)
        BeginTrayPopupOpen()
    return 0                             ; suppress AHK's built-in tray menu
}

TrayPopupIsVisible() {
    global g_PopupGui
    return IsObject(g_PopupGui)
        && DllCall("User32\IsWindowVisible", "Ptr", g_PopupGui.Hwnd)
}

IsPopupReturnWindow(hwnd) {
    if (!hwnd || !DllCall("User32\IsWindow", "Ptr", hwnd)
            || !DllCall("User32\IsWindowVisible", "Ptr", hwnd)
            || IsOwnWindow(hwnd) || FindHidden(hwnd) || IsTrayWindow(hwnd))
        return false
    return true
}

RememberUserForeground(hwnd) {
    global g_LastUserForegroundHwnd, g_LastUserFocusCtrl

    if !IsPopupReturnWindow(hwnd)
        return

    ; Do not replace the real Explorer CabinetWClass with the transient
    ; InputSiteWindowClass that Windows 11 can foreground after restoration.
    resolved := ResolveExplorerActiveWindow(hwnd)
    if (resolved != hwnd) {
        DebugLog(
            "RememberUserForeground kept real Explorer window: helper="
            DebugWindow(hwnd) " resolved=" DebugWindow(resolved),
            "DEBUG"
        )
        hwnd := resolved
    }

    ; Store only a genuine Alt+Tab target. Shell/input helper HWNDs are not
    ; useful popup-return or later hide targets.
    if !IsAltTabWindow(hwnd)
        return

    g_LastUserForegroundHwnd := hwnd
    ctrl := 0
    try ctrl := ControlGetFocus("ahk_id " hwnd)
    g_LastUserFocusCtrl := ctrl
}

CapturePopupReturnFocus() {
    global g_LastUserForegroundHwnd, g_LastUserFocusCtrl
    global g_PopupReturnHwnd, g_PopupReturnCtrl

    hwnd := DllCall("User32\GetForegroundWindow", "Ptr")
    if IsPopupReturnWindow(hwnd) {
        g_PopupReturnHwnd := hwnd
        ctrl := 0
        try ctrl := ControlGetFocus("ahk_id " hwnd)
        g_PopupReturnCtrl := ctrl
        RememberUserForeground(hwnd)
    } else {
        g_PopupReturnHwnd := g_LastUserForegroundHwnd
        g_PopupReturnCtrl := g_LastUserFocusCtrl
    }

    DebugLog("Captured tray popup return focus: hwnd=" g_PopupReturnHwnd
        " ctrl=" g_PopupReturnCtrl, "DEBUG")
}

RestorePopupReturnFocus(closeTargetHwnd := 0, closeTargetPid := 0, attempt := 0, *) {
    global g_PopupGui, g_PopupReturnHwnd, g_PopupReturnCtrl

    ; Let WinClose finish. If the target process owns a visible prompt, leave
    ; that prompt in front rather than stealing focus back to the old window.
    foreground := DllCall("User32\GetForegroundWindow", "Ptr")
    if (closeTargetPid && foreground && !IsOwnWindow(foreground)) {
        fgPid := 0
        try fgPid := WinGetPID("ahk_id " foreground)
        if (fgPid = closeTargetPid && foreground != closeTargetHwnd) {
            DebugLog("Tray close left target-process prompt in foreground: "
                DebugWindow(foreground), "INFO")
            g_PopupReturnHwnd := 0
            g_PopupReturnCtrl := 0
            return
        }
    }

    if (closeTargetHwnd && WinExist("ahk_id " closeTargetHwnd)) {
        if (attempt < 12) {
            SetTimer(
                RestorePopupReturnFocus.Bind(
                    closeTargetHwnd,
                    closeTargetPid,
                    attempt + 1
                ),
                -50
            )
            return
        }
        ; A still-existing target after 600 ms is probably waiting for user
        ; input (for example a save prompt). Do not pull focus away from it.
        if (foreground && foreground != (IsObject(g_PopupGui) ? g_PopupGui.Hwnd : 0)) {
            g_PopupReturnHwnd := 0
            g_PopupReturnCtrl := 0
            return
        }
    }

    ; Windows may already have transferred focus to a usable destination.
    if IsPopupReturnWindow(foreground) {
        g_PopupReturnHwnd := 0
        g_PopupReturnCtrl := 0
        return
    }

    restored := false
    if IsPopupReturnWindow(g_PopupReturnHwnd) {
        restored := ForceForegroundWindow(g_PopupReturnHwnd, 0.08)
        if (restored && g_PopupReturnCtrl
                && DllCall("User32\IsWindow", "Ptr", g_PopupReturnCtrl))
            ForceControlFocus(g_PopupReturnHwnd, g_PopupReturnCtrl)
    }

    if !restored {
        desktopHwnd := FocusDesktop()
        restored := !!desktopHwnd
    }

    DebugLog("Tray close focus recovery: restored=" restored
        " hwnd=" g_PopupReturnHwnd " ctrl=" g_PopupReturnCtrl, "INFO")
    g_PopupReturnHwnd := 0
    g_PopupReturnCtrl := 0
}

RunPopupAction(action, restoreFocusAfter := false, closeTargetHwnd := 0, *) {
    closeTargetPid := 0
    if (restoreFocusAfter && closeTargetHwnd && WinExist("ahk_id " closeTargetHwnd)) {
        try closeTargetPid := WinGetPID("ahk_id " closeTargetHwnd)
    }

    try action.Call()
    catch Error as err
        DebugException("Tray popup action failed", err)

    if restoreFocusAfter
        SetTimer(
            RestorePopupReturnFocus.Bind(closeTargetHwnd, closeTargetPid, 0),
            -80
        )
}


BeginTrayPopupOpen(*) {
    global g_PopupOpening, POPUP_OPEN_SETTLE, POPUP_OPEN_TAIL
    DebugLog("Tray popup open requested", "INFO")
    CapturePopupReturnFocus()
    ; Start suppression before the GUI exists, then show and announce it in
    ; this same invocation. There is no double-click or accessibility-settle
    ; timer, so right-click and the Applications key respond immediately.
    g_PopupOpening := true
    ; Open the quiet gate before focus moves into the ListBox, but do not issue
    ; a controller-client cancellation here. The dedicated MTMENU command is
    ; processed inside NVDA after the focus events arrive; it cancels there and
    ; speaks on the next NVDA event-loop turn, avoiding a late cancel that clips
    ; the beginning of "MiniTray menu".
    StartQuiet(POPUP_OPEN_SETTLE + POPUP_OPEN_TAIL + 500, false)
    ShowTrayPopup()
}

ShowTrayPopup(*) {
    global g_PopupGui, g_PopupLB, g_PopupItems, g_PopupProc, g_PopupMode, POPUP_OPEN_SETTLE
    global g_PopupContextHwnd, g_PopupContextParent
    if !g_PopupGui
        BuildTrayPopup()
    g_PopupProc := ""                    ; always open at the application list
    g_PopupMode := "browse"
    g_PopupContextHwnd := 0
    g_PopupContextParent := ""
    FillTrayPopup(0)                     ; populate without emitting MTNAV
    ; The popup should open directly on row 1. Select it while the ListBox is
    ; still hidden so no intermediate accessibility announcement escapes before
    ; the MTMENU transport takes ownership of the opening presentation.
    if g_PopupItems.Length
        g_PopupLB.Choose(1)

    ; Size it first, then place it near the pointer, clamped to the work area.
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    g_PopupGui.Show("Hide AutoSize")
    WinGetPos(, , &pw, &ph, "ahk_id " g_PopupGui.Hwnd)
    b := GetBounds(g_PopupGui.Hwnd, "work")
    x := Min(Max(mx - (pw // 2), b.l), b.r - pw)
    y := Min(Max(my - ph, b.t), b.b - ph)
    g_PopupGui.Show("x" x " y" y)
    try g_PopupLB.Focus()
    DebugLog("Tray popup shown: x=" x " y=" y " width=" pw " height=" ph, "DEBUG")
    AnnounceTrayPopupOpened()
}

AnnounceTrayPopupOpened() {
    global g_PopupGui, g_PopupLB, g_PopupOpening, APP_NAME, POPUP_OPEN_TAIL
    g_PopupOpening := false
    if (!IsObject(g_PopupGui)
        || !DllCall("User32\IsWindowVisible", "Ptr", g_PopupGui.Hwnd)
        || !WinActive("ahk_id " g_PopupGui.Hwnd)) {
        DebugLog("Tray popup opening announcement aborted: popup not active", "WARN")
        EndQuiet()
        return
    }

    ; MTMENU now carries the already-selected first row, not the container name.
    ; The NVDA plugin speaks this text exactly once while suppressing the popup's
    ; native dialog/list/selection-state chatter. This makes AppsKey/right-click
    ; land directly on e.g. "Microsoft Teams menu".
    firstItem := ""
    try firstItem := Trim(g_PopupLB.Text)
    if (firstItem = "") {
        ; Compatibility fallback. A current plugin can recover the focused row
        ; natively when the payload is empty; never fall back to "MiniTray menu".
        DebugLog("Tray popup first-item text unavailable; sending empty MTMENU payload", "WARN")
    } else {
        DebugLog("Sending tray popup first-item announcement: " firstItem, "DEBUG")
    }
    Announce(Chr(1) "MTMENU:" POPUP_OPEN_TAIL ":" firstItem Chr(1), false)
}

BuildTrayPopup() {
    global g_PopupGui, g_PopupLabel, g_PopupLB, APP_NAME
    g := Gui("-MaximizeBox -MinimizeBox +AlwaysOnTop +ToolWindow", APP_NAME)
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 10, g.MarginY := 10

    ; The static text immediately before the ListBox becomes its accessible
    ; label. Updating it when a context level opens gives NVDA a stable name
    ; without relying on AHK's native Menu.Show(), which was silent here.
    g_PopupLabel := g.Add("Text", "w460", APP_NAME " menu")

    ; A ListBox rather than a TreeView: one flat level at a time, announced as
    ; "item N of M", which is how a menu reads.
    g_PopupLB := g.Add("ListBox", "w460 r12 vPopupList")

    g.OnEvent("Close", (*) => HideTrayPopup())
    g.OnEvent("Escape", (*) => PopupEscape())
    g.OnEvent("ContextMenu", PopupContextMenu)
    g_PopupGui := g
}

HideTrayPopup(*) {
    global g_PopupGui, g_PopupProc, g_PopupMode, g_PopupOpening
    DebugLog("Hiding tray popup: level=" g_PopupProc " mode=" g_PopupMode, "DEBUG")
    global g_PopupContextHwnd, g_PopupContextParent
    SetTimer(AnnounceTrayPopupOpened, 0)
    wasOpening := g_PopupOpening
    g_PopupOpening := false
    g_PopupProc := ""
    g_PopupMode := "browse"
    g_PopupContextHwnd := 0
    g_PopupContextParent := ""
    if g_PopupGui
        try g_PopupGui.Hide()
    ; Only cancel suppression owned by an opening that never reached its
    ; explicit announcement. PopupThen starts its own quiet transaction before
    ; hiding, and that transaction must remain active for the restore action.
    if wasOpening
        EndQuiet()
}

PopupHasAltTabTarget() {
    ; A modal/dialog owner is not hideable, but it remains a legitimate native
    ; Alt+Tab destination. Never use the hideable chain for this decision.
    return GetNativeAltTabChain().Length > 0
}

PopupAltTabNoTarget(*) {
    global g_PopupGui, g_PopupLB

    DebugLog(
        "Alt+Tab retained MiniTray popup because no eligible window exists",
        "INFO"
    )

    ; Do not hide or rebuild the popup. Its current row and keyboard focus stay
    ; intact. The protected announcement is processed before ordinary Alt+Tab
    ; preview speech by conceptSphereQuiet.
    StartQuiet(700)
    SayQuietFinal("no windows open", 500)

    if TrayPopupIsVisible() {
        try WinActivate("ahk_id " g_PopupGui.Hwnd)
        try g_PopupLB.Focus()
    }
}

PopupAltTabClose(*) {
    HideTrayPopup()
    ; The menu-opening tail must not suppress the title of the window Windows
    ; activates through the native Alt+Tab operation.
    EndQuiet()
}

; Esc backs out of an application first, like closing a submenu.
PopupEscape(*) {
    global g_PopupProc, g_PopupMode
    EndQuiet()
    if (g_PopupMode = "windowContext") {
        PopupReturnFromWindowContext()
        return
    }
    if (g_PopupProc != "") {
        PopupReturnToApps()
        return
    }
    HideTrayPopup()
}

; Rebuild the current level. selectIndex=0 suppresses the MTNAV transport;
; the initial-open path selects row 1 itself while the ListBox is still hidden.
;
; Top level: single hidden windows or multi-window app menus, then Settings.
; There is no placeholder row when nothing is hidden, so Settings is then the
; sole cyclic item. App context: windows, Restore all, Close all. Window context:
; Restore, Close. Settings: Window rules, Options, Exit.
FillTrayPopup(selectIndex := 1, selectProc := "", selectHwnd := 0) {
    global g_PopupLabel, g_PopupLB, g_PopupItems, g_PopupProc, g_PopupMode, APP_NAME
    global g_PopupContextHwnd, g_PopupContextParent
    if !g_PopupLB
        return

    if (selectIndex > 0)
        ReleasePopupSpeech()

    rows := [], g_PopupItems := []
    grp := GroupByProcess()

    if (g_PopupMode = "windowContext") {
        if g_PopupLabel
            g_PopupLabel.Text := ""
        rows.Push("Restore")
        g_PopupItems.Push({ kind: "ctxRestoreOne", proc: g_PopupContextParent
            , hwnd: g_PopupContextHwnd })
        rows.Push("Close")
        g_PopupItems.Push({ kind: "ctxCloseOne", proc: g_PopupContextParent
            , hwnd: g_PopupContextHwnd })
    } else if (g_PopupProc = "__settings__") {
        if g_PopupLabel
            g_PopupLabel.Text := "Settings"
        rows.Push("Window rules")
        g_PopupItems.Push({ kind: "rules", proc: "", hwnd: 0 })
        rows.Push("Options")
        g_PopupItems.Push({ kind: "options", proc: "", hwnd: 0 })
        rows.Push("Exit")
        g_PopupItems.Push({ kind: "exit", proc: "", hwnd: 0 })
    } else if (g_PopupProc != "" && grp.groups.Has(g_PopupProc)) {
        if g_PopupLabel
            g_PopupLabel.Text := ""
        for e in grp.groups[g_PopupProc] {
            rows.Push(MenuLabel(e.title))
            g_PopupItems.Push({ kind: "win", proc: g_PopupProc, hwnd: e.hwnd })
        }
        rows.Push("Restore all")
        g_PopupItems.Push({ kind: "restoreGroup", proc: g_PopupProc, hwnd: 0 })
        rows.Push("Close all")
        g_PopupItems.Push({ kind: "closeGroup", proc: g_PopupProc, hwnd: 0 })
    } else {
        g_PopupProc := ""
        g_PopupMode := "browse"
        g_PopupContextHwnd := 0
        g_PopupContextParent := ""
        if g_PopupLabel
            g_PopupLabel.Text := APP_NAME " menu"
        for proc in grp.order {
            entries := grp.groups[proc]
            if (entries.Length = 1) {
                e := entries[1]
                rows.Push(MenuLabel(e.title))
                g_PopupItems.Push({ kind: "win", proc: proc, hwnd: e.hwnd })
            } else {
                rows.Push(proc " menu")
                g_PopupItems.Push({ kind: "app", proc: proc, hwnd: 0 })
            }
        }
        rows.Push("Settings")
        g_PopupItems.Push({ kind: "settings", proc: "", hwnd: 0 })
    }

    g_PopupLB.Delete()
    g_PopupLB.Add(rows)
    DebugLog("Tray popup populated: level=" g_PopupProc " mode=" g_PopupMode
        " rows=" rows.Length, "DEBUG")

    ; Returning from a context level reselects its parent window/application.
    ; Initial opening passes zero here only to avoid MTNAV; ShowTrayPopup then
    ; selects row 1 while the ListBox is hidden before focus enters the popup.
    if (selectProc != "" || selectHwnd) {
        for idx, it in g_PopupItems {
            if (selectHwnd && it.hwnd = selectHwnd) {
                selectIndex := idx
                break
            }
            if (!selectHwnd && (
                (it.kind = "app" && it.proc = selectProc)
                || (it.kind = "win" && it.proc = selectProc)
                || (it.kind = "settings" && selectProc = "__settings__")
            )) {
                selectIndex := idx
                break
            }
        }
    }

    if (selectIndex > 0 && selectIndex <= g_PopupItems.Length)
        g_PopupLB.Choose(selectIndex)
    else
        PopupClearSelection()
}

PopupClearSelection() {
    global g_PopupLB
    if !g_PopupLB
        return
    ; LB_SETCURSEL with -1 removes the selection from a single-select ListBox.
    DllCall("User32\SendMessageW", "Ptr", g_PopupLB.Hwnd, "UInt", 0x0186
          , "Ptr", -1, "Ptr", 0, "Ptr")
}

; Explicit arrow handling gives menu-style wrapping and defines the first move
; from an intentionally unselected popup: Down -> first; Up -> last.
PopupMove(direction, *) {
    global g_PopupLB, g_PopupItems, g_PopupProc, g_PopupMode
    if (!g_PopupLB || !g_PopupItems.Length)
        return

    idx := g_PopupLB.Value

    ; With nothing hidden the top level contains only Settings. Up/Down cannot
    ; actually move anywhere, so do not re-Choose(1): doing so generates a new
    ; ListBox focus event and makes NVDA repeat "Settings" on every key press.
    ; Keep the protected opening phrase intact as well; a no-op navigation key
    ; should be completely silent.
    if (g_PopupItems.Length = 1 && idx = 1) {
        DebugLog("Tray popup singleton navigation ignored: kind="
            g_PopupItems[1].kind, "DEBUG")
        return
    }

    ; A deliberate user action that really changes selection may interrupt the
    ; opening phrase and must never have its resulting item announcement
    ; swallowed by the protective tail.
    ReleasePopupSpeech()
    EndQuiet()

    if (!idx)
        idx := (direction > 0) ? 1 : g_PopupItems.Length
    else {
        idx += direction
        if (idx < 1)
            idx := g_PopupItems.Length
        else if (idx > g_PopupItems.Length)
            idx := 1
    }
    g_PopupLB.Choose(idx)
    try DebugLog("Tray popup selection: index=" idx " kind=" g_PopupItems[idx].kind
        " proc=" g_PopupItems[idx].proc " hwnd=" g_PopupItems[idx].hwnd, "DEBUG")
}

PopupEnterWindows(proc) {
    global g_PopupProc, g_PopupMode
    DebugLog("Opening application submenu: app=" proc, "INFO")
    if (proc = "")
        return
    g_PopupMode := "browse"
    g_PopupProc := proc
    FillTrayPopup(1)
}

PopupEnterWindowContext(hwnd, parentProc := "") {
    global g_PopupMode, g_PopupProc, g_PopupContextHwnd, g_PopupContextParent
    DebugLog("Opening window context: hwnd=" hwnd " parent=" parentProc, "INFO")
    if (!hwnd)
        return
    g_PopupContextHwnd := hwnd
    g_PopupContextParent := parentProc
    g_PopupMode := "windowContext"
    ; Keep g_PopupProc as the parent level so Back can restore it exactly.
    g_PopupProc := parentProc
    FillTrayPopup(1)
}

PopupEnterSettings(*) {
    global g_PopupProc, g_PopupMode
    DebugLog("Opening Settings submenu", "INFO")
    g_PopupMode := "browse"
    g_PopupProc := "__settings__"
    FillTrayPopup(1)
}

PopupReturnFromWindowContext() {
    global g_PopupMode, g_PopupProc, g_PopupContextHwnd, g_PopupContextParent
    hwnd := g_PopupContextHwnd
    parent := g_PopupContextParent
    g_PopupMode := "browse"
    g_PopupContextHwnd := 0
    g_PopupContextParent := ""
    g_PopupProc := parent
    FillTrayPopup(1, parent, hwnd)
}

PopupReturnToApps() {
    global g_PopupProc, g_PopupMode
    proc := g_PopupProc
    g_PopupMode := "browse"
    g_PopupProc := ""
    FillTrayPopup(1, proc)
}


; Run the exact same restore/close function used by the global hotkeys.
;
; The old implementation waited 120 ms, which made tray restores visibly
; slower. Running directly inside a GUI callback was also unsafe because the
; popup could reclaim focus when the callback returned. Hide synchronously,
; then run on the very next message-loop turn with no perceptible delay.
PopupThen(action, restoreFocusAfter := false, closeTargetHwnd := 0) {
    global SPEECH_SETTLE
    DebugLog("Scheduling popup action on next message-loop turn: restoreFocus="
        restoreFocusAfter " closeTarget=" closeTargetHwnd, "DEBUG")
    StartQuiet(SPEECH_SETTLE + 500)
    HideTrayPopup()

    ; Do not activate or close the target from inside a ListBox/GUI callback.
    ; The wrapper runs after the popup deactivates and, for close actions,
    ; restores the window/control that owned focus before the popup opened.
    SetTimer(
        RunPopupAction.Bind(action, restoreFocusAfter, closeTargetHwnd),
        -1
    )
}


PopupListMouseUp(wParam, lParam, msg, hwnd) {
    global g_PopupLB, g_PopupItems
    EndQuiet()
    if (!g_PopupLB || hwnd != g_PopupLB.Hwnd || !TrayPopupIsVisible())
        return

    ; LB_ITEMFROMPOINT identifies the row even when it was already selected.
    ; This gives the custom ListBox the one-click activation of a native menu
    ; without treating clicks on its scrollbar or empty area as commands.
    hit := DllCall("User32\SendMessageW", "Ptr", g_PopupLB.Hwnd
        , "UInt", 0x01A9, "Ptr", 0, "Ptr", lParam, "Ptr")
    if ((hit >> 16) & 0xFFFF)
        return
    index := (hit & 0xFFFF) + 1
    if (index < 1 || index > g_PopupItems.Length)
        return
    ReleasePopupSpeech()
    if (g_PopupLB.Value != index)
        g_PopupLB.Choose(index)
    shiftAction := GetKeyState("Shift", "P")
    SetTimer(PopupActivate.Bind(shiftAction), -1)
}

PopupSelectedItem() {
    global g_PopupLB, g_PopupItems
    if !g_PopupLB
        return 0
    idx := g_PopupLB.Value
    return (idx && idx <= g_PopupItems.Length) ? g_PopupItems[idx] : 0
}

; Close one or more hidden windows as a single accessible transaction.
; Native close/focus chatter remains suppressed until the plugin has spoken the
; result and the actual destination focus.
PopupCloseKeepOpen(action, returnProc := "", preferredIndex := 1, *) {
    global g_PopupGui, g_PopupLB, g_PopupItems, g_Hidden
    global g_PopupProc, g_PopupMode, g_Cfg, APP_NAME
    global g_PopupContextHwnd, g_PopupContextParent

    beforeCount := g_Hidden.Length
    closeText := ""
    try closeText := action.Call()
    catch Error as err {
        DebugException("Tray popup close transaction failed", err)
        EndQuiet()
        return
    }

    ; A confirmation dialog may have been cancelled.
    if (closeText = "" || g_Hidden.Length >= beforeCount) {
        EndQuiet()
        if TrayPopupIsVisible() {
            try WinActivate("ahk_id " g_PopupGui.Hwnd)
            try g_PopupLB.Focus()
        }
        return
    }

    ; Keep the notification icon available until the destination focus has been
    ; chosen. When no hidden windows remain, the plugin may advance to the next
    ; icon before posting WM_MT_HIDE_ICON back to this script.
    SetTimer(UpdateTrayIcon, 0)
    A_IconTip := APP_NAME
    MTIcon_SetHidden(false, "popup close: keep icon until focus settles")

    if g_Hidden.Length {
        g_PopupMode := "browse"
        g_PopupContextHwnd := 0
        g_PopupContextParent := ""
        g_PopupProc := returnProc

        grp := GroupByProcess()
        if (g_PopupProc != "" && !grp.groups.Has(g_PopupProc))
            g_PopupProc := ""

        ; Always focus row 1 after the close.
        FillTrayPopup(0)
        if g_PopupItems.Length {
            g_PopupLB.Choose(1)
            try WinActivate("ahk_id " g_PopupGui.Hwnd)
            try g_PopupLB.Focus()
            SendCloseMenuResult(closeText)
            DebugLog("Tray close focused first remaining popup item: level="
                g_PopupProc " rows=" g_PopupItems.Length, "INFO")
            return
        }
    }

    ; No hidden item remains. Settings is not treated as a surviving close
    ; context: close the popup and move into the native notification-area order.
    HideTrayPopup()
    removeIcon := (g_Cfg.Get("HideIconWhenEmpty", "0") = "1")
    SendCloseTrayResult(closeText, removeIcon)
    DebugLog("Tray close handed off to notification-area focus: removeIcon="
        removeIcon, "INFO")
}


; Enter/click restores the selected window or all windows for an app.
; Shift+Enter or Shift+click closes the selected window or all app windows.
PopupActivate(shiftAction := false, *) {
    global g_PopupLB, g_PopupProc, g_PopupContextParent
    EndQuiet()
    if !(it := PopupSelectedItem()) {
        DebugLog("PopupActivate ignored: no selected item", "DEBUG")
        return
    }
    DebugLog("PopupActivate: kind=" it.kind " proc=" it.proc " hwnd=" it.hwnd
        " shift=" shiftAction, "INFO")
    selectedIndex := g_PopupLB ? g_PopupLB.Value : 1

    switch it.kind {
        case "app":
            ; A multi-window app row is itself an action: ordinary activation
            ; restores all; Shift activation closes all. Use Right/Context to
            ; inspect individual hidden windows.
            if shiftAction
                SetTimer(
                    PopupCloseKeepOpen.Bind(
                        CloseGroup.Bind(it.proc, false, false, true),
                        "",
                        selectedIndex
                    ),
                    -1
                )
            else
                PopupThen(RestoreGroup.Bind(it.proc))
        case "settings":
            PopupEnterSettings()
        case "win":
            if shiftAction
                SetTimer(
                    PopupCloseKeepOpen.Bind(
                        CloseOne.Bind(it.hwnd, false, false, true),
                        g_PopupProc,
                        selectedIndex
                    ),
                    -1
                )
            else
                PopupThen(RestoreOne.Bind(it.hwnd, true))
        case "restoreGroup":
            PopupThen(RestoreGroup.Bind(it.proc))
        case "closeGroup":
            SetTimer(
                PopupCloseKeepOpen.Bind(
                    CloseGroup.Bind(it.proc, false, false, true),
                    "",
                    selectedIndex
                ),
                -1
            )
        case "rules":
            HideTrayPopup()
            SetTimer(ShowMainGui.Bind(1), -1)
        case "options":
            HideTrayPopup()
            SetTimer(ShowMainGui.Bind(3), -1)
        case "exit":
            QuitMiniTray()
        case "ctxRestoreOne":
            PopupThen(RestoreOne.Bind(it.hwnd, true))
        case "ctxCloseOne":
            SetTimer(
                PopupCloseKeepOpen.Bind(
                    CloseOne.Bind(it.hwnd, false, false, true),
                    g_PopupContextParent,
                    selectedIndex
                ),
                -1
            )
        ; Backward-compatible action kinds retained for any stale popup rows.
        case "ctxRestoreGroup": PopupThen(RestoreGroup.Bind(it.proc))
        case "ctxCloseGroup":
            SetTimer(
                PopupCloseKeepOpen.Bind(
                    CloseGroup.Bind(it.proc, false, false, true),
                    "",
                    selectedIndex
                ),
                -1
            )
        case "ctxRestoreAll":   PopupThen(RestoreAll)
        case "ctxCloseAll":
            SetTimer(
                PopupCloseKeepOpen.Bind(
                    CloseAllHidden.Bind(false, false, true),
                    "",
                    selectedIndex
                ),
                -1
            )
    }
}


; At the top level, Right opens a multi-window app context or Settings.
; Single-window rows use Applications/right-click for Restore/Close context.
; Left returns from any context/submenu to its exact parent.
PopupDrillIn(*) {
    global g_PopupProc, g_PopupMode
    EndQuiet()
    if (g_PopupMode != "browse" || g_PopupProc != "")
        return
    if !(it := PopupSelectedItem())
        return
    if (it.kind = "app")
        PopupEnterWindows(it.proc)
    else if (it.kind = "settings")
        PopupEnterSettings()
}

PopupBack(*) {
    global g_PopupProc, g_PopupMode
    EndQuiet()
    if (g_PopupMode = "windowContext")
        PopupReturnFromWindowContext()
    else if (g_PopupProc != "")
        PopupReturnToApps()
}


; Delete: close the selected window, or the whole application.
PopupCloseSelected(*) {
    global g_PopupLB, g_PopupProc
    EndQuiet()
    if !(it := PopupSelectedItem())
        return
    selectedIndex := g_PopupLB ? g_PopupLB.Value : 1
    if (it.kind = "win") {
        SetTimer(
            PopupCloseKeepOpen.Bind(
                CloseOne.Bind(it.hwnd, false, false, true),
                g_PopupProc,
                selectedIndex
            ),
            -1
        )
    } else if (it.kind = "app") {
        SetTimer(
            PopupCloseKeepOpen.Bind(
                CloseGroup.Bind(it.proc, false, false, true),
                "",
                selectedIndex
            ),
            -1
        )
    }
}

; Right-click, Applications, or Shift+F10 opens the relevant accessible
; context: app rows expose windows plus Restore all/Close all; window rows expose
; Restore/Close; Settings exposes Window rules/Options/Exit.
PopupContextMenu(guiObj, ctrl, item, isRightClick, x, y) {
    global g_PopupLB, g_PopupProc, g_PopupMode
    EndQuiet()

    if (g_PopupMode = "windowContext" || ctrl != g_PopupLB)
        return

    ; A ListBox ContextMenu event does not always identify the row that was
    ; right-clicked. Resolve it from the pointer so the context belongs to the
    ; clicked row rather than merely the previously selected row.
    if isRightClick
        item := PopupItemAtPointer()
    else if !item
        item := g_PopupLB.Value
    if !item
        return
    ReleasePopupSpeech()
    if (item != g_PopupLB.Value)
        g_PopupLB.Choose(item)
    if !(it := PopupSelectedItem())
        return

    if (it.kind = "app")
        PopupEnterWindows(it.proc)
    else if (it.kind = "win")
        PopupEnterWindowContext(it.hwnd, g_PopupProc)
    else if (it.kind = "settings")
        PopupEnterSettings()
}


PopupItemAtPointer() {
    global g_PopupLB, g_PopupItems
    if !g_PopupLB
        return 0

    pt := Buffer(8, 0)
    if !DllCall("User32\GetCursorPos", "Ptr", pt)
        return 0
    if !DllCall("User32\ScreenToClient", "Ptr", g_PopupLB.Hwnd, "Ptr", pt)
        return 0

    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")
    lParam := (x & 0xFFFF) | ((y & 0xFFFF) << 16)
    hit := DllCall("User32\SendMessageW", "Ptr", g_PopupLB.Hwnd
        , "UInt", 0x01A9, "Ptr", 0, "Ptr", lParam, "Ptr")
    if ((hit >> 16) & 0xFFFF)
        return 0
    index := (hit & 0xFFFF) + 1
    return (index >= 1 && index <= g_PopupItems.Length) ? index : 0
}

PopupOpenKeyboardContext(*) {
    global g_PopupProc, g_PopupMode
    EndQuiet()
    if (g_PopupMode = "windowContext")
        return
    if !(it := PopupSelectedItem())
        return
    if (it.kind = "app")
        PopupEnterWindows(it.proc)
    else if (it.kind = "win")
        PopupEnterWindowContext(it.hwnd, g_PopupProc)
    else if (it.kind = "settings")
        PopupEnterSettings()
}


; Updates the tray icon, and the popup if it happens to be open. Named for what
; it does now -- there is no menu left to build.
RefreshTray(hideEmptyNow := false) {
    global g_Hidden, g_Cfg, APP_NAME, g_PopupGui, ICON_HIDE_DELAY

    A_IconTip := APP_NAME                             ; constant, always

    ; Showing the icon is harmless at any moment. Hiding it makes Explorer
    ; reflow the notification area and can move accessibility focus to the next
    ; icon. Ordinary refreshes therefore keep the existing delayed/focus-aware
    ; path. Restore/save transactions may request an immediate hide while their
    ; quiet/focus handoff is still active, so the real destination window can be
    ; the final focus event instead of a neighboring tray icon.
    if (g_Hidden.Length || g_Cfg.Get("HideIconWhenEmpty", "0") != "1") {
        SetTimer(UpdateTrayIcon, 0)
        MTIcon_SetHidden(false, "refresh: icon required")
    } else if hideEmptyNow {
        SetTimer(UpdateTrayIcon, 0)
        MTIcon_SetHidden(true, "refresh: immediate empty hide inside quiet focus handoff")
    } else {
        SetTimer(UpdateTrayIcon, -ICON_HIDE_DELAY)
    }

    if (g_PopupGui && DllCall("User32\IsWindowVisible", "Ptr", g_PopupGui.Hwnd))
        FillTrayPopup()
}

; =============================================================================
;  MAIN GUI
; =============================================================================
ShowMainGui(tabIndex := 1) {
    global g_MainGui, g_MainTab
    DebugLog("ShowMainGui requested: tab=" tabIndex, "INFO")
    if !g_MainGui
        BuildMainGui()
    RefreshOpen(), RefreshRules(), RefreshHidden(), LoadOptionsIntoGui()

    ; Menu entries can open a specific page directly. Keep the hotkey and the
    ; --show command on the Rules page by retaining 1 as the default.
    if (tabIndex < 1 || tabIndex > 3)
        tabIndex := 1
    try g_MainTab.Choose(tabIndex)

    g_MainGui.Show()
    try {
        if (tabIndex = 3)
            g_MainGui["OptSound"].Focus()
        else if (tabIndex = 2)
            g_MainGui["LVHidden"].Focus()
        else
            g_MainGui["LVOpen"].Focus()
    }
}

BuildMainGui() {
    global g_MainGui, g_MainTab, g_LVOpen, g_LVRules, g_LVHidden, APP_NAME, INI_FILE

    ; Title is just the app name. The settings folder used to be appended here
    ; to show which INI was live; the Options tab now has a labelled field for
    ; that, which is a better home for a long path than the title bar.
    g := Gui("+Resize +MinSize900x520", APP_NAME)
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 12, g.MarginY := 12
    g.OnEvent("Close", (*) => g.Hide())
    g.OnEvent("Escape", (*) => g.Hide())

    g_MainTab := g.Add("Tab3", "xm ym w880 h420", ["Rules", "Hidden windows", "Options"])
    tab := g_MainTab

    ; ---- Rules ----------------------------------------------------------
    tab.UseTab(1)
    g.Add("Text", "x28 y58", "Currently open windows")
    g_LVOpen := g.Add("ListView", "x28 y+6 w400 h300 Grid -Multi vLVOpen"
                    , ["Title", "Class", "HWND"])
    g_LVOpen.OnEvent("DoubleClick", (*) => RuleFlowForSelectedOpen())

    g.Add("Text", "x452 y58", "Rules")
    g_LVRules := g.Add("ListView", "x452 y+6 w400 h300 Grid -Multi vLVRules"
                     , ["Rule", "Type", "Match", "Value", "Bounds"])
    g_LVRules.OnEvent("DoubleClick", (*) => EditSelectedRule())

    b := g.Add("Button", "x28 y+12 w150", "Add / edit rule")
    b.OnEvent("Click", (*) => RuleFlowForSelectedOpen())
    b := g.Add("Button", "x+8 yp w90", "Edit")
    b.OnEvent("Click", (*) => EditSelectedRule())
    b := g.Add("Button", "x+8 yp w90", "Remove")
    b.OnEvent("Click", (*) => RemoveSelectedRule())
    b := g.Add("Button", "x+8 yp w90", "Refresh")
    b.OnEvent("Click", (*) => (RefreshOpen(), RefreshRules()))
    b := g.Add("Button", "x+8 yp w150", "Open INI folder")
    b.OnEvent("Click", (*) => OpenIniFolder())

    ; ---- Hidden ---------------------------------------------------------
    tab.UseTab(2)
    g.Add("Text", "x28 y58", "Windows currently hidden to the tray")
    g_LVHidden := g.Add("ListView", "x28 y+6 w824 h300 Grid -Multi vLVHidden"
                      , ["Process", "Title", "Method", "HWND"])
    g_LVHidden.OnEvent("DoubleClick", (*) => RestoreSelectedHidden())
    b := g.Add("Button", "x28 y+12 w120", "Restore")
    b.OnEvent("Click", (*) => RestoreSelectedHidden())
    b := g.Add("Button", "x+8 yp w120", "Close")
    b.OnEvent("Click", (*) => CloseSelectedHidden())
    b := g.Add("Button", "x+8 yp w150", "Restore all")
    b.OnEvent("Click", (*) => (RestoreAll(), RefreshHidden()))

    ; ---- Options --------------------------------------------------------
    tab.UseTab(3)
    g.Add("Text", "x28 y62 w120", "Sound")
    g.Add("DropDownList", "x150 y58 w120 vOptSound", ["Wav", "Beep", "None"])
    g.Add("Text", "x28 y+14 w120", "Beep freq / ms")
    g.Add("Edit", "x150 yp-4 w70 vOptFreq Number")
    g.Add("Edit", "x+8 yp w70 vOptDur Number")
    g.Add("Text", "x28 y+14 w120", "Wav path")
    g.Add("Edit", "x150 yp-4 w500 vOptWav")
    g.Add("CheckBox", "x150 y+16 vOptSpeak", "Announce actions through NVDA when it is running")
    g.Add("CheckBox", "x150 y+8 vOptConfirm", "Confirm before Close all")
    g.Add("CheckBox", "x150 y+8 vOptAuto", "Apply rules automatically on focus and title change")
    g.Add("CheckBox", "x150 y+8 vOptHideIcon"
        , "Remove the tray icon when nothing is hidden (a screen reader may re-read the tray)")
    ; A compiled exe reads its INI from its OWN folder, so running the build
    ; and running the source use two different files. Show which one is live.
    g.Add("Text", "x28 y+22 w120", "Settings file")
    g.Add("Edit", "x150 yp-4 w500 ReadOnly vOptIniPath", INI_FILE)
    b := g.Add("Button", "x150 y+20 w120", "Save options")
    b.OnEvent("Click", (*) => SaveOptionsFromGui())

    tab.UseTab()
    b := g.Add("Button", "xm y+14 w140", "&Hide MiniTray")
    b.OnEvent("Click", (*) => g.Hide())
    b := g.Add("Button", "x+8 yp w140", "E&xit MiniTray")
    b.OnEvent("Click", (*) => QuitMiniTray())

    g_MainGui := g
}

; Mirrors what Alt+Tab shows: visible, top-level, unowned, not a tool window,
; and not DWM-cloaked. The cloak test matters on Windows 11 - a suspended store
; app or one parked on another virtual desktop still reports IsWindowVisible.
IsAltTabWindow(hwnd) {
    static GA_ROOT := 2, GW_OWNER := 4, GWL_EXSTYLE := -20
    static WS_EX_TOOLWINDOW := 0x00000080, WS_EX_APPWINDOW := 0x00040000
    static DWMWA_CLOAKED := 14

    if !DllCall("User32\IsWindowVisible", "Ptr", hwnd)
        return false
    if (DllCall("User32\GetAncestor", "Ptr", hwnd, "UInt", GA_ROOT, "Ptr") != hwnd)
        return false

    cloaked := 0
    try DllCall("Dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", DWMWA_CLOAKED
              , "Int*", &cloaked, "UInt", 4)
    if (cloaked)
        return false

    fn := (A_PtrSize = 8) ? "User32\GetWindowLongPtrW" : "User32\GetWindowLongW"
    ex := DllCall(fn, "Ptr", hwnd, "Int", GWL_EXSTYLE, "Ptr")
    if (ex & WS_EX_APPWINDOW)
        return true                      ; opts in regardless of ownership
    if (ex & WS_EX_TOOLWINDOW)
        return false
    if DllCall("User32\GetWindow", "Ptr", hwnd, "UInt", GW_OWNER, "Ptr")
        return false                     ; owned windows ride with their owner
    return true
}

RefreshOpen() {
    global g_LVOpen
    if !g_LVOpen
        return
    g_LVOpen.Delete()
    for hwnd in WinGetList() {
        if (
            IsOwnWindow(hwnd)
            || !IsAltTabWindow(hwnd)
            || WindowHideBlockReason(hwnd) != ""
        )
            continue
        try {
            t := WinGetTitle("ahk_id " hwnd)
            c := WinGetClass("ahk_id " hwnd)
        } catch
            continue
        if (t = "")
            continue
        g_LVOpen.Add("", t, c, hwnd)
    }
    if (g_LVOpen.GetCount())
        g_LVOpen.Modify(1, "Select Focus Vis")
    loop 3
        g_LVOpen.ModifyCol(A_Index, "AutoHdr")
}

RefreshRules() {
    global g_LVRules, g_Rules
    if !g_LVRules
        return
    LoadRules(true)
    g_LVRules.Delete()
    for r in g_Rules {
        val  := (r.cmp = "title") ? r.title : r.cls
        mtch := (r.cmp = "title") ? r.match : "-"
        g_LVRules.Add("", r.name . (r.on ? "" : "  (disabled)")
                        , (r.cmp = "title" ? "Title" : "Class"), mtch, val, r.bounds)
    }
    if (g_LVRules.GetCount())
        g_LVRules.Modify(1, "Select Focus")
    loop 5
        g_LVRules.ModifyCol(A_Index, "AutoHdr")
}

RefreshHidden() {
    global g_LVHidden, g_Hidden
    if !g_LVHidden
        return
    g_LVHidden.Delete()
    i := g_Hidden.Length
    while (i >= 1) {
        e := g_Hidden[i]
        g_LVHidden.Add("", e.proc, e.title, e.how = "min" ? "minimised" : "hidden", e.hwnd)
        i--
    }
    loop 4
        g_LVHidden.ModifyCol(A_Index, "AutoHdr")
}

SelectedText(lv, col) {
    if !lv
        return ""
    row := lv.GetNext(0)
    return row ? lv.GetText(row, col) : ""
}

RestoreSelectedHidden() {
    global g_LVHidden
    if (h := SelectedText(g_LVHidden, 4))
        RestoreOne(h + 0)
    RefreshHidden()
}

CloseSelectedHidden() {
    global g_LVHidden
    if (h := SelectedText(g_LVHidden, 4))
        CloseOne(h + 0)
    RefreshHidden()
}

OpenIniFolder() {
    global INI_FILE
    try Run('explorer.exe /select,"' INI_FILE '"')
}

LoadOptionsIntoGui() {
    global g_MainGui, g_Cfg
    if !g_MainGui
        return
    ChooseText(g_MainGui["OptSound"], ["Wav", "Beep", "None"], g_Cfg.Get("SoundMode", "Wav"))
    g_MainGui["OptFreq"].Value    := g_Cfg.Get("BeepFreq", "400")
    g_MainGui["OptDur"].Value     := g_Cfg.Get("BeepDur", "40")
    g_MainGui["OptWav"].Value     := g_Cfg.Get("WavPath", "")
    g_MainGui["OptSpeak"].Value   := (g_Cfg.Get("Speak", "0") = "1")
    g_MainGui["OptConfirm"].Value := (g_Cfg.Get("ConfirmCloseAll", "1") = "1")
    g_MainGui["OptAuto"].Value    := (g_Cfg.Get("AutoApply", "1") = "1")
    g_MainGui["OptHideIcon"].Value := (g_Cfg.Get("HideIconWhenEmpty", "0") = "1")
}

SaveOptionsFromGui() {
    global g_MainGui, g_Cfg, g_Hidden, INI_FILE, CFG_SEC
    if !g_MainGui
        return
    set := Map("SoundMode",       g_MainGui["OptSound"].Text
             , "BeepFreq",        g_MainGui["OptFreq"].Value
             , "BeepDur",         g_MainGui["OptDur"].Value
             , "WavPath",         g_MainGui["OptWav"].Value
             , "Speak",           g_MainGui["OptSpeak"].Value ? "1" : "0"
             , "ConfirmCloseAll", g_MainGui["OptConfirm"].Value ? "1" : "0"
             , "AutoApply",       g_MainGui["OptAuto"].Value ? "1" : "0"
             , "HideIconWhenEmpty", g_MainGui["OptHideIcon"].Value ? "1" : "0")
    for k, v in set {
        IniWrite(v, INI_FILE, CFG_SEC, k)
        g_Cfg[k] := v . ""
    }

    ; Save is also the Options dialog's accept action. If the new setting hides
    ; an empty tray icon, perform that shell reflow while MiniTray still owns
    ; foreground and while MTQUIET can absorb the transient tray focus event.
    ; Hiding the GUI immediately afterwards makes the underlying application the
    ; final native focus destination instead of the next notification-area icon.
    hideEmptyNow := (!g_Hidden.Length
        && g_Cfg.Get("HideIconWhenEmpty", "0") = "1")
    if hideEmptyNow
        StartQuiet(700, false)
    RefreshTray(hideEmptyNow)
    g_MainGui.Hide()
    if hideEmptyNow
        SetTimer(EndQuiet, -250)

    DebugLog("Options saved and window hidden: SoundMode=" g_Cfg.Get("SoundMode", "")
        " Speak=" g_Cfg.Get("Speak", "0")
        " ConfirmCloseAll=" g_Cfg.Get("ConfirmCloseAll", "1")
        " AutoApply=" g_Cfg.Get("AutoApply", "1")
        " HideIconWhenEmpty=" g_Cfg.Get("HideIconWhenEmpty", "0"), "INFO")
    Feedback()
}

; =============================================================================
;  RULE FLOW
; =============================================================================
RuleFlowForActiveWindow() {
    RuleFlowForHwnd(WinExist("A"))
}

RuleFlowForSelectedOpen() {
    global g_LVOpen
    if (h := SelectedText(g_LVOpen, 3))
        RuleFlowForHwnd(h + 0)
}

; Ctrl+Alt+4. Only ever one editor open; never targets our own windows; and
; nothing is written to the INI until Save is pressed. The previous version
; wrote the section up front, which is how [Edit rule - Edit rule - ...] and
; the stray File Explorer rules ended up in the file.
RuleFlowForHwnd(hwnd) {
    global g_EditGui, g_Rules
    if (g_EditGui) {                     ; already editing - just come forward
        try WinActivate("ahk_id " g_EditGui.Hwnd)
        return
    }
    if (!hwnd || !WinExist("ahk_id " hwnd) || IsOwnWindow(hwnd)) {
        Nope()
        return
    }

    cls := WinGetClass("ahk_id " hwnd)
    ttl := WinGetTitle("ahk_id " hwnd)
    LoadRules(true)

    ; class rules first, then title rules
    for r in g_Rules
        if (r.cmp = "class" && r.cls != "" && r.cls = cls) {
            EditRuleDialog(r, r.name, false, hwnd)
            return
        }
    for r in g_Rules
        if (r.cmp = "title" && r.title != "" && TitleMatches(ttl, r)) {
            EditRuleDialog(r, r.name, false, hwnd)
            return
        }

    ; nothing matches - offer a new rule seeded from the window itself
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    fresh := { name  : SanitizeSection(ttl != "" ? ttl : cls)
             , cmp   : "title"
             , cls   : cls
             , title : ttl
             , match : "exact"
             , w     : w, h : h, x : x, y : y
             , bounds: "work", hom : false, on : true }
    EditRuleDialog(fresh, "", true, hwnd)
}

EditSelectedRule() {
    global g_LVRules, g_Rules
    name := RegExReplace(SelectedText(g_LVRules, 1), "  \(disabled\)$")
    if (name = "")
        return
    LoadRules(true)
    for r in g_Rules
        if (r.name = name) {
            EditRuleDialog(r, name, false, 0)
            return
        }
}

RemoveSelectedRule() {
    global g_LVRules, INI_FILE, APP_NAME
    name := RegExReplace(SelectedText(g_LVRules, 1), "  \(disabled\)$")
    if (name = "")
        return
    if (MsgBox("Remove rule '" name "'?", APP_NAME, "YesNo Icon?") != "Yes")
        return
    try IniDelete(INI_FILE, name)
    LoadRules(true), RefreshRules()
}

SanitizeSection(name) {
    name := RegExReplace(Trim(name), "\s+", " ")
    name := RegExReplace(name, '[\[\]:\*\?"<>|/\\\t]', "_")
    name := Trim(name, " ._")
    if (StrLen(name) > 80)
        name := SubStr(name, 1, 80)
    return name = "" ? "Rule" : name
}

UniqueSection(base) {
    global g_Rules
    LoadRules(true)
    taken := Map()
    taken.CaseSense := false
    for r in g_Rules
        taken[r.name] := true
    if !taken.Has(base)
        return base
    i := 2
    while (taken.Has(base " (" i ")") && i < 9999)
        i++
    return base " (" i ")"
}

; =============================================================================
;  EDIT RULE DIALOG
; =============================================================================
EditRuleDialog(rule, sec, isNew, hwnd := 0) {
    global g_EditGui, g_MainGui, g_EditSec, g_EditNew, g_EditHwnd
    global g_EditClass, g_EditTitle, g_EditMode   ; assigned below - without
                                                 ; this they become locals

    if (g_EditGui) {
        try WinActivate("ahk_id " g_EditGui.Hwnd)
        return
    }
    g_EditSec := sec, g_EditNew := isNew, g_EditHwnd := hwnd
    g_EditClass := rule.cls
    g_EditTitle := rule.title
    ; The box is seeded straight from `rule` below, so record the mode it is
    ; already showing. UpdateMatchMode then has nothing to do until a radio is
    ; actually clicked.
    g_EditMode  := (rule.cmp = "class") ? "class" : "title"

    ; Slider ranges span the virtual desktop, widened if the rule already sits
    ; outside it (a 4096-wide rule on a 2560 screen must stay representable).
    vx := SysGet(76), vy := SysGet(77), vw := SysGet(78), vh := SysGet(79)
    wHi := Max(vw, NumOr(rule.w, 1)),        hHi := Max(vh, NumOr(rule.h, 1))
    ; Rule positions deliberately use a non-negative coordinate space.
    ; Existing negative INI values are displayed as zero and corrected on save.
    rule.x := Max(0, NumOr(rule.x, 0)), rule.y := Max(0, NumOr(rule.y, 0))
    xLo := 0, xHi := Max(0, vx + vw, rule.x)
    yLo := 0, yHi := Max(0, vy + vh, rule.y)

    g := Gui("-MaximizeBox -MinimizeBox", isNew ? "Create rule" : "Edit rule")
    if IsObject(g_MainGui)
        g.Opt("+Owner" g_MainGui.Hwnd)
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 12, g.MarginY := 12

    g.Add("Text", "xm w110", "Rule name")
    g.Add("Edit", "x+8 yp-4 w430 vRName", rule.name)

    g.Add("Text", "xm y+12 w110", "Match on")
    rc := g.Add("Radio", "x+8 yp vRCmpClass Group" . (rule.cmp = "class" ? " Checked" : ""), "Class")
    rt := g.Add("Radio", "x+12 yp vRCmpTitle" . (rule.cmp = "title" ? " Checked" : ""), "Title")
    rc.OnEvent("Click", (*) => UpdateMatchMode(g))
    rt.OnEvent("Click", (*) => UpdateMatchMode(g))

    ; One box for both. The label and contents follow the Match-on radios; the
    ; value you are not looking at is held in memory, not in a second control.
    ; Seeded directly from `rule` -- same as the Rule name box above -- rather
    ; than being filled in later from the globals.
    isClass := (rule.cmp = "class")
    g.Add("Text", "xm y+12 w110 vRValueLabel", isClass ? "Class" : "Title")
    ve := g.Add("Edit", "x+8 yp-4 w430 vRValue", isClass ? rule.cls : rule.title)
    ve.OnEvent("Change", (*) => CaptureValue(g))

    g.Add("Text", "xm y+12 w110", "Title match")
    ddl := g.Add("DropDownList", "x+8 yp-4 w150 vRMatch", ["Exact", "Contains", "Wildcard", "RegEx"])
    ChooseText(ddl, ["Exact", "Contains", "Wildcard", "RegEx"], rule.match)
    ddl.Enabled := !isClass              ; title-match is meaningless for a class rule

    AddNumRow(g, "Width",  "RW", "SW", rule.w, 1,   wHi)
    AddNumRow(g, "Height", "RH", "SH", rule.h, 1,   hHi)
    AddNumRow(g, "X",      "RX", "SX", rule.x, xLo, xHi)
    AddNumRow(g, "Y",      "RY", "SY", rule.y, yLo, yHi)

    b := g.Add("Button", "xm y+14 w160", "Grab current size")
    b.OnEvent("Click", GrabGeometry.Bind(g))
    if !hwnd
        b.Enabled := false

    g.Add("Text", "xm y+16 w110", "Clamp to")
    ; The explanation lives in the items themselves rather than in a loose Text
    ; control beside them, so it is announced when the control takes focus.
    ; The INI still stores the bare keys work|monitor|virtual.
    bd := g.Add("DropDownList", "x+8 yp-4 w330 vRBounds"
              , ["Work area - excludes the taskbar"
               , "Whole monitor - includes the taskbar"
               , "Virtual desktop - spans all monitors"])
    bd.Choose(BoundsToIndex(rule.bounds))

    g.Add("CheckBox", "xm y+14 vRHom" . (rule.hom ? " Checked" : "")
        , "Hide this window to the tray when it is minimised")
    g.Add("CheckBox", "xm y+8 vROn" . (rule.on ? " Checked" : "")
        , "Enable automatic matching and hide-on-minimize for this rule")

    b := g.Add("Button", "xm y+18 w110 Default", isNew ? "Create" : "Save")
    b.OnEvent("Click", (*) => SaveRuleDialog(g, true))
    b := g.Add("Button", "x+8 yp w110", "Cancel")
    b.OnEvent("Click", (*) => CloseEditGui())
    b := g.Add("Button", "x+8 yp w110", "Apply now")
    b.OnEvent("Click", (*) => ApplyFromDialog(g))

    g.OnEvent("Close", (*) => CloseEditGui())
    g.OnEvent("Escape", (*) => CloseEditGui())
    g_EditGui := g
    g.Show()
    try g["RName"].Focus()
}

; Switch the shared box between the class name and the window title. The value
; being left behind is flushed to memory first, so the rule keeps BOTH - editing
; a class rule never discards its Title note (e.g. "ATLAS IDE" on [wxWindowNR]),
; and editing a title rule never discards its Class.
UpdateMatchMode(g) {
    global g_EditClass, g_EditTitle, g_EditMode
    mode := g["RCmpClass"].Value ? "class" : "title"
    if (mode = g_EditMode)               ; radios fire on re-clicks too
        return
    CaptureValue(g)                      ; store the box under the mode we are leaving
    g_EditMode := mode
    g["RValueLabel"].Text := (mode = "class") ? "Class" : "Title"
    g["RValue"].Value     := (mode = "class") ? g_EditClass : g_EditTitle
    g["RMatch"].Enabled   := (mode = "title")   ; meaningless for a class rule
}

; Keeps the in-memory copy in step with what is being typed. Also called before
; a mode switch and before saving.
CaptureValue(g) {
    global g_EditClass, g_EditTitle, g_EditMode
    if (g_EditMode = "class")
        g_EditClass := g["RValue"].Value
    else if (g_EditMode = "title")
        g_EditTitle := g["RValue"].Value
}

; An integer field plus a slider over the same value. The EDIT is authoritative:
; it is never clamped while you type, so a value beyond the slider's range can
; still be entered - the slider just saturates.
AddNumRow(g, label, editName, sliderName, value, lo, hi) {
    ; One arrow press moves 1% of the range, PgUp/PgDn 10%. Without this the
    ; step is a single pixel, so arrowing across a 5000-wide range announces
    ; thousands of near-identical values. The value spoken is still the real
    ; pixel figure -- what you need for W/H/X/Y -- just reached in 1% jumps.
    step := Max(1, Round((hi - lo) / 100))
    page := Max(1, Round((hi - lo) / 10))

    g.Add("Text", "xm y+14 w110", label)
    ed := g.Add("Edit", "x+8 yp-4 w90 v" . editName, value)
    sl := g.Add("Slider", "x+12 yp-2 w320 NoTicks v" . sliderName
              . " Range" . lo . "-" . hi . " Line" . step . " Page" . page)
    sl.Value := ClampNum(value, lo, hi)
    ed.OnEvent("Change", SyncEditToSlider.Bind(ed, sl, lo, hi))
    sl.OnEvent("Change", SyncSliderToEdit.Bind(ed, sl))
}

SyncEditToSlider(ed, sl, lo, hi, *) {
    global g_SyncGuard
    if (g_SyncGuard)
        return
    v := Trim(ed.Value)
    if !IsInt(v)                     ; mid-typing "-" or empty: leave the slider
        return
    g_SyncGuard := true
    sl.Value := ClampNum(v, lo, hi)
    g_SyncGuard := false
}

SyncSliderToEdit(ed, sl, *) {
    global g_SyncGuard
    if (g_SyncGuard)
        return
    g_SyncGuard := true
    ed.Value := sl.Value
    g_SyncGuard := false
}

SetNumRow(g, editName, sliderName, v) {
    global g_SyncGuard
    g_SyncGuard := true
    g[editName].Value := v
    try g[sliderName].Value := v         ; saturates if outside the slider range
    g_SyncGuard := false
}

ClampNum(v, lo, hi) {
    if !IsInt(v)
        return lo
    v += 0
    return (v < lo) ? lo : ((v > hi) ? hi : v)
}

NumOr(v, dflt) => IsInt(v) ? v + 0 : dflt

; Bounds is shown as descriptive text but stored as a bare key, so the two are
; mapped by position rather than by the label the user sees.
BoundsToIndex(b) {
    b := StrLower(Trim(b . ""))
    return (b = "monitor") ? 2 : ((b = "virtual") ? 3 : 1)
}

BoundsFromIndex(i) {
    static keys := ["work", "monitor", "virtual"]
    return (i >= 1 && i <= keys.Length) ? keys[i] : "work"
}

; DropDownList.Choose wants an item number, so resolve the text ourselves.
ChooseText(ctrl, list, value) {
    for i, v in list
        if (v = value) {
            ctrl.Choose(i)
            return
        }
    ctrl.Choose(1)
}

GrabGeometry(g, *) {
    global g_EditHwnd
    if (!g_EditHwnd || !WinExist("ahk_id " g_EditHwnd))
        return
    WinGetPos(&x, &y, &w, &h, "ahk_id " g_EditHwnd)
    SetNumRow(g, "RW", "SW", w)
    SetNumRow(g, "RH", "SH", h)
    SetNumRow(g, "RX", "SX", Max(0, x))
    SetNumRow(g, "RY", "SY", Max(0, y))
}

; Returns the section name it wrote, or "" if validation failed.
SaveRuleDialog(g, andClose := true) {
    global INI_FILE, APP_NAME, g_EditSec, g_EditNew, g_EditClass, g_EditTitle
    CaptureValue(g)                      ; flush the live box before reading either
    cmp := g["RCmpTitle"].Value ? "title" : "class"
    r := { cmp   : cmp
         , cls   : Trim(g_EditClass)
         , title : Trim(g_EditTitle)
         , match : StrLower(g["RMatch"].Text)
         , w     : Trim(g["RW"].Value), h : Trim(g["RH"].Value)
         , x     : Trim(g["RX"].Value), y : Trim(g["RY"].Value)
         , bounds: BoundsFromIndex(g["RBounds"].Value)
         , hom   : g["RHom"].Value ? true : false
         , on    : g["ROn"].Value ? true : false }

    if !(IsInt(r.w) && IsInt(r.h) && IsInt(r.x) && IsInt(r.y)) {
        MsgBox("W, H, X and Y must all be whole numbers.", APP_NAME, "Icon!")
        return ""
    }
    if (r.w + 0 <= 0 || r.h + 0 <= 0) {
        MsgBox("Width and height must be greater than zero.", APP_NAME, "Icon!")
        return ""
    }
    ; Never persist negative rule coordinates, including values pasted or
    ; typed directly into the edit controls.
    r.x := Max(0, r.x + 0), r.y := Max(0, r.y + 0)
    SetNumRow(g, "RX", "SX", r.x)
    SetNumRow(g, "RY", "SY", r.y)
    if (cmp = "class" && r.cls = "") {
        MsgBox("A class rule needs a class name.", APP_NAME, "Icon!")
        return ""
    }
    if (cmp = "title" && r.title = "") {
        MsgBox("A title rule needs a title to match.", APP_NAME, "Icon!")
        return ""
    }
    if (cmp = "title" && r.match = "regex") {
        try RegExMatch("", r.title)
        catch {
            MsgBox("That is not a valid regular expression.", APP_NAME, "Icon!")
            return ""
        }
    }

    newName := SanitizeSection(g["RName"].Value)
    sec := g_EditSec
    if (g_EditNew) {
        sec := UniqueSection(newName)        ; first write for this rule
    } else if (newName != sec) {
        try IniDelete(INI_FILE, sec)
        sec := UniqueSection(newName)
    }

    WriteRule(sec, r)
    g_EditSec := sec, g_EditNew := false
    RefreshRules()
    if (andClose)
        CloseEditGui()
    return sec
}

ApplyFromDialog(g) {
    global g_EditHwnd
    if ((sec := SaveRuleDialog(g, false)) != "")
        ApplyNamedRule(sec, g_EditHwnd)
}

ApplyNamedRule(sec, hwnd) {
    global g_Rules
    LoadRules(true)
    if (!hwnd)
        hwnd := WinExist("A")
    for r in g_Rules
        if (r.name = sec) {
            if ApplyRule(r, hwnd)
                Feedback()
            return
        }
}

CloseEditGui() {
    global g_EditGui, g_EditSec, g_EditNew, g_EditHwnd
    global g_EditClass, g_EditTitle, g_EditMode
    if g_EditGui {
        try g_EditGui.Destroy()
        g_EditGui := 0
    }
    g_EditSec := "", g_EditNew := false, g_EditHwnd := 0
    g_EditClass := "", g_EditTitle := "", g_EditMode := ""
}

QuitMiniTray(*) {
    global g_Cfg
    DebugLog("Quit requested by user", "INFO")

    ; Restore every tracked window before announcing or terminating. The batch
    ; reveal is non-activating, so windows reappear immediately without paying
    ; AutoHotkey's per-window WinShow/WinRestore delays or generating a cascade
    ; of foreground announcements.
    restoredCount := RestoreAllForExit()
    noun := (restoredCount = 1) ? " window" : " windows"
    message := restoredCount noun " restored, exited MiniTray"

    ; Quit is an explicit user command, so report it even when routine MiniTray
    ; speech is disabled. Keep focus and shell churn quiet while the tray popup
    ; is destroyed and Windows chooses the next foreground window.
    savedSpeak := g_Cfg.Get("Speak", "0")
    g_Cfg["Speak"] := "1"
    if (g_Cfg.Get("QuietPlugin", "1") = "1") {
        StartQuiet(1800)
        Announce(Chr(1) "MTFINAL:" message Chr(1), false)
    } else {
        Announce(message, true)
    }
    Sleep 80
    g_Cfg["Speak"] := savedSpeak
    ExitApp()
}

RestoreAllForExit() {
    global g_Hidden, g_Restoring, INI_FILE, HID_SEC

    entries := BuildRestoreAllOrder(g_Hidden.Clone())
    restoredCount := 0
    g_Restoring := true
    try {
        for e in entries {
            if !WindowMatchesRecord(e)
                continue
            if RevealBatchFast(e)
                restoredCount++
        }
    } finally {
        g_Restoring := false
    }

    ; Clear the authoritative in-memory and persisted lists now. HandleExit()
    ; remains as a crash/reload safety net, but has nothing to restore twice
    ; after an ordinary user-requested quit.
    g_Hidden := []
    try IniDelete(INI_FILE, HID_SEC)

    DebugLog("Exit restore completed: restored=" restoredCount
        " tracked=" entries.Length, "INFO")
    return restoredCount
}

; =============================================================================
;  SHUTDOWN
; =============================================================================
; Deliberately minimal. An explicit user quit has already restored and cleared
; the hidden list and queued its final speech. This handler remains the safety
; net for reloads, replacement by #SingleInstance Force, shutdown, and other
; clean-exit paths.
HandleExit(reason, code) {
    global g_Hidden, INI_FILE, HID_SEC, g_FocusBridgeGui
    DebugLog("HandleExit: reason=" reason " code=" code " hidden=" g_Hidden.Length, "INFO")
    RemoveHooks()
    if IsObject(g_FocusBridgeGui)
        try g_FocusBridgeGui.Destroy()
    for e in g_Hidden.Clone() {
        try {
            if !WindowMatchesRecord(e)
                continue
            if (e.how = "min")
                TaskbarTab(e.hwnd, true)
            WinShow("ahk_id " e.hwnd)
        } catch {
            ; window already gone; nothing to un-hide
        }
    }
    g_Hidden := []
    try IniDelete(INI_FILE, HID_SEC)

    ; Do not send Shell_NotifyIcon(NIM_DELETE) during shutdown. Explorer has
    ; repeatedly fail-fasted while servicing DeleteIcon/NotificationAreaIcon2::Close.
    ; Once this OnExit handler returns, AHK destroys A_ScriptHwnd/process state and
    ; the shell can discard the owner registration as part of normal owner teardown.
    MTIcon_Abandon("process exit: " reason)
    DebugLog("MiniTray shutdown complete (no NIM_DELETE sent)", "INFO")
    return 0
}

; =============================================================================
;  NOTIFICATION-AREA ICON  (MTIcon_*)
; -----------------------------------------------------------------------------
;  MiniTray owns its tray icon directly rather than using AHK's A_IconHidden.
;
;  WHY. Crash dump explorer.exe.8304 (13 Aug 2026) fail-fasted here:
;
;      explorer!CTray::_MessageLoop
;        -> user32!_fnCOPYDATA                    (WM_COPYDATA = Shell_NotifyIcon)
;        -> Taskbar!TrayUI::HandleCopyData
;        -> Taskbar!NotificationAreaIconManager2::ShellNotifyIcon
;        -> Taskbar!NotificationAreaIconManager2::DeleteIcon      <-- NIM_DELETE
;        -> Taskbar!...NotificationAreaIcon2::Close
;        -> Taskbar!...registry_watcher_state::~registry_watcher_state
;        -> Taskbar!wil::details::CloseHandle      -> FAIL FAST (E_HANDLE)
;
;  DeleteIcon is reached by the explicit NIM_DELETE request shown in the crash
;  stack. A_IconHidden offers add/delete, so older hide-when-empty behavior drove
;  that path repeatedly. Normal hiding now uses NIM_MODIFY + NIS_HIDDEN, and this
;  build also suppresses the final shutdown NIM_DELETE. MiniTray therefore sends
;  NIM_ADD and NIM_MODIFY only.
;
;  The bug is Microsoft's: Shell_NotifyIcon marshals a NOTIFYICONDATA struct
;  over WM_COPYDATA and cannot pass a handle into explorer's heap, so the bad
;  handle is explorer's own. MiniTray was only the trigger. This removes the
;  trigger.
;
;  CONSEQUENCE OF OWNERSHIP. AHK used to re-create its own icon when the shell
;  restarted. It will not do that for an icon we registered, so MTIcon_Init
;  handles TaskbarCreated itself. Without that, one explorer crash would leave
;  MiniTray running with no icon and every hidden window unreachable.
;
;  No top-level globals here on purpose: state lives in a lazily built object,
;  so this block can sit anywhere in the file.
; =============================================================================

MTIcon_State() {
    static s := ""
    if !IsObject(s) {
        s := { hIcon:   0
             , added:   false
             , hidden:  false
             , hooked:  false
             , uID:     1001         ; our own ID; AHK's icon is not in play
             , seq:     0            ; monotonic tray-operation diagnostic ID
             , buf:     "" }
    }
    return s
}

; One compact line per notification-area transition. This makes it possible to
; correlate a future Explorer dump with the last MiniTray shell operation while
; keeping the normal log small.
MTIcon_Log(action, ok := -1, why := "") {
    st := MTIcon_State()
    st.seq += 1

    shellPid := 0
    try shellPid := ProcessExist("explorer.exe")

    result := ""
    level := "DEBUG"
    if (ok != -1) {
        result := " result=" (ok ? "ok" : "FAILED err=" A_LastError)
        if !ok
            level := "ERROR"
    }
    if (action = "ABANDON")
        level := "INFO"

    DebugLog("MTIcon seq=" st.seq
        " action=" action
        " pid=" ProcessExist()
        " hwnd=" A_ScriptHwnd
        " uid=" st.uID
        " shellPid=" shellPid
        " added=" st.added
        " hidden=" st.hidden
        . (why ? " why=" why : "")
        . result, level)
}

; NOTIFYICONDATAW offsets, computed from A_PtrSize rather than hard-coded: the
; struct is 976 bytes on x64 and 956 on x86, and a wrong cbSize makes
; Shell_NotifyIcon fail silently with no useful error.
MTIcon_Offsets() {
    static o := ""
    if !IsObject(o) {
        p := A_PtrSize
        o := {}
        o.cbSize       := 0
        o.hWnd         := (p = 8) ? 8 : 4
        o.uID          := o.hWnd + p
        o.uFlags       := o.uID + 4
        o.uCallback    := o.uFlags + 4
        o.hIcon        := (p = 8) ? 32 : 20      ; 8-byte realign on x64
        o.szTip        := o.hIcon + p
        o.dwState      := o.szTip + 256          ; szTip is WCHAR[128]
        o.dwStateMask  := o.dwState + 4
        o.szInfo       := o.dwStateMask + 4
        o.uVersion     := o.szInfo + 512         ; szInfo is WCHAR[256]
        o.szInfoTitle  := o.uVersion + 4
        o.dwInfoFlags  := o.szInfoTitle + 128    ; szInfoTitle is WCHAR[64]
        o.guidItem     := o.dwInfoFlags + 4
        o.hBalloonIcon := o.guidItem + 16
        o.size         := o.hBalloonIcon + p
    }
    return o
}

MTIcon_BuildNid(flags, state := 0, stateMask := 0, tip := "") {
    st := MTIcon_State()
    o  := MTIcon_Offsets()

    if !IsObject(st.buf)
        st.buf := Buffer(o.size, 0)

    NumPut("UInt", o.size,       st.buf, o.cbSize)
    NumPut("Ptr",  A_ScriptHwnd, st.buf, o.hWnd)
    NumPut("UInt", st.uID,       st.buf, o.uID)
    NumPut("UInt", flags,        st.buf, o.uFlags)
    NumPut("UInt", 0x0404,       st.buf, o.uCallback)   ; TrayIconMsg listens here
    NumPut("Ptr",  st.hIcon,     st.buf, o.hIcon)
    NumPut("UInt", state,        st.buf, o.dwState)
    NumPut("UInt", stateMask,    st.buf, o.dwStateMask)

    if (tip != "") {
        DllCall("RtlZeroMemory", "Ptr", st.buf.Ptr + o.szTip, "UPtr", 256)
        StrPut(SubStr(tip, 1, 127), st.buf.Ptr + o.szTip, 127, "UTF-16")
    }
    return st.buf
}

; Mirrors the original TraySetIcon logic: when compiled, Ahk2Exe embeds
; MiniTray.ico as the exe's main icon, so never fall back to shell32 there or a
; good embedded icon gets replaced by a generic one.
MTIcon_Load() {
    cx := DllCall("GetSystemMetrics", "Int", 49, "Int")   ; SM_CXSMICON
    cy := DllCall("GetSystemMetrics", "Int", 50, "Int")   ; SM_CYSMICON

    if FileExist(ICON_FILE) {
        h := DllCall("LoadImageW", "Ptr", 0, "Str", ICON_FILE
            , "UInt", 1, "Int", cx, "Int", cy, "UInt", 0x10, "Ptr")   ; LR_LOADFROMFILE
        if h
            return h
    }
    if A_IsCompiled {
        h := DllCall("shell32\ExtractIconW", "Ptr", 0, "Str", A_ScriptFullPath
            , "UInt", 0, "Ptr")
        if (h && h != 1)
            return h
    } else {
        h := DllCall("shell32\ExtractIconW", "Ptr", 0, "Str", "shell32.dll"
            , "UInt", 44, "Ptr")
        if (h && h != 1)
            return h
    }
    return DllCall("LoadIconW", "Ptr", 0, "Ptr", 32512, "Ptr")        ; IDI_APPLICATION
}

MTIcon_Init() {
    st := MTIcon_State()

    if !st.hooked {
        if (m := DllCall("RegisterWindowMessage", "Str", "TaskbarCreated", "UInt")) {
            OnMessage(m, MTIcon_OnTaskbarCreated)
            st.hooked := true
        }
    }
    return MTIcon_Add()
}

MTIcon_Add() {
    st := MTIcon_State()
    if st.added
        return true

    if !st.hIcon
        st.hIcon := MTIcon_Load()

    ; NIF_MESSAGE | NIF_ICON | NIF_TIP
    nid := MTIcon_BuildNid(0x1 | 0x2 | 0x4, 0, 0, APP_NAME)
    ok  := DllCall("shell32\Shell_NotifyIconW", "UInt", 0, "Ptr", nid, "Int")  ; NIM_ADD

    st.added  := ok ? true : false
    st.hidden := false

    MTIcon_Log("NIM_ADD", ok)
    return ok
}

; Hide/show WITHOUT deleting the registration. Idempotent: if the icon is
; already in the requested state, nothing is sent at all.
MTIcon_SetHidden(hide, why := "") {
    st   := MTIcon_State()
    hide := !!hide

    if !st.added {
        DebugLog("MTIcon SetHidden(" hide ") while not registered; adding first", "DEBUG")
        if !MTIcon_Add()
            return false
    }
    if (st.hidden = hide)
        return true

    ; dwStateMask says only the NIS_HIDDEN bit of dwState is meaningful.
    nid := MTIcon_BuildNid(0x8, hide ? 0x1 : 0, 0x1)                  ; NIF_STATE / NIS_HIDDEN
    ok  := DllCall("shell32\Shell_NotifyIconW", "UInt", 1, "Ptr", nid, "Int")  ; NIM_MODIFY

    if ok
        st.hidden := hide

    MTIcon_Log("NIM_MODIFY " (hide ? "NIS_HIDDEN" : "VISIBLE"), ok, why)
    return ok
}

; Shutdown deliberately abandons the registration instead of sending NIM_DELETE.
; The owner HWND/process is about to disappear anyway. Avoiding an explicit delete
; removes MiniTray's last direct route into Explorer's crashing DeleteIcon path.
MTIcon_Abandon(why := "") {
    st := MTIcon_State()
    MTIcon_Log("ABANDON", 1, why " (no Shell_NotifyIcon call)")
    st.added := false
    return true
}

; Compatibility guard: if an older code path ever calls MTIcon_Destroy, suppress
; NIM_DELETE rather than reintroducing the crash trigger.
MTIcon_Destroy(why := "") {
    DebugLog("MTIcon_Destroy requested; NIM_DELETE intentionally suppressed", "INFO")
    return MTIcon_Abandon(why ? why : "legacy destroy request")
}

; The restarted shell has no record of our icon, so re-register and restore the
; state we believe it should be in.
MTIcon_OnTaskbarCreated(wParam, lParam, msg, hwnd) {
    st := MTIcon_State()
    MTIcon_Log("TASKBAR_CREATED", 1, "re-register after Explorer/taskbar restart")

    wasHidden := st.hidden
    st.added  := false
    if MTIcon_Add()
        if wasHidden
            MTIcon_SetHidden(true, "restore state after shell restart")
    return 0
}
