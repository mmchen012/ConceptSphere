#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon                     ; icon appears only while windows are hidden

; =============================================================================
;  MiniTray.ahk  -  v2.1 (Explorer stability guard)
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
;    Shift+Alt+Esc     restore the most recently hidden window
;    Ctrl+Alt+H        announce what is currently hidden
;    Ctrl+Alt+T        speech diagnostics (why is nothing being spoken?)
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
;                       ExplorerSafeHide=0|1 (default 1; Explorer folder
;                         windows are minimized before their taskbar button is
;                         removed instead of being hidden with SW_HIDE)
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
global CFG_SEC   := "__MiniTray__"
global OLD_CFG   := "__WindowSizer__"   ; pre-rename config section, migrated on startup
global HID_SEC   := "__Hidden__"
global MAX_LABEL := 60
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

;@Ahk2Exe-SetMainIcon MiniTray.ico

; --- WinEvent constants ------------------------------------------------------
global EV_FOREGROUND    := 0x0003
global EV_MINIMIZESTART := 0x0016
global EV_NAMECHANGE    := 0x800C

; --- state -------------------------------------------------------------------
global g_Rules    := []         ; parsed rule cache
global g_Stamp    := ""         ; INI mtime|size, to know when to reparse
global g_Cfg      := Map()      ; parsed [__MiniTray__]
global g_Hidden   := []         ; [{hwnd, pid, proc, title, how}] oldest first
global g_PopupGui  := 0           ; the tray popup, replacing AHK's tray menu
global g_PopupLB    := 0
global g_PopupItems := []         ; row index -> {kind, proc, hwnd}
global g_PopupProc  := ""         ; "" = application list, else the app we are in
global POPUP_SETTLE := 120        ; ms to let the popup finish closing before a
                                  ;   restore runs -- see PopupThen()         ; keeps Menu objects alive
global g_Queue    := []         ; WinEvent queue, drained off the hook thread
global g_Seen     := Map()      ; hwnd -> last auto-apply tick (per-window debounce)
global g_Hooks    := []
global g_CbProc   := 0
global g_Restoring := false     ; suppress auto-apply while we un-hide things
global g_Transitioning := Map()  ; hwnd -> start tick; blocks re-entrant hide/apply
global g_ShellPid := 0           ; invalidates cached shell COM after Explorer restarts

global g_EditSec  := ""        ; section being edited ("" = not yet written)
global g_EditNew  := false     ; true while the dialog is a Create, not an Edit
global g_EditHwnd := 0         ; window the dialog was invoked from
global g_EditClass := ""       ; both match values live here while the dialog is
global g_EditTitle := ""       ;   open; only one is shown in the shared box
global g_EditMode  := ""       ; which one the box currently holds: class|title
global g_SyncGuard := false    ; stops the edit/slider pair echoing each other

global g_MainGui  := 0
global g_EditGui  := 0
global g_LVOpen   := 0
global g_LVRules  := 0
global g_LVHidden := 0

; =============================================================================
;  STARTUP
; =============================================================================
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

; AHK's own main window is normally hidden, but the shell can foreground and
; show it when hosting a tray menu. WS_EX_TOOLWINDOW keeps it out of Alt+Tab
; whatever happens; applied now, while it is still hidden, so it is in force
; before anything can show it.
MakeToolWindow(A_ScriptHwnd)
HideScriptEdit()

; AHK's own tray menu is never shown -- see the TRAY POPUP section for why.
A_TrayMenu.Delete()
OnMessage(0x404, TrayIconMsg)     ; AHK_NOTIFYICON: the shell's tray-icon click

AdoptOrphans()                  ; recover windows stranded by a previous crash
RefreshTray()
RefreshShellIdentity()
InstallHooks()
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
^!m::ShowTrayPopup()            ; reachable even when the icon is auto-hidden
^!h::AnnounceHidden()
^!t::SpeechTest()

#HotIf (IsObject(g_PopupGui) && WinActive("ahk_id " g_PopupGui.Hwnd))
Enter::PopupActivate()
NumpadEnter::PopupActivate()
Right::PopupDrillIn()
Left::PopupBack()
Delete::PopupCloseSelected()
#HotIf
+Esc::HideActiveToTray()
^+l::RestoreAll()
!+Esc::RestoreLast()
^!+q::ExitApp()

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

; Speaks through NVDA when it is running and Speak=1; silently does nothing
; otherwise, so the script has no hard dependency on the controller client.
; cancel=false queues the line behind whatever the screen reader is already
; saying - used when there is no notification-area re-read to talk over, so the
; announcement of the window that just appeared is not clobbered.
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

; Announce() has four separate silent exits - Speak unset, DLL missing, load
; failed, NVDA not running - and from outside they look identical. This reports
; which one is happening instead of leaving it to guesswork.
SpeechTest() {
    global g_Cfg, APP_NAME, INI_FILE, g_StartedAt, g_QuietUntil
    path := NvdaDllPath()
    out := []
    out.Push("Running from : " A_ScriptDir)
    out.Push("Compiled     : " (A_IsCompiled ? "yes" : "no"))
    ; If the file on disk is NEWER than this process, a rebuilt exe exists but
    ; the old one is still running -- the single most expensive false trail in
    ; this project, because every symptom then reflects stale code.
    exeTime := ""
    try exeTime := FileGetTime(A_ScriptFullPath, "M")
    out.Push("Exe on disk  : " (exeTime = "" ? "?" : FormatTime(exeTime, "yyyy-MM-dd HH:mm:ss")))
    out.Push("This process : started " FormatTime(g_StartedAt, "yyyy-MM-dd HH:mm:ss")
           . ((exeTime != "" && exeTime > g_StartedAt)
              ? "   <-- STALE: the exe was rebuilt after this process started"
              : "   (up to date)"))
    out.Push("Elevated     : " (A_IsAdmin ? "yes - NVDA may fail to identify the"
                                          . " process, so appModules\minitray.py"
                                          . " would never load" : "no"))
    out.Push("Script window: " (IsToolWindow(A_ScriptHwnd) ? "tool window (out of Alt+Tab)"
                                                           : "NOT a tool window")
           . ", " (DllCall("User32\IsWindowVisible", "Ptr", A_ScriptHwnd)
                   ? "VISIBLE" : "hidden"))
    out.Push("Its title    : " WinGetTitle("ahk_id " A_ScriptHwnd))
    out.Push("Its edit ctrl: " ScriptEditState())
    out.Push("Settings file: " INI_FILE)
    out.Push("  (a compiled exe reads the INI beside ITSELF, not beside the source)")
    out.Push("")
    out.Push("Speak setting          : [" g_Cfg.Get("Speak", "(unset)") "]   (needs 1)")
    out.Push("HideIconWhenEmpty      : [" g_Cfg.Get("HideIconWhenEmpty", "(unset)") "]")
    out.Push("QuietPlugin            : [" g_Cfg.Get("QuietPlugin", "(unset)") "]"
           . "   (needs the minitrayQuiet NVDA add-on)")
    out.Push("Quiet window right now : "
           . (g_QuietUntil ? (g_QuietUntil - A_TickCount) " ms left" : "not quiet"))
    out.Push("")
    out.Push("DLL expected at : " path)
    out.Push("DLL file present: " (FileExist(path) ? "yes" : "NO - copy it here"))

    h := DllCall("LoadLibrary", "Str", path, "Ptr")
    out.Push("LoadLibrary     : " (h ? "ok, handle " h : "FAILED, GetLastError " A_LastError))

    if (h) {
        run := DllCall("nvdaControllerClient64\nvdaController_testIfRunning", "UInt")
        out.Push("NVDA running    : " (run = 0 ? "yes" : "NO - testIfRunning returned " run))
        if (run = 0) {
            DllCall("nvdaControllerClient64\nvdaController_cancelSpeech", "UInt")
            r := DllCall("nvdaControllerClient64\nvdaController_speakText"
                       , "Str", "MiniTray speech test", "UInt")
            out.Push("speakText       : returned " r "   (0 = accepted)")
            out.Push("")
            out.Push("If you heard nothing but this says 0, the call is being")
            out.Push("accepted and something is cancelling it afterwards.")
        }
    }
    MsgBox(Join(out, "`n"), APP_NAME " - speech test", "Iconi")
}

AnnounceHidden() {
    global g_Hidden
    if (g_Hidden.Length = 0) {
        Say("Nothing hidden")
        return
    }
    parts := []
    for e in g_Hidden
        parts.Push(e.proc " " e.title)
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
    txt .= "AutoApply=1" nl
    txt .= "; Safer Explorer path: minimize first, then remove the taskbar button" nl
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
    bw := b.r - b.l, bh := b.b - b.t
    if (bw <= 0 || bh <= 0)
        return false

    if (w > bw)
        w := bw
    if (h > bh)
        h := bh
    if (x < b.l)
        x := b.l
    if (y < b.t)
        y := b.t
    if (x + w > b.r)
        x := b.r - w
    if (y + h > b.b)
        y := b.b - h
    return true
}

IsInt(v) => RegExMatch(Trim(v . ""), "^-?\d+$") > 0

; =============================================================================
;  APPLY
; =============================================================================
ApplyRule(r, hwnd) {
    if !hwnd || !WinExist("ahk_id " hwnd)
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
        if (WinGetMinMax("ahk_id " hwnd) != 0)
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
    if (r && ApplyRule(r, hwnd))
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
    global g_Hooks, g_CbProc, EV_FOREGROUND, EV_MINIMIZESTART, EV_NAMECHANGE
    if (g_CbProc)
        return
    g_CbProc := CallbackCreate(WinEventProc, "F", 7)
    for ev in [EV_FOREGROUND, EV_MINIMIZESTART, EV_NAMECHANGE] {
        h := DllCall("User32\SetWinEventHook", "UInt", ev, "UInt", ev
                   , "Ptr", 0, "Ptr", g_CbProc, "UInt", 0, "UInt", 0
                   , "UInt", 0x2, "Ptr")             ; OUTOFCONTEXT | SKIPOWNPROCESS
        if (h)
            g_Hooks.Push(h)
    }
}

RemoveHooks() {
    global g_Hooks, g_CbProc
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
    }
}

HandleEvent(ev, hwnd) {
    global EV_FOREGROUND, EV_MINIMIZESTART, EV_NAMECHANGE, g_Restoring

    ; WinEvents may re-enter while an earlier event is still being handled.
    ; Never auto-apply or queue another hide against a window in the middle of
    ; a hide/restore transaction, or against one already owned by MiniTray.
    if (g_Restoring || IsOwnWindow(hwnd) || IsTransitioning(hwnd) || FindHidden(hwnd))
        return

    if (ev = EV_FOREGROUND) {
        if Debounced(hwnd, 250)
            return
        TryAutoApply(hwnd)
    } else if (ev = EV_NAMECHANGE) {
        if (DllCall("User32\GetForegroundWindow", "Ptr") != hwnd)
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

; Reports whether HideScriptEdit() actually found and hid the control -- that
; Edit is what a screen reader describes as "edit multiline blank".
ScriptEditState() {
    found := 0, shown := 0
    try {
        for c in WinGetControlsHwnd("ahk_id " A_ScriptHwnd) {
            if (WinGetClass("ahk_id " c) = "Edit") {
                found++
                if DllCall("User32\IsWindowVisible", "Ptr", c)
                    shown++
            }
        }
    } catch {
        return "could not enumerate controls"
    }
    if (!found)
        return "none found"
    return found . " found, " . (shown ? shown . " STILL VISIBLE" : "all hidden")
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

; Reports whether the tool-window style actually stuck.
IsToolWindow(hwnd) {
    static GWL_EXSTYLE := -20, WS_EX_TOOLWINDOW := 0x80
    fn := (A_PtrSize = 8) ? "User32\GetWindowLongPtrW" : "User32\GetWindowLongW"
    return (DllCall(fn, "Ptr", hwnd, "Int", GWL_EXSTYLE, "Ptr") & WS_EX_TOOLWINDOW) != 0
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
    SetTimer(HideToTray.Bind(hwnd), -150)            ; let the minimise finish
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

RefreshShellIdentity() {
    global g_ShellPid
    pid := 0
    try pid := WinGetPID("ahk_class Shell_TrayWnd")
    if (pid != g_ShellPid) {
        changed := (g_ShellPid != 0)
        g_ShellPid := pid
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
    static skip := ["Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW"
                  , "Windows.UI.Core.CoreWindow", "MultitaskingViewFrame"
                  , "Windows.UI.Composition.DesktopWindowContentBridge"]
    try cls := WinGetClass("ahk_id " hwnd)
    catch
        return true
    for c in skip
        if (cls = c)
            return true
    return false
}

FindHidden(hwnd) {
    global g_Hidden
    for i, e in g_Hidden
        if (e.hwnd = hwnd)
            return i
    return 0
}

HideActiveToTray() {
    hwnd := WinExist("A")
    ; AHK briefly foregrounds its own main window to display a popup menu, so
    ; "A" really can be us for an instant after Ctrl+Alt+M or a tray click.
    if (!hwnd || IsOwnWindow(hwnd) || IsShellWindow(hwnd) || FindHidden(hwnd)) {
        Nope()
        return
    }
    HideToTray(hwnd)
}

HideToTray(hwnd) {
    global g_Hidden, g_Cfg
    ; Also guarded here, not just in the caller: MaybeHideOnMinimize reaches
    ; this directly from the WinEvent dispatcher. The transition guard is set
    ; before any operation that can generate another WinEvent.
    if (!WinExist("ahk_id " hwnd) || IsOwnWindow(hwnd) || FindHidden(hwnd))
        return
    if !BeginTransition(hwnd)
        return

    recorded := false
    taskbarRemoved := false
    speechHandedOff := false

    ; Open the NVDA quiet window BEFORE WinMinimize/WinHide. Previously this
    ; happened after Explorer had already moved focus, so NVDA had time to queue
    ; the transient "<page title> document" and "same page link" lines.
    StartQuiet()

    try {
        try {
            title := WinGetTitle("ahk_id " hwnd)
            pid   := WinGetPID("ahk_id " hwnd)
            exe   := StrLower(WinGetProcessName("ahk_id " hwnd))
        } catch {
            Nope()
            return
        }
        proc := AppNameFor(hwnd)
        if (title = "")
            title := "(untitled)"

        ; Grab the focused control BEFORE hiding - once the window goes, the
        ; keyboard focus has already moved elsewhere and this returns nothing.
        focus := 0
        try focus := ControlGetFocus("ahk_id " hwnd)

        how := "hide"
        explorerSafe := (exe = "explorer.exe"
                      && g_Cfg.Get("ExplorerSafeHide", "1") = "1")

        if explorerSafe {
            ; Explorer folder windows share a process with the desktop shell on
            ; many systems. Let Explorer perform a normal minimize first, wait
            ; for that transition to settle, and only then remove its taskbar
            ; button. This avoids forcing SW_HIDE into an active shell window.
            try WinMinimize("ahk_id " hwnd)
            catch {
                Nope()
                return
            }
            if !WaitForMinimized(hwnd, 700) {
                try WinRestore("ahk_id " hwnd)
                Nope()
                return
            }
            Sleep 100
            if !TaskbarTab(hwnd, false) {
                try WinRestore("ahk_id " hwnd)
                Nope()
                return
            }
            taskbarRemoved := true
            how := "min"
        } else {
            try WinHide("ahk_id " hwnd)
            catch {
                Nope()
                return
            }
            Sleep 60
            if DllCall("User32\IsWindowVisible", "Ptr", hwnd) {
                try WinMinimize("ahk_id " hwnd)
                if !WaitForMinimized(hwnd, 700) {
                    Nope()
                    return
                }
                if !TaskbarTab(hwnd, false) {
                    try WinRestore("ahk_id " hwnd)
                    Nope()
                    return
                }
                taskbarRemoved := true
                how := "min"
            }
        }

        if !WinExist("ahk_id " hwnd)
            return

        g_Hidden.Push({ hwnd: hwnd, pid: pid, proc: proc, title: title
                      , how: how, focus: focus })
        recorded := true
        SaveHidden()
        RefreshTray()

        ; Move focus away while NVDA is already quiet. Do not append the new
        ; foreground window's title: that was transient focus context, not the
        ; result of the user's Shift+Escape command.
        if !FocusNextWindow(hwnd)
            FocusDesktop()

        ; MTFINAL is allowed through by conceptSphereQuiet while every ordinary
        ; focus/title announcement remains suppressed. There is no settle delay,
        ; so this is heard as soon as the hide transaction has completed.
        SayQuietFinal(proc " hidden")
        speechHandedOff := true
    } finally {
        EndTransition(hwnd)

        ; Any failed/aborted path must reopen NVDA immediately. A successful path
        ; hands ownership to SayQuietFinal(), which closes after its short tail.
        if !speechHandedOff
            EndQuiet()

        ; Roll back a taskbar deletion if the transaction failed before the
        ; window was committed to g_Hidden. Never leave an untracked window.
        if (!recorded && taskbarRemoved && WinExist("ahk_id " hwnd))
            TaskbarTab(hwnd, true)
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
                WinActivate("ahk_id " hwnd)
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
    ; A normal minimize often transfers foreground by itself. Reuse that result
    ; instead of generating a second activation/focus storm.
    fg := DllCall("User32\GetForegroundWindow", "Ptr")
    if (fg && fg != skip && !IsOwnWindow(fg) && !FindHidden(fg)
            && IsAltTabWindow(fg))
        return fg

    for hwnd in WinGetList() {
        if (hwnd = skip || IsOwnWindow(hwnd) || FindHidden(hwnd))
            continue
        if !IsAltTabWindow(hwnd)
            continue
        try WinActivate("ahk_id " hwnd)
        return hwnd
    }
    return 0
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

Reveal(e, activate := false) {
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
        ReturnFocus(e)
    }
}

; Showing a window does not restore the keyboard focus that was inside it -
; most apps focus their default control instead. Put the caret back where the
; user left it. Tried twice: once immediately, and once after the app has had a
; moment to run its own activation handling and possibly overwrite us.
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

RestoreOne(hwnd, *) {
    global g_Hidden, SPEECH_SETTLE
    if !(i := FindHidden(hwnd))
        return

    ; Last one out: take the Ctrl+Shift+L path, which does not trigger the
    ; notification-area re-read, and say exactly what it says.
    if (g_Hidden.Length = 1) {
        RestoreEverything(true)          ; this path DOES need the utterance
        return
    }

    e := g_Hidden[i]
    quiet := StillFocused(e.hwnd)        ; must be asked BEFORE we activate
    StartQuiet(SPEECH_SETTLE + 400)
    Reveal(e, true)
    Forget(hwnd)
    SaveHidden(), RefreshTray()
    ; Silent unless focus never left the window, in which case showing it
    ; produces no focus change and nothing would be announced at all.
    SayAfterTrayChange(quiet ? e.proc " " e.title : "")
}

CloseOne(hwnd, *) {
    global g_Hidden
    said := ""
    if (i := FindHidden(hwnd)) {
        e := g_Hidden[i]
        Dismiss(e)
        said := "Closed " e.proc " " e.title
    }
    Forget(hwnd)
    SaveHidden(), RefreshTray()
    if (said != "")
        SayAfterTrayChange(said)
}

RestoreGroup(proc, *) {
    global g_Hidden, g_Restoring
    g_Restoring := true
    last := 0
    for e in g_Hidden.Clone()
        if (e.proc = proc)
            Reveal(e), last := e
    g_Restoring := false
    if (last)                            ; leave the last one focused, as a
        Reveal(last, true)               ;   single restore would
    ForgetProc(proc)
    SaveHidden(), RefreshTray()
    SayAfterTrayChange("Restored all " proc " windows")
}

CloseGroup(proc, *) {
    global g_Hidden, g_Cfg, APP_NAME
    if (g_Cfg.Get("ConfirmCloseAll", "1") = "1") {
        n := 0
        for e in g_Hidden
            if (e.proc = proc)
                n++
        if (MsgBox("Close " n " hidden " proc " window(s)?", APP_NAME, "YesNo Icon!") != "Yes")
            return
    }
    for e in g_Hidden.Clone()
        if (e.proc = proc)
            Dismiss(e)
    ForgetProc(proc)
    SaveHidden(), RefreshTray()
    SayAfterTrayChange("Closed all " proc " windows")
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
RestoreEverything(saySummary) {
    global g_Hidden, g_Restoring, g_Cfg
    ; Nothing to restore: say so and get out WITHOUT going quiet. There is no
    ; focus change coming and no deferred line of ours to protect, so opening a
    ; quiet window here would only mute the screen reader -- which is what
    ; swallowed an NVDA command pressed straight afterwards.
    if (!g_Hidden.Length) {
        EndQuiet()                       ; close any window still open
        if (saySummary)
            Announce("Nothing hidden")   ; immediate; nothing to talk over
        else
            Nope()
        return
    }

    ; Before any reveal: each one is a focus change the reader announces, and
    ; going quiet after the fact only truncates the first of them.
    StartQuiet()
    n := g_Hidden.Length
    last := n ? g_Hidden[n] : 0

    ; Reveal everything EXCEPT the last one. It used to be revealed here and
    ; again below, and each reveal is an event a screen reader announces.
    g_Restoring := true
    for i, e in g_Hidden.Clone()
        if (i != n)
            Reveal(e)
    g_Restoring := false

    quiet := last ? StillFocused(last.hwnd) : false
    if (last)
        Reveal(last, true)

    g_Hidden := []
    SaveHidden(), RefreshTray()

    ; ONE sentence, spoken LAST.
    ;
    ; Speaking before activating gets us cut off: focusing a window makes the
    ; reader announce its whole ancestry (window, then document, then landmark
    ; for a browser), and each of those cancels what came before. That burst is
    ; NVDA's normal behaviour on any focus change -- plain Alt+Tab produces the
    ; identical repetition -- so it cannot be prevented from here, only talked
    ; over. Our line is deferred past it and cancels first, which is why it has
    ; to carry the title itself.
    said := ""
    if (last && saySummary)
        said := "All windows restored. " last.proc " " last.title
    else if (last && quiet)
        said := last.proc " " last.title
    if (said != "")
        SayAfterTrayChange(said)
    else
        EndQuiet()                       ; nothing to say, so re-open the floor
}

RestoreLast(*) {
    global g_Hidden, SPEECH_SETTLE
    if (g_Hidden.Length = 0) {
        Nope()
        return
    }
    ; Last one out: same path as Ctrl+Shift+L, which is clean from a hotkey --
    ; nothing is closing underneath it, so there is no focus churn to cancel our
    ; speech and let the tray reflow through.
    if (g_Hidden.Length = 1) {
        RestoreEverything(false)
        return
    }
    e := g_Hidden[g_Hidden.Length]
    quiet := StillFocused(e.hwnd)        ; must be asked BEFORE we activate
    StartQuiet(SPEECH_SETTLE + 400)
    Reveal(e, true)
    g_Hidden.RemoveAt(g_Hidden.Length)
    SaveHidden(), RefreshTray()
    SayAfterTrayChange(quiet ? e.proc " " e.title : "")
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
    for i, e in g_Hidden
        IniWrite(e.hwnd "|" e.pid "|" e.how "|" e.focus "|" e.proc "|" e.title
               , INI_FILE, HID_SEC, "W" i)
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
        ; 6 fields is the current layout, 5 is a record written before the
        ; focus handle was added. A window title may itself contain "|", so
        ; everything from the title onwards is rejoined rather than indexed.
        if (f.Length >= 6)
            focus := f[4] + 0, proc := f[5], title := JoinFrom(f, 6, "|")
        else
            focus := 0,        proc := f[4], title := JoinFrom(f, 5, "|")
        hwnd := f[1] + 0, pid := f[2] + 0
        if (!WinExist("ahk_id " hwnd) || IsOwnWindow(hwnd))
            continue                     ; a recycled HWND could now be ours
        ; the HWND could have been recycled by an unrelated window
        try {
            if (WinGetPID("ahk_id " hwnd) != pid)
                continue
        } catch
            continue
        if DllCall("User32\IsWindowVisible", "Ptr", hwnd) && f[3] != "min"
            continue                                  ; not actually hidden
        g_Hidden.Push({ hwnd: hwnd, pid: pid, how: f[3], proc: proc
                      , title: title, focus: focus })
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
    for e in g_Hidden {
        if !groups.Has(e.proc) {
            groups[e.proc] := []
            order.Push(e.proc)
        }
        groups[e.proc].Push(e)
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
StartQuiet(maxMs := 0) {
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
    SendQuiet(QUIET_CHUNK)               ; suppress what is about to be queued,
    Announce("", true)                   ;   THEN cut off what is already
                                         ;   playing -- the plugin cannot reach
                                         ;   audio that is already rendering
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

; Speak one command-result announcement through conceptSphereQuiet without
; dropping the quiet window first. This closes the race in EndQuiet()+Announce(),
; where queued foreground speech could enter between those two controller calls.
SayQuietFinal(text) {
    global g_QuietUntil, QUIET_FINAL_TAIL, g_Cfg

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

    g_QuietUntil := A_TickCount + QUIET_FINAL_TAIL
    Announce(Chr(1) "MTFINAL:" text Chr(1), true)
    SetTimer(EndQuiet, -QUIET_FINAL_TAIL)
}

SaySoon(text) {
    global g_SoonSay, SPEECH_SETTLE, g_Cfg
    if (g_Cfg.Get("Speak", "0") != "1")
        return
    g_SoonSay := text
    StartQuiet(SPEECH_SETTLE + 200)
    SetTimer(FlushSoonSay, -SPEECH_SETTLE)
}

FlushSoonSay() {
    global g_SoonSay
    if (g_SoonSay = "")
        return
    text := g_SoonSay
    g_SoonSay := ""
    EndQuiet()                           ; close the window BEFORE we speak, or
    Announce(text)                       ;   the plugin drops our own line too
}

; Speaking at the moment of the restore LOSES the race: the icon is not removed
; until ICON_HIDE_DELAY later, so the shell's notification-area re-read starts
; after we have already finished talking. The line is queued instead and spoken
; just after the icon actually goes, where cancelSpeech can cut the shell off.
; Every path out of here must either hand the quiet window on to something that
; will close it, or close it here -- a window left open mutes the screen reader
; until QUIET_MAX expires, and swallows our own line with it.
SayAfterTrayChange(text) {
    global g_PendingSay, g_PendingArmed, g_Hidden, g_Cfg
    if (g_Cfg.Get("Speak", "0") != "1") {
        EndQuiet()
        return
    }

    removing := (!g_Hidden.Length && g_Cfg.Get("HideIconWhenEmpty", "0") = "1")
    if (!removing) {
        if (text != "")                  ; nothing to talk over; just say it,
            SaySoon(text)                ;   once the focus events have settled
        else
            EndQuiet()
        return
    }
    ; The icon is about to go, and that reflow is what the shell reads aloud.
    ; Queue for just after the removal: speak if we have something to say,
    ; otherwise cancel silently - which suppresses the re-read on its own.
    g_PendingSay := text
    g_PendingArmed := true
    StartQuiet()                         ; closed in FlushPendingSay
}

FlushPendingSay() {
    global g_PendingSay, g_PendingArmed
    if (!g_PendingArmed)
        return
    text := g_PendingSay
    g_PendingSay := "", g_PendingArmed := false
    EndQuiet()                           ; close the window BEFORE we speak
    Announce(text)                       ; "" here cancels and says nothing
}

; Idempotent: if something was hidden again inside the delay window, this
; correctly leaves the icon showing.
UpdateTrayIcon() {
    global g_Hidden, g_Cfg, g_PendingSay, ANNOUNCE_AFTER_HIDE
    global ICON_HIDE_RETRY, ICON_HIDE_RETRIES
    static tries := 0

    if (g_Hidden.Length || g_Cfg.Get("HideIconWhenEmpty", "0") != "1") {
        tries := 0
        A_IconHidden := false
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
    A_IconHidden := true
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
; The list DRILLS IN rather than expanding in place. A tree was tried and is
; wrong for this: once a node expands, up and down walk through both levels
; mixed together. A submenu keeps the levels separate -- at the top you move
; through applications only, and inside one you move through its windows only.
;   Up / Down     move within the current level
;   Right         open the selected application, to pick out one window
;   Left          back to the list of applications
;   Enter         on an application, restore ALL of its windows;
;                 on a window, restore it; on a command, run it
;   Delete        close the selected window (or the whole application)
;   Esc           back one level, or close the popup at the top level

TrayIconMsg(wParam, lParam, msg, hwnd) {
    static WM_LBUTTONUP := 0x202, WM_LBUTTONDBLCLK := 0x203, WM_RBUTTONUP := 0x205
    if (lParam = WM_RBUTTONUP || lParam = WM_LBUTTONUP || lParam = WM_LBUTTONDBLCLK)
        SetTimer(ShowTrayPopup, -1)      ; get off the message handler first
    return 0                             ; suppress AHK's built-in tray menu
}

ShowTrayPopup(*) {
    global g_PopupGui, g_PopupLB, g_PopupProc
    if !g_PopupGui
        BuildTrayPopup()
    g_PopupProc := ""                    ; always open at the application list
    FillTrayPopup()

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
}

BuildTrayPopup() {
    global g_PopupGui, g_PopupLB, APP_NAME
    g := Gui("-MaximizeBox -MinimizeBox +AlwaysOnTop", APP_NAME)
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 10, g.MarginY := 10

    ; A ListBox rather than a TreeView: one flat level at a time, announced as
    ; "item N of M", which is how a menu reads.
    g_PopupLB := g.Add("ListBox", "w460 r12 vPopupList")
    g_PopupLB.OnEvent("DoubleClick", (*) => PopupActivate())

    g.OnEvent("Close", (*) => HideTrayPopup())
    g.OnEvent("Escape", (*) => PopupEscape())
    g.OnEvent("ContextMenu", PopupContextMenu)
    g_PopupGui := g
}

HideTrayPopup(*) {
    global g_PopupGui, g_PopupProc
    g_PopupProc := ""
    if g_PopupGui
        try g_PopupGui.Hide()
}

; Esc backs out of an application first, like closing a submenu.
PopupEscape(*) {
    global g_PopupProc
    if (g_PopupProc != "") {
        g_PopupProc := ""
        FillTrayPopup()
        return
    }
    HideTrayPopup()
}

FillTrayPopup() {
    global g_PopupLB, g_PopupItems, g_PopupProc, g_Hidden
    if !g_PopupLB
        return

    rows := [], g_PopupItems := []
    grp := GroupByProcess()

    if (g_PopupProc != "" && grp.groups.Has(g_PopupProc)) {
        ; --- inside one application ---------------------------------------
        ; No "back" row: Left arrow and Esc both return to the application list.
        for e in grp.groups[g_PopupProc] {
            rows.Push(MenuLabel(e.title))
            g_PopupItems.Push({ kind: "win", proc: g_PopupProc, hwnd: e.hwnd })
        }
        rows.Push("Restore all " g_PopupProc " windows")
        g_PopupItems.Push({ kind: "restoreapp", proc: g_PopupProc, hwnd: 0 })
        rows.Push("Close all " g_PopupProc " windows")
        g_PopupItems.Push({ kind: "closeapp", proc: g_PopupProc, hwnd: 0 })
    } else {
        ; --- the application list ------------------------------------------
        g_PopupProc := ""
        for proc in grp.order {
            rows.Push(proc " (" grp.groups[proc].Length ")")
            g_PopupItems.Push({ kind: "app", proc: proc, hwnd: 0 })
        }
        if (!grp.order.Length) {
            rows.Push("No hidden windows")
            g_PopupItems.Push({ kind: "none", proc: "", hwnd: 0 })
        } else {
            rows.Push("Restore all hidden windows")
            g_PopupItems.Push({ kind: "restoreall", proc: "", hwnd: 0 })
        }
        rows.Push("Window rules    Ctrl+Alt+5")
        g_PopupItems.Push({ kind: "rules", proc: "", hwnd: 0 })
        rows.Push("Exit MiniTray    Ctrl+Alt+Shift+Q")
        g_PopupItems.Push({ kind: "exit", proc: "", hwnd: 0 })
    }

    g_PopupLB.Delete()
    g_PopupLB.Add(rows)
    g_PopupLB.Choose(1)
}

; Runs a restore the way the HOTKEYS do.
;
; Invoking it inline leaves the popup closing underneath: hiding a focused
; window is itself a focus change, the screen reader announces whatever gains
; focus next, and that cancels our announcement -- which frees the floor for the
; notification-area re-read. Ctrl+Shift+L has no such churn because nothing is
; closing when it fires. Getting the popup out of the way FIRST, then running
; the same code a moment later, makes the two paths behave identically.
PopupThen(action) {
    global POPUP_SETTLE, SPEECH_SETTLE
    ; Go quiet FIRST. Hiding the popup is itself a focus change, and the action
    ; that opens the quiet window does not run until POPUP_SETTLE later -- so
    ; the popup's own closing announcement was landing in the unprotected gap
    ; before it. The action re-opens the window for its own duration; this only
    ; has to cover from here until then.
    StartQuiet(POPUP_SETTLE + SPEECH_SETTLE + 400)
    HideTrayPopup()
    SetTimer(action, -POPUP_SETTLE)
}

PopupSelectedItem() {
    global g_PopupLB, g_PopupItems
    if !g_PopupLB
        return 0
    idx := g_PopupLB.Value
    return (idx && idx <= g_PopupItems.Length) ? g_PopupItems[idx] : 0
}

; Enter, or double-click.
PopupActivate(*) {
    global g_PopupProc
    if !(it := PopupSelectedItem())
        return
    if (it.kind = "app") {
        ; Enter / double-click on an application restores the whole group.
        ; Right arrow is what opens it to pick out one window.
        PopupThen(RestoreGroup.Bind(it.proc))
    } else if (it.kind = "win") {
        PopupThen(RestoreOne.Bind(it.hwnd))
    } else if (it.kind = "restoreapp") {
        PopupThen(RestoreGroup.Bind(it.proc))
    } else if (it.kind = "closeapp") {
        CloseGroup(it.proc)
        g_PopupProc := ""
        FillTrayPopup()
    } else if (it.kind = "restoreall") {
        PopupThen(RestoreAll)
    } else if (it.kind = "rules") {
        HideTrayPopup()
        ShowMainGui()
    } else if (it.kind = "exit") {
        ExitApp()
    }
}

; Right arrow: only meaningful on an application.
PopupDrillIn(*) {
    global g_PopupProc
    if !(it := PopupSelectedItem())
        return
    if (it.kind = "app") {
        g_PopupProc := it.proc
        FillTrayPopup()
    }
}

PopupBack(*) {
    global g_PopupProc
    if (g_PopupProc = "")
        return
    g_PopupProc := ""
    FillTrayPopup()
}

; Delete: close the selected window, or the whole application.
PopupCloseSelected(*) {
    global g_PopupProc
    if !(it := PopupSelectedItem())
        return
    if (it.kind = "win") {
        CloseOne(it.hwnd)
        FillTrayPopup()                  ; stay put; the list just got shorter
    } else if (it.kind = "app" || it.kind = "closeapp") {
        CloseGroup(it.proc)
        g_PopupProc := ""
        FillTrayPopup()
    }
}

; Right-click, or the Applications key / Shift+F10.
;
; A popup menu is fine here, unlike AHK's tray menu: this one is owned by the
; popup window, which is a real titled window a screen reader can name.
PopupContextMenu(guiObj, ctrl, item, isRightClick, x, y) {
    global g_PopupLB
    if (ctrl != g_PopupLB)
        return
    if (item && item != g_PopupLB.Value)
        g_PopupLB.Choose(item)                ; act on what was clicked
    if !(it := PopupSelectedItem())
        return

    m := Menu()
    if (it.kind = "app") {
        m.Add("&Open", (*) => PopupDrillIn())
        m.Add("Restore &all", (*) => PopupThen(RestoreGroup.Bind(it.proc)))
        m.Add("&Close all",   (*) => PopupCloseSelected())
    } else if (it.kind = "win") {
        m.Add("&Restore", (*) => PopupActivate())
        m.Add("&Close",   (*) => PopupCloseSelected())
    } else {
        return                                ; commands need no context menu
    }
    m.Show()                                  ; blocks until dismissed
}

; Updates the tray icon, and the popup if it happens to be open. Named for what
; it does now -- there is no menu left to build.
RefreshTray() {
    global g_Hidden, g_Cfg, APP_NAME, g_PopupGui, ICON_HIDE_DELAY

    A_IconTip := APP_NAME                             ; constant, always

    ; Showing the icon is harmless at any moment. REMOVING it is not: deleting a
    ; notification-area icon makes the shell reflow that toolbar, and a screen
    ; reader then re-reads every remaining icon.
    if (g_Hidden.Length || g_Cfg.Get("HideIconWhenEmpty", "0") != "1")
        A_IconHidden := false
    else
        SetTimer(UpdateTrayIcon, -ICON_HIDE_DELAY)

    if (g_PopupGui && DllCall("User32\IsWindowVisible", "Ptr", g_PopupGui.Hwnd))
        FillTrayPopup()
}

; =============================================================================
;  MAIN GUI
; =============================================================================
ShowMainGui() {
    global g_MainGui
    if !g_MainGui
        BuildMainGui()
    RefreshOpen(), RefreshRules(), RefreshHidden(), LoadOptionsIntoGui()
    g_MainGui.Show()
    try g_MainGui["LVOpen"].Focus()
}

BuildMainGui() {
    global g_MainGui, g_LVOpen, g_LVRules, g_LVHidden, APP_NAME, INI_FILE

    ; Title is just the app name. The settings folder used to be appended here
    ; to show which INI was live; the Options tab now has a labelled field for
    ; that, which is a better home for a long path than the title bar.
    g := Gui("+Resize +MinSize900x520", APP_NAME)
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 12, g.MarginY := 12
    g.OnEvent("Close", (*) => g.Hide())
    g.OnEvent("Escape", (*) => g.Hide())

    tab := g.Add("Tab3", "xm ym w880 h420", ["Rules", "Hidden windows", "Options"])

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
    b.OnEvent("Click", (*) => ExitApp())

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
        if (IsOwnWindow(hwnd) || !IsAltTabWindow(hwnd))
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
    for e in g_Hidden
        g_LVHidden.Add("", e.proc, e.title, e.how = "min" ? "minimised" : "hidden", e.hwnd)
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
    global g_MainGui, g_Cfg, INI_FILE, CFG_SEC
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
    ; Act on the new settings now. HideIconWhenEmpty is only ever evaluated in
    ; RefreshTray(), which otherwise runs on hide/restore/close/prune -- so with
    ; nothing hidden, toggling it here would have had no visible effect at all
    ; until the next time a window was hidden and restored.
    RefreshTray()
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
    xLo := Min(vx, NumOr(rule.x, vx)),       xHi := Max(vx + vw, NumOr(rule.x, vx))
    yLo := Min(vy, NumOr(rule.y, vy)),       yHi := Max(vy + vh, NumOr(rule.y, vy))

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
    g.Add("CheckBox", "xm y+8 vROn" . (rule.on ? " Checked" : ""), "Rule enabled")

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
    SetNumRow(g, "RX", "SX", x)
    SetNumRow(g, "RY", "SY", y)
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

; =============================================================================
;  SHUTDOWN
; =============================================================================
; Deliberately minimal. #SingleInstance Force gives the outgoing instance only a
; few seconds before Windows offers to kill it, so the exit path does the one
; thing that MUST happen -- make every hidden window visible again -- and
; nothing else. It does NOT go through RestoreAll(), which activates a window,
; restores focus inside it on a timer, rewrites the INI, rebuilds the tray menu
; and queues speech. All of that is pointless while quitting and any of it can
; block long enough to trigger "Could not close the previous instance".
HandleExit(reason, code) {
    global g_Hidden, INI_FILE, HID_SEC
    RemoveHooks()
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
    return 0
}
