#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; ConsoleSelectAll - Ctrl+Shift+A copies the whole console buffer.
;
; HOW EACH TERMINAL IS COPIED
;
;   Every earlier version injected Ctrl+A then Ctrl+C and hoped the console
;   handled them. Under pwsh that never works: PSReadLine binds Ctrl+A to its
;   own SelectAll (the current command line only) and CONSUMES the key, so
;   conhost's mark-mode select-all is never reached. Ctrl+C then copies
;   PSReadLine's selection, which at an empty prompt is nothing at all.
;   Windows PowerShell 5.1 hid this by disabling PSReadLine under a screen
;   reader -- which is why the same script worked there and failed here.
;
;   A classic ConsoleWindowClass buffer is read directly through the console API:
;       AttachConsole -> CONOUT$ -> ReadConsoleOutputCharacterW
;   Nothing is typed, nothing is selected, no modifier can be left down, and
;   NVDA has no selection change to announce -- so the quiet-window sentinel
;   is not needed on this path either. PSReadLine, QuickEdit and the "Enable
;   Ctrl key shortcuts" setting all stop mattering.
;
;   Windows Terminal and ATLAS IDE do not expose the classic console buffer.
;   Windows Terminal uses Ctrl+Shift+A then Ctrl+Shift+C. ATLAS v10+ owns a
;   private Ctrl+Alt+Shift+F24 chord which copies its complete transcript in
;   one operation without selecting the native text control. That prevents
;   NVDA from announcing selection and copy state as separate messages.
;
; Ctrl+Alt+Shift+A reports diagnostics, including which path would be taken
; and the buffer dimensions it can see.

global g_NvdaDll := ""              ; module name for DllCall, "" when absent
global g_StartedAt := A_Now
global g_CopyHotkeyArmed := true     ; false while one copy request is active
global g_CopyHotkeyRunning := false ; second guard for an already-queued thread

QUIET_MS   := 1200                  ; fallback path only
SELECT_GAP := 120
COPY_GAP   := 150
COPY_REARM_DELAY_MS := 100           ; minimum quiet time before accepting again
COPY_REARM_POLL_MS  := 25            ; release polling while keys remain held
MAX_CHARS  := 4000000               ; sanity cap on one buffer read

SetKeyDelay 15, 15
LoadNVDA()
WarnIfDuplicate()

; ---------------------------------------------------------------- the hotkey

#HotIf g_CopyHotkeyArmed
$^+a:: {
    global g_CopyHotkeyArmed, g_CopyHotkeyRunning

    ; Turn off this hotkey variant before doing anything which can synthesize
    ; keys.  The $ prefix rejects normal Send recursion, while this lifecycle
    ; gate also rejects held-key repeats and injected/cross-script re-entry.
    if g_CopyHotkeyRunning
        return
    g_CopyHotkeyArmed := false
    g_CopyHotkeyRunning := true

    try {
        HandleCopyHotkey()
    } finally {
        ; Rearming is asynchronous so the triggering key-up events can finish.
        ; The hotkey stays unavailable until Ctrl, Shift and A are physically
        ; released, preventing one press from starting a second request.
        ScheduleCopyHotkeyRearm()
    }
}
#HotIf

HandleCopyHotkey() {
    if !IsConsole() {
        Send "{Blind}a"             ; pass through, strands no modifier
        return
    }

    if IsLegacyConsole() {
        text := ReadConsoleBuffer()
        if (text != "") {
            A_Clipboard := text
            NvdaSay("select all and copied to clipboard")
        } else {
            NvdaSay("console buffer could not be read")
        }
        return
    }

    if IsAtlasIde() {
        CopyAtlasAtomic()
        return
    }

    CopyByKeystroke("windows-terminal")
}

ScheduleCopyHotkeyRearm() {
    global COPY_REARM_DELAY_MS
    SetTimer RearmCopyHotkey, -COPY_REARM_DELAY_MS
}

RearmCopyHotkey() {
    global g_CopyHotkeyArmed, g_CopyHotkeyRunning, COPY_REARM_POLL_MS

    held := GetKeyState("Control", "P")
            || GetKeyState("Shift", "P")
            || GetKeyState("a", "P")
    if held {
        SetTimer RearmCopyHotkey, -COPY_REARM_POLL_MS
        return
    }

    g_CopyHotkeyRunning := false
    g_CopyHotkeyArmed := true
}

; ------------------------------------------------------- console API path

; True for a classic conhost window, where the window's process is attached to
; the console we want. Windows Terminal is a different beast entirely.
IsLegacyConsole() {
    return WinGetClass("A") = "ConsoleWindowClass"
}

IsAtlasIde() {
    proc := ""
    title := ""
    try proc := WinGetProcessName("A")
    try title := WinGetTitle("A")
    return (proc = "pythonw.exe" || proc = "python.exe")
           && InStr(title, "ATLAS IDE")
}

IsConsole() {
    cls := WinGetClass("A")
    return (cls = "ConsoleWindowClass"
            || cls = "CASCADIA_HOSTING_WINDOW_CLASS"
            || IsAtlasIde())
}

; The console window's process is usually the shell itself (pwsh, powershell,
; cmd). When it is conhost, the shell is conhost's PARENT -- conhost is spawned
; as a child of the program it hosts.
GetConsolePid() {
    pid := 0
    try pid := WinGetPID("A")
    if !pid
        return 0
    name := ""
    try name := WinGetProcessName("A")
    if (name != "conhost.exe")
        return pid
    try {
        q := "SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" pid
        for p in ComObjGet("winmgmts:").ExecQuery(q)
            return p.ParentProcessId
    }
    return pid
}

ReadConsoleBuffer() {
    global MAX_CHARS
    static GENERIC_READ  := 0x80000000
    static GENERIC_WRITE := 0x40000000
    static SHARE_RW      := 0x3
    static OPEN_EXISTING := 3
    static INVALID       := -1

    pid := GetConsolePid()
    if !pid
        return ""

    ; We must own no console of our own before attaching to someone else's.
    DllCall("FreeConsole")
    if !DllCall("AttachConsole", "UInt", pid)
        return ""

    out := ""
    h := DllCall("CreateFileW", "Str", "CONOUT$",
                 "UInt", GENERIC_READ | GENERIC_WRITE,
                 "UInt", SHARE_RW, "Ptr", 0,
                 "UInt", OPEN_EXISTING, "UInt", 0, "Ptr", 0, "Ptr")
    if (h && h != INVALID) {
        ; CONSOLE_SCREEN_BUFFER_INFO: dwSize, dwCursorPosition, wAttributes,
        ; srWindow, dwMaximumWindowSize -- 22 bytes.
        csbi := Buffer(22, 0)
        if DllCall("GetConsoleScreenBufferInfo", "Ptr", h, "Ptr", csbi) {
            width  := NumGet(csbi, 0, "Short")
            curY   := NumGet(csbi, 6, "Short")
            rows   := curY + 1                  ; ignore the blank tail
            total  := width * rows
            if (total > 0 && total <= MAX_CHARS) {
                buf  := Buffer(total * 2, 0)
                read := 0
                ok := DllCall("ReadConsoleOutputCharacterW", "Ptr", h,
                              "Ptr", buf, "UInt", total,
                              "UInt", 0,            ; COORD {0,0}, packed
                              "UInt*", &read)
                if (ok && read) {
                    raw := StrGet(buf, read, "UTF-16")
                    ; The buffer is one flat run of fixed-width rows, so it is
                    ; sliced back into lines and the padding spaces dropped.
                    lines := []
                    y := 0
                    while (y < rows) {
                        lines.Push(RTrim(SubStr(raw, y * width + 1, width), " `t"))
                        y++
                    }
                    while (lines.Length && lines[lines.Length] = "")
                        lines.Pop()
                    for line in lines
                        out .= line "`r`n"
                }
            }
        }
        DllCall("CloseHandle", "Ptr", h)
    }
    DllCall("FreeConsole")
    return out
}

; --------------------------------------------------- keystroke fallback

CopyAtlasAtomic() {
    WaitForRelease(1000)

    saved := ""
    try saved := A_Clipboard
    A_Clipboard := ""

    NvdaCancel()
    SendEvent "{a up}{Shift up}{Ctrl up}{Alt up}"
    Sleep 20

    ; ATLAS owns all success/error speech for this atomic action. Keeping one
    ; speech owner avoids the former Select All + Copy + AHK triple chatter.
    SendEvent "{Ctrl down}{Alt down}{Shift down}{F24}{Shift up}{Alt up}{Ctrl up}"
    copied := ClipWait(1, false)

    ReleaseCtrl()
    ForceModifiersUp()
    if copied
        return true

    try A_Clipboard := saved
    return false
}

CopyByKeystroke(targetKind) {
    global QUIET_MS, SELECT_GAP, COPY_GAP

    WaitForRelease(1000)

    saved := ""
    try saved := A_Clipboard
    A_Clipboard := ""

    NvdaCancel()
    NvdaQuiet(QUIET_MS)

    ; Release the modifiers which invoked this hotkey before synthesizing
    ; Windows Terminal's select-all and copy shortcuts.
    SendEvent "{a up}{Shift up}{Ctrl up}"
    Sleep 20

    SendEvent "{Ctrl down}{Shift down}a{Shift up}{Ctrl up}"
    Sleep SELECT_GAP
    SendEvent "{Ctrl down}{Shift down}c{Shift up}{Ctrl up}"
    Sleep 20

    copied := ClipWait(1, false)
    Sleep COPY_GAP

    ReleaseCtrl()
    ForceModifiersUp()

    NvdaQuiet(0)
    if copied {
        NvdaSay("select all and copied to clipboard")
        return true
    }

    try A_Clipboard := saved
    SendEvent "{Escape}"
    NvdaSay("select all failed, nothing copied")
    return false
}

; ------------------------------------------------------------- diagnostics

^!+a:: {
    global g_StartedAt, g_CopyHotkeyArmed, g_CopyHotkeyRunning
    cls := "", pid := 0, proc := ""
    try cls := WinGetClass("A")
    try pid := WinGetPID("A")
    try proc := WinGetProcessName("A")

    exeCount := CountProcess("ConsoleSelectAll.exe")
    srcCount := CountScriptInstances("ConsoleSelectAll.ahk")

    stale := "n/a"
    if A_IsCompiled {
        mtime := FileGetTime(A_ScriptFullPath, "M")
        stale := (DateDiff(mtime, g_StartedAt, "Seconds") > 0)
            ? "STALE - exe on disk is newer than this process"
            : "current"
    }

    path := IsLegacyConsole() ? "console API (direct buffer read)"
          : IsAtlasIde()      ? "atomic transcript copy (ATLAS IDE terminal)"
          : IsConsole()       ? "Ctrl+Shift+A/C fallback (Windows Terminal)"
          : "pass through - not a supported terminal"

    probe := "not attempted"
    if IsLegacyConsole() {
        t := ReadConsoleBuffer()
        probe := t = "" ? "FAILED - could not read the buffer"
                        : StrLen(t) " characters readable"
    }

    clipLen := 0
    try clipLen := StrLen(A_Clipboard)

    MsgBox "ConsoleSelectAll diagnostics`n`n"
         . "This process: " (A_IsCompiled ? "compiled exe" : "ahk source") "`n"
         . "Path: " A_ScriptFullPath "`n"
         . "Started: " g_StartedAt "`n"
         . "Build: " stale "`n`n"
         . "ConsoleSelectAll.exe processes: " exeCount "`n"
         . "AutoHotkey processes running ConsoleSelectAll.ahk: " srcCount "`n"
         . "Copy gate: " (g_CopyHotkeyArmed ? "armed" : "disarmed")
         . ", " (g_CopyHotkeyRunning ? "running" : "idle") "`n"
         . ((exeCount + srcCount) > 1
             ? ">>> MORE THAN ONE INSTANCE OWNS Ctrl+Shift+A <<<`n`n" : "`n")
         . "Active window class: " cls "`n"
         . "Active window process: " proc " (pid " pid ")`n"
         . "Console process resolved: " GetConsolePid() "`n"
         . "Method: " path "`n"
         . "Buffer probe: " probe "`n`n"
         . "NVDA client: " (g_NvdaDll ? g_NvdaDll : "not loaded") "`n"
         . "NVDA running: " (NvdaRunning() ? "yes" : "no") "`n"
         . "Clipboard length: " clipLen,
           "ConsoleSelectAll", "Iconi"
}

; ------------------------------------------------------------------ helpers

WaitForRelease(timeout, triggerKey := "a") {
    end := A_TickCount + timeout
    while (A_TickCount < end) {
        held := GetKeyState("Control", "P")
                || GetKeyState("Shift", "P")
                || (triggerKey != "" && GetKeyState(triggerKey, "P"))
        if !held
            return true
        Sleep 10
    }
    return false
}

; Release Ctrl unconditionally -- no GetKeyState test. That reports AHK's own
; idea of the logical state, and the failure mode is AHK's idea being wrong.
; A key-up on an already-released key is harmless.
ReleaseCtrl() {
    static KEYEVENTF_KEYUP := 0x0002
    for vk in [0xA2, 0xA3, 0x11] {
        DllCall("keybd_event", "UChar", vk, "UChar", 0,
                "UInt", KEYEVENTF_KEYUP, "UPtr", 0)
    }
}

; Alt and Win keep the test: a stray Alt-up activates the menu bar and a stray
; Win-up opens the Start menu.
ForceModifiersUp() {
    static KEYEVENTF_KEYUP := 0x0002
    static vks := Map("LShift", 0xA0, "RShift", 0xA1,
                      "LAlt",   0xA4, "RAlt",   0xA5,
                      "LWin",   0x5B, "RWin",   0x5C)
    for name, vk in vks {
        if (GetKeyState(name) && !GetKeyState(name, "P"))
            DllCall("keybd_event", "UChar", vk, "UChar", 0,
                    "UInt", KEYEVENTF_KEYUP, "UPtr", 0)
    }
}

CountProcess(exeName) {
    n := 0
    try {
        q := "SELECT ProcessId FROM Win32_Process WHERE Name='" exeName "'"
        for p in ComObjGet("winmgmts:").ExecQuery(q)
            n++
    }
    return n
}

CountScriptInstances(scriptName) {
    n := 0
    try {
        q := "SELECT CommandLine FROM Win32_Process WHERE Name LIKE 'AutoHotkey%'"
        for p in ComObjGet("winmgmts:").ExecQuery(q) {
            cl := p.CommandLine
            if (cl && InStr(cl, scriptName))
                n++
        }
    }
    return n
}

WarnIfDuplicate() {
    total := CountProcess("ConsoleSelectAll.exe")
             + CountScriptInstances("ConsoleSelectAll.ahk")
    if (total <= 1)
        return
    Loop 3 {
        SoundBeep 400, 120
        Sleep 60
    }
    MsgBox "More than one copy of ConsoleSelectAll is running (" total ").`n`n"
         . "Both own Ctrl+Shift+A. Stop the other one -- "
         . "most likely the "
         . "elevated ConsoleSelectAll.exe started by the logon scheduled task.",
           "ConsoleSelectAll", "Icon!"
}

; ---------------------------------------------------------------- NVDA glue

LoadNVDA() {
    global g_NvdaDll
    for name in ["nvdaControllerClient64.dll", "nvdaControllerClient.dll"] {
        if DllCall("LoadLibrary", "Str", A_ScriptDir "\" name, "Ptr") {
            g_NvdaDll := SubStr(name, 1, -4)
            return
        }
    }
}

NvdaRunning() {
    return g_NvdaDll
        && DllCall(g_NvdaDll "\nvdaController_testIfRunning", "UInt") = 0
}

NvdaCancel() {
    if g_NvdaDll
        DllCall(g_NvdaDll "\nvdaController_cancelSpeech")
}

NvdaQuiet(ms) {
    if g_NvdaDll
        DllCall(g_NvdaDll "\nvdaController_speakText",
                "Str", Chr(1) "MTQUIET:" ms Chr(1))
}

NvdaSay(text) {
    if !NvdaRunning() {
        SoundBeep 900, 100
        return
    }
    DllCall(g_NvdaDll "\nvdaController_speakText", "Str", text)
    DllCall(g_NvdaDll "\nvdaController_brailleMessage", "Str", text)
}
