#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; =============================================================================
;  ConceptSphereWatchdog.ahk
;
;  One process that watches every RESIDENT ConceptSphere component and restarts
;  any that wedges or disappears. Replaces StartMenuWatchdog.ahk.
;
;  WHY: these scripts CONSUME keys before the app underneath sees them, so a
;  handler that stalls (typically a cross-process UIA call that never returns)
;  doesn't just stop working -- it makes the Start menu, the console, or Shift+Esc
;  appear completely dead to the keyboard. MiniTray is worse still: a wedged
;  instance leaves hidden windows with no route back.
;
;  HOW: each component is an AHK v2 script, so each owns a hidden message window
;  of class "AutoHotkey". Pinging it with WM_NULL + SMTO_ABORTIFHUNG costs the
;  target nothing and returns instantly if its message loop is stuck. N
;  consecutive misses means genuinely wedged, not merely busy.
;
;  NOT WATCHED: DesktopFocus.exe. It is a ONE-SHOT script -- it opens the desktop
;  folder, focuses the first item and exits. It is supposed to be absent, so
;  watching it would restart it forever. Do not add it to COMPONENTS.
;
;  MUST RUN ELEVATED. The components run at RunLevel Highest from logon tasks and
;  a normal-integrity process cannot terminate them. It self-elevates on startup;
;  register it as a logon task with RunLevel Highest, exactly like the others.
;
;  Hotkeys:  Ctrl+Alt+Shift+W  status report
;            Ctrl+Alt+Shift+P  pause / resume all watching (do this before you
;                              recompile anything, or a stopped task looks like a
;                              crash and gets restarted under your build)
; =============================================================================


; =============================================================================
;  CONFIGURATION
; =============================================================================
; One entry per resident component. Adding a component is one line.
;
;   name     spoken and logged label
;   exe      process to watch, expected to live in EXE_DIR
;   task     scheduled task to restart it through, so it comes back at the same
;            integrity level and user context it gets at logon. Left blank, or
;            wrong, the task is discovered from the exe path instead (see
;            ResolveTask) and a direct Run is the last resort.
;   strikes  consecutive missed pings before acting. EnhancedStartMenu gets an
;            extra one: its first UIA read after a cold Start can legitimately
;            block ~2 s.
;   missing  true  = also restart when the process is absent
;            false = only rescue it when it is running but wedged. MiniTray is
;                    false because it has its own Exit item (Ctrl+Alt+Shift+Q),
;                    and a watchdog that resurrects it makes quitting impossible.

global EXE_DIR := A_ScriptDir              ; components live beside this script

global COMPONENTS := [
    { name: "Enhanced Start Menu", exe: "EnhancedStartMenu.exe"
    , task: "Enhanced Start Menu", strikes: 4, missing: true  },

    { name: "Console Select All" , exe: "ConsoleSelectAll.exe"
    , task: "Console Select All" , strikes: 3, missing: true  },

    { name: "MiniTray"           , exe: "MiniTray.exe"
    , task: "MiniTray"           , strikes: 3, missing: false }
]

global CHECK_MS      := 2000     ; ms between rounds of pings
global PING_MS       := 1000     ; ms to wait for a WM_NULL reply
global STARTUP_MS    := 20000    ; ms of quiet at logon before the first round
global COOLDOWN_MS   := 20000    ; ms of grace for a component after a restart
global VERIFY_MS     := 12000    ; ms to wait for a restarted component to answer
global MAX_PER_HOUR  := 4        ; restarts before a component is quarantined
global UNQUARANTINE_MS := 3600000 ; ms of calm before a quarantined component is
                                 ; watched again. RateLimited already forgets
                                 ; restarts older than an hour, but the
                                 ; quarantine flag never cleared by itself, so a
                                 ; bad patch could silently disable the watchdog
                                 ; until someone clicked the tray menu.
                                 ; Set to 0 to keep quarantine manual-only.
global LOG_FILE      := A_Temp "\ConceptSphereWatchdog.log"
global LOG_MAX_BYTES := 262144
global SPEAK         := 1        ; speak through NVDA when it is available
global BEEP          := 1        ; tones as well as speech


; =============================================================================
;  STATE
; =============================================================================

global g_Paused  := false
global g_Nvda    := 0
global g_UpBuf   := 0            ; keep WAV buffers alive: PlaySound is async
global g_DownBuf := 0
global g_LowBuf  := 0
global g_HighBuf := 0

for c in COMPONENTS {
    c.strikeCount   := 0
    c.cooldownUntil := 0
    c.ignored       := false     ; per-component pause, from the tray menu
    c.quarantined   := false     ; hit MAX_PER_HOUR, left alone until resumed
    c.history       := []        ; tick counts of recent restarts
    c.taskResolved  := ""        ; "" not looked up, "-" none found
    c.lastRestart   := ""
}


; =============================================================================
;  STARTUP
; =============================================================================

if !A_IsAdmin {
    try {
        if A_IsCompiled
            Run '*RunAs "' A_ScriptFullPath '" /restart'
        else
            Run '*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"'
    } catch
        MsgBox "ConceptSphere Watchdog must run elevated and could not elevate itself."
             , "ConceptSphere Watchdog", "Iconx"
    ExitApp
}

DetectHiddenWindows true
SetTitleMatchMode 2

g_LowBuf  := MakeToneWav(700, 70)
g_HighBuf := MakeToneWav(950, 70)
LoadNVDA()
BuildTray()

Log("watchdog started (elevated), exe dir " EXE_DIR)
for c in COMPONENTS
    Log("watching " . c.exe . ' (task "' . c.task . '", ' . c.strikes
      . " strikes, " . (c.missing ? "restart if missing" : "hung only") . ")")

SetTimer Sweep, -STARTUP_MS      ; let logon finish before judging anything
return


; =============================================================================
;  MAIN LOOP
; =============================================================================

Sweep() {
    static started := false
    if !started {
        started := true
        SetTimer Sweep, CHECK_MS
    }
    if g_Paused
        return

    for c in COMPONENTS
        CheckOne(c)
}

CheckOne(c) {
    ; Lift a quarantine once the component has been left alone long enough.
    ; RateLimited() prunes history on the same rolling hour, so by this point
    ; its restart count has already decayed and one more attempt is cheap.
    if (c.quarantined && UNQUARANTINE_MS && c.history.Length) {
        if (A_TickCount - c.history[c.history.Length] > UNQUARANTINE_MS) {
            c.quarantined := false
            c.strikeCount := 0
            Log(c.name ": quarantine lifted after " (UNQUARANTINE_MS // 60000) " min of calm")
        }
    }

    if c.ignored || c.quarantined || (A_TickCount < c.cooldownUntil)
        return

    hwnd := FindWindow(c.exe)

    if !hwnd && !ProcessExist(c.exe) {
        c.strikeCount := 0
        if c.missing
            Recover(c, "not running")
        return
    }

    ; Running. A window we cannot find, or one that will not answer, both mean
    ; the message loop is not serving requests.
    if hwnd && RespondingExe(c.exe) {
        if c.strikeCount
            Log(c.name ": responding again after " c.strikeCount " missed ping(s)")
        c.strikeCount := 0
        return
    }

    c.strikeCount += 1
    Log(c.name . ": " . (hwnd ? "no reply" : "no message window")
      . " (miss " . c.strikeCount . " of " . c.strikes . ")")

    if (c.strikeCount >= c.strikes) {
        c.strikeCount := 0
        Recover(c, "not responding")
    }
}

; Any window owned by the component. Do NOT hard-code AHK's main-window class
; here: this used to read `ahk_class AutoHotkey ahk_exe ...`, which never
; matched, so FindWindow always returned 0 and every component looked wedged
; forever. Matching on the exe alone survives whatever AHK calls its window.
; (DetectHiddenWindows is true, so the hidden main window is in scope.)
FindWindow(exe) {
    return WinExist("ahk_exe " exe)
}

; Responsive if ANY window the process owns answers. All of a script's windows
; are served by the same message loop, so pinging whichever one WinExist
; happened to return first is needlessly fragile -- a component that owns both
; a GUI and its hidden main window should not be judged on the luck of the draw.
RespondingExe(exe) {
    try {
        for hwnd in WinGetList("ahk_exe " exe)
            if Responding(hwnd)
                return true
    }
    return false
}

; WM_NULL costs the target nothing; SMTO_ABORTIFHUNG returns immediately when
; the thread is stuck instead of burning the whole timeout.
Responding(hwnd) {
    res := 0
    ok := DllCall("SendMessageTimeoutW"
        , "Ptr" , hwnd
        , "UInt", 0x0000
        , "Ptr" , 0
        , "Ptr" , 0
        , "UInt", 0x0002
        , "UInt", PING_MS
        , "Ptr*", &res)
    return ok ? true : false
}


; =============================================================================
;  RECOVERY
; =============================================================================

Recover(c, why) {
    c.cooldownUntil := A_TickCount + COOLDOWN_MS      ; set first: no re-entry

    if RateLimited(c) {
        c.quarantined := true
        Log(c.name . ": QUARANTINED after " . MAX_PER_HOUR
          . " restarts in an hour - left alone until resumed from the tray menu")
        Alert(c.name . " keeps failing. Watchdog has stopped restarting it.", false)
        return
    }

    Log(c.name ": restarting (" why ")")
    StopIt(c)
    StartIt(c)

    ok := false
    deadline := A_TickCount + VERIFY_MS
    while (A_TickCount < deadline) {
        Sleep 500
        if FindWindow(c.exe) && RespondingExe(c.exe) {
            ok := true
            break
        }
    }

    c.cooldownUntil := A_TickCount + COOLDOWN_MS
    c.history.Push(A_TickCount)

    if ok {
        c.lastRestart := FormatTime(, "HH:mm:ss")
        Log(c.name ": recovered, responding again")
        Alert(c.name " restarted", true)
    } else {
        c.cooldownUntil := A_TickCount + (COOLDOWN_MS * 6)   ; back off, don't hammer
        Log(c.name . ": restart FAILED, no response within " . (VERIFY_MS // 1000) . " s")
        Alert(c.name " restart failed", false)
    }
}

; Close politely first. A partly-responsive script gets to run its OnExit -- which
; for MiniTray is what un-hides windows -- and only a truly wedged one is killed.
; (A killed MiniTray is not a disaster either: it re-adopts orphaned windows from
; its INI at startup. Politeness is still cheaper than relying on that.)
StopIt(c) {
    if FindWindow(c.exe) {
        try {
            WinClose("ahk_exe " c.exe, , 2)
            if !ProcessExist(c.exe) {
                Log(c.name ": closed cleanly")
                return
            }
        }
    }

    if (task := ResolveTask(c)) != "-" {
        code := RunHidden('schtasks /end /tn "' task '"')
        Log(c.name ": schtasks /end -> " code)
        Sleep 500
    }

    loop 5 {
        if !(pid := ProcessExist(c.exe))
            return
        Log(c.name ": still running as pid " pid ", terminating")
        try ProcessClose(c.exe)
        Sleep 400
    }
}

StartIt(c) {
    if (task := ResolveTask(c)) != "-" {
        code := RunHidden('schtasks /run /tn "' task '"')
        Log(c.name ": schtasks /run -> " code)
        if (code = 0)
            return
    }

    ; No usable task. We are elevated, so a direct Run inherits high integrity,
    ; which is the property the task was giving us anyway.
    path := EXE_DIR "\" c.exe
    if !FileExist(path) {
        Log(c.name ": cannot start, " path " does not exist")
        return
    }
    try {
        Run '"' path '"', EXE_DIR
        Log(c.name ": started directly from " path)
    } catch as e
        Log(c.name ": direct start failed: " e.Message)
}

; Prefer the configured task name; if it is missing or renamed, find the task
; whose action actually points at this exe -- the same match the installer's
; cleanup uses. Result is cached, including "-" for "there isn't one".
ResolveTask(c) {
    if (c.taskResolved != "")
        return c.taskResolved

    if (c.task != "" && TaskExists(c.task))
        return c.taskResolved := c.task

    if (found := FindTaskByExe(c.exe)) != "" {
        Log(c.name . ': task "' . c.task . '" not found, using discovered task "'
          . found . '"')
        return c.taskResolved := found
    }

    Log(c.name ": no scheduled task found, will start the exe directly")
    return c.taskResolved := "-"
}

TaskExists(name) {
    return RunHidden('schtasks /query /tn "' name '"') = 0
}

FindTaskByExe(exe) {
    tmp := A_Temp "\cs-watchdog-tasks.csv"
    if (RunHidden('schtasks /query /fo csv /v > "' tmp '"') != 0)
        return ""
    text := ""
    try text := FileRead(tmp, "UTF-8")
    try FileDelete tmp
    for line in StrSplit(text, "`n", "`r") {
        if !InStr(line, exe)
            continue
        f := CsvFields(line)
        if (f.Length >= 2 && f[2] != "TaskName" && f[2] != "")
            return f[2]
    }
    return ""
}

; schtasks needs a shell for the redirection, and Hide keeps a console window
; from flashing over whatever has focus.
RunHidden(cmd) {
    try return RunWait(A_ComSpec ' /c ' cmd, , "Hide")
    catch as e
        Log("command failed: " cmd " -- " e.Message)
    return -1
}

CsvFields(line) {
    out := [], cur := "", inQ := false
    loop parse line {
        ch := A_LoopField
        if (ch = '"')
            inQ := !inQ
        else if (ch = "," && !inQ)
            out.Push(cur), cur := ""
        else
            cur .= ch
    }
    out.Push(cur)
    return out
}

; A component that fails repeatedly is broken, not unlucky; restarting it every
; 20 s just buries the evidence and talks over the screen reader.
RateLimited(c) {
    cutoff := A_TickCount - 3600000
    kept := []
    for t in c.history
        if (t > cutoff)
            kept.Push(t)
    c.history := kept
    return kept.Length >= MAX_PER_HOUR
}


; =============================================================================
;  NOTIFICATION
; =============================================================================

Alert(text, good) {
    if BEEP {
        PlayBuf(good ? g_LowBuf : g_HighBuf)
        Sleep 110
        PlayBuf(good ? g_HighBuf : g_LowBuf)      ; rising = fixed, falling = not
    }
    Say(text)
}

; Own sine WAV rather than MessageBeep/SoundBeep: the Default Beep sound-scheme
; event is silent on this machine, and system beeps get dropped while another
; sound is playing.
MakeToneWav(freq, ms, vol := 0.45, rate := 44100) {
    samples := Round(rate * ms / 1000)
    dataLen := samples * 2
    buf     := Buffer(44 + dataLen, 0)

    NumPut("UInt"  , 0x46464952  , buf,  0)   ; "RIFF"
    NumPut("UInt"  , 36 + dataLen, buf,  4)
    NumPut("UInt"  , 0x45564157  , buf,  8)   ; "WAVE"
    NumPut("UInt"  , 0x20746D66  , buf, 12)   ; "fmt "
    NumPut("UInt"  , 16          , buf, 16)
    NumPut("UShort", 1           , buf, 20)   ; PCM
    NumPut("UShort", 1           , buf, 22)   ; mono
    NumPut("UInt"  , rate        , buf, 24)
    NumPut("UInt"  , rate * 2    , buf, 28)
    NumPut("UShort", 2           , buf, 32)
    NumPut("UShort", 16          , buf, 34)
    NumPut("UInt"  , 0x61746164  , buf, 36)   ; "data"
    NumPut("UInt"  , dataLen     , buf, 40)

    twoPi := 6.283185307179586
    fade  := Max(1, Round(rate * 0.005))      ; 5 ms in/out kills the click
    loop samples {
        i   := A_Index - 1
        amp := vol
        if (i < fade)
            amp *= i / fade
        else if (i > samples - fade)
            amp *= (samples - i) / fade
        NumPut("Short", Round(32767 * amp * Sin(twoPi * freq * i / rate))
             , buf, 44 + i * 2)
    }
    return buf
}

PlayBuf(buf) {
    if buf
        DllCall("winmm\PlaySound", "Ptr", buf.Ptr, "Ptr", 0, "UInt", 0x0007)
}                                             ; SND_MEMORY|SND_ASYNC|SND_NODEFAULT

LoadNVDA() {
    global g_Nvda
    for name in ["nvdaControllerClient64.dll", "nvdaControllerClient.dll"] {
        if g_Nvda := DllCall("LoadLibrary", "Str", A_ScriptDir "\" name, "Ptr") {
            Log("NVDA controller client loaded: " name)
            return
        }
    }
    Log("no NVDA controller client beside the script; tones only")
}

Say(text) {
    if !SPEAK || !g_Nvda
        return
    try {
        if DllCall("nvdaControllerClient64\nvdaController_testIfRunning", "UInt")
            return                            ; non-zero = NVDA is not running
        DllCall("nvdaControllerClient64\nvdaController_speakText", "Str", text)
        DllCall("nvdaControllerClient64\nvdaController_brailleMessage", "Str", text)
    }
}


; =============================================================================
;  LOGGING
; =============================================================================

Log(msg) {
    try {
        FileAppend FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", LOG_FILE, "UTF-8"
        TrimLog()
    }
}

TrimLog() {
    static lastCheck := 0
    if (A_TickCount - lastCheck < 60000)
        return
    lastCheck := A_TickCount
    try {
        if FileGetSize(LOG_FILE) <= LOG_MAX_BYTES
            return
        lines := StrSplit(FileRead(LOG_FILE, "UTF-8"), "`n")
        start := Max(1, lines.Length - 500)
        keep  := ""
        loop lines.Length - start + 1
            keep .= lines[start + A_Index - 1] "`n"
        FileDelete LOG_FILE
        FileAppend keep, LOG_FILE, "UTF-8"
    }
}


; =============================================================================
;  STATUS
; =============================================================================

ShowStatus(*) {
    text := "ConceptSphere Watchdog"
    if g_Paused
        text .= " (PAUSED)"
    text .= "`n`n"
    for c in COMPONENTS
        text .= ComponentLine(c) "`n`n"
    text .= "Log: " LOG_FILE
    MsgBox text, "ConceptSphere Watchdog", "Iconi"
}

ComponentLine(c) {
    hwnd  := FindWindow(c.exe)
    pid   := ProcessExist(c.exe)
    if !pid
        state := "not running"
    else if !hwnd
        state := "running, no message window"
    else if RespondingExe(c.exe)
        state := "running and responding"
    else
        state := "running but NOT RESPONDING"

    line := c.name ": " state
    if (stale := StaleNote(c, pid))
        line .= "`n  " stale
    if c.quarantined
        line .= "`n  QUARANTINED - not being restarted"
    else if c.ignored
        line .= "`n  ignored"
    if c.strikeCount
        line .= "`n  misses: " c.strikeCount " of " c.strikes
    if c.history.Length {
        line .= "`n  restarts this hour: " c.history.Length
        if c.lastRestart
            line .= " (last " c.lastRestart ")"
    }
    return line
}

; The recurring trap: the exe on disk is rebuilt but the OLD process is still
; running, because #SingleInstance Force cannot replace an elevated instance from
; a normal-integrity compiler. Symptoms then come from code that no longer exists.
StaleNote(c, pid) {
    if !pid
        return ""
    path := EXE_DIR "\" c.exe
    if !FileExist(path)
        return ""
    try {
        exeTime := FileGetTime(path, "M")
        q := ComObjGet("winmgmts:").ExecQuery(
             "Select CreationDate from Win32_Process where ProcessId=" pid)
        for p in q {
            started := SubStr(p.CreationDate, 1, 14)         ; yyyyMMddHHmmss
            if (exeTime > started)
                return "STALE: the exe on disk is newer than the running process"
            return "process started " FormatTime(started, "yyyy-MM-dd HH:mm:ss")
        }
    }
    return ""
}


; =============================================================================
;  TRAY AND HOTKEYS
; =============================================================================

BuildTray() {
    A_IconTip := "ConceptSphere Watchdog"
    m := A_TrayMenu
    m.Delete()
    m.Add("&Status`tCtrl+Alt+Shift+W", ShowStatus)
    m.Add("&Pause watching`tCtrl+Alt+Shift+P", TogglePause)
    m.Add()
    for c in COMPONENTS {
        sub := Menu()
        sub.Add("&Restart now", ManualRestart.Bind(c))
        sub.Add("&Ignore this component", ToggleIgnore.Bind(c))
        m.Add(c.name, sub)
    }
    m.Add()
    m.Add("&Open log", OpenLog)
    m.Add("E&xit watchdog", ExitWatchdog)
    m.Default := "&Status`tCtrl+Alt+Shift+W"
}

; Pause before recompiling: stopping a task to build looks exactly like a crash.
TogglePause(*) {
    global g_Paused
    g_Paused := !g_Paused
    for c in COMPONENTS
        c.strikeCount := 0
    Log(g_Paused ? "watching PAUSED by user" : "watching RESUMED by user")
    if BEEP
        PlayBuf(g_Paused ? g_LowBuf : g_HighBuf)
    Say(g_Paused ? "Watchdog paused" : "Watchdog resumed")
}

ToggleIgnore(c, *) {
    c.ignored := !c.ignored
    c.strikeCount := 0
    Log(c.name . ": " . (c.ignored ? "ignored" : "watched again") . " by user")
    Say(c.name . (c.ignored ? " ignored" : " watched again"))
}

ManualRestart(c, *) {
    c.quarantined := false
    c.history := []                          ; a deliberate restart is not a symptom
    c.cooldownUntil := 0
    Log(c.name ": manual restart requested")
    Recover(c, "manual request")
}

OpenLog(*) {
    if !FileExist(LOG_FILE)
        Log("log opened")
    try Run 'notepad.exe "' LOG_FILE '"'
}

ExitWatchdog(*) {
    Log("watchdog exiting at user request")
    ExitApp
}

^!+w::ShowStatus()
^!+p::TogglePause()