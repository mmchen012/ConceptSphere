#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; ConsoleSelectAll - Ctrl+Shift+A copies the whole console buffer.
; Ctrl+Shift+V then opens Notepad++ and pastes that captured text.
;
; WHY THIS VERSION SENDS NO KEYSTROKES AT ALL
;
;   Every earlier version injected Ctrl+A then Ctrl+C and hoped the console
;   handled them. Under pwsh that never works: PSReadLine binds Ctrl+A to its
;   own SelectAll (the current command line only) and CONSUMES the key, so
;   conhost's mark-mode select-all is never reached. Ctrl+C then copies
;   PSReadLine's selection, which at an empty prompt is nothing at all.
;   Windows PowerShell 5.1 hid this by disabling PSReadLine under a screen
;   reader -- which is why the same script worked there and failed here.
;
;   So the buffer is now read directly through the console API:
;       AttachConsole -> CONOUT$ -> ReadConsoleOutputCharacterW
;   Nothing is typed, nothing is selected, no modifier can be left down, and
;   NVDA has no selection change to announce -- so the quiet-window sentinel
;   is not needed on this path either. PSReadLine, QuickEdit and the "Enable
;   Ctrl key shortcuts" setting all stop mattering.
;
;   Windows Terminal keeps the old keystroke path as a fallback: its window
;   belongs to WindowsTerminal.exe and gives no route to the shell's console,
;   so the API cannot be used there.
;
; Ctrl+Alt+Shift+A reports diagnostics, including which path would be taken
; and the buffer dimensions it can see.

global g_NvdaDll := ""              ; module name for DllCall, "" when absent
global g_StartedAt := A_Now
global g_LastConsoleText := ""       ; armed only after Ctrl+Shift+A succeeds

QUIET_MS   := 1200                  ; fallback path only
SELECT_GAP := 120
COPY_GAP   := 150
MAX_CHARS  := 4000000               ; sanity cap on one buffer read

SetKeyDelay 15, 15
LoadNVDA()
WarnIfDuplicate()

; ---------------------------------------------------------------- the hotkey

^+a:: {
    global g_LastConsoleText

    g_LastConsoleText := ""
    if !IsConsole() {
        Send "{Blind}a"             ; pass through, strands no modifier
        return
    }

    if IsLegacyConsole() {
        text := ReadConsoleBuffer()
        if (text != "") {
            A_Clipboard := text
            g_LastConsoleText := text
            NvdaSay("select all and copied to clipboard")
        } else {
            NvdaSay("console buffer could not be read")
        }
        return
    }

    if CopyByKeystroke()            ; Windows Terminal
        try g_LastConsoleText := A_Clipboard
}

; After Ctrl+Shift+A has successfully copied console text, Ctrl+Shift+V opens
; a fresh Notepad++ instance and pastes that exact text. If the clipboard has
; changed, or Ctrl+Shift+A was not the source of the clipboard text, the key is
; passed through normally so existing Ctrl+Shift+V shortcuts keep working.
^+v:: {
    global g_LastConsoleText

    if (g_LastConsoleText = "") {
        Send "{Blind}v"
        return
    }

    clipboardText := ""
    try clipboardText := A_Clipboard
    if (clipboardText != g_LastConsoleText) {
        g_LastConsoleText := ""
        Send "{Blind}v"
        return
    }

    if OpenInNotepadPlusPlus(g_LastConsoleText)
        g_LastConsoleText := ""
}

; ------------------------------------------------------- console API path

; True for a classic conhost window, where the window's process is attached to
; the console we want. Windows Terminal is a different beast entirely.
IsLegacyConsole() {
    return WinGetClass("A") = "ConsoleWindowClass"
}

IsConsole() {
    cls := WinGetClass("A")
    return (cls = "ConsoleWindowClass" || cls = "CASCADIA_HOSTING_WINDOW_CLASS")
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

CopyByKeystroke() {
    global QUIET_MS, SELECT_GAP, COPY_GAP

    WaitForRelease(1000)

    saved := ""
    try saved := A_Clipboard
    A_Clipboard := ""

    NvdaCancel()
    NvdaQuiet(QUIET_MS)

    SendEvent "{Ctrl down}"
    Sleep 20
    SendEvent "a"
    Sleep SELECT_GAP
    SendEvent "c"
    Sleep 20
    SendEvent "{Ctrl up}"

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

; ------------------------------------------------------ Notepad++ paste path

OpenInNotepadPlusPlus(text) {
    exe := FindNotepadPlusPlus()
    if (exe = "") {
        NvdaSay("Notepad plus plus could not be found")
        MsgBox "Notepad++ could not be found.`n`nInstall Notepad++ in a standard "
             . "location, or add notepad++.exe to the Windows App Paths "
             . "registry key.",
               "ConsoleSelectAll", "Icon!"
        return false
    }

    ; Do not let the still-held Shift key turn the paste into Ctrl+Shift+V.
    if !WaitForRelease(2000, "v") {
        NvdaSay("release control shift and v, then try again")
        return false
    }

    A_Clipboard := text
    if !ClipWait(1, false) {
        NvdaSay("clipboard could not be prepared")
        return false
    }

    pid := 0
    command := Chr(34) exe Chr(34) " -multiInst -nosession"
    try Run command, , , &pid
    catch as err {
        NvdaSay("Notepad plus plus could not be opened")
        MsgBox "Notepad++ could not be opened.`n`n" err.Message,
               "ConsoleSelectAll", "Icon!"
        return false
    }

    target := "ahk_pid " pid
    if !WinWait(target, , 5) {
        NvdaSay("Notepad plus plus did not open")
        return false
    }

    WinActivate target
    if !WinWaitActive(target, , 5) {
        NvdaSay("Notepad plus plus could not be activated")
        return false
    }

    ; The first Scintilla control is the primary Notepad++ editing pane.
    try ControlFocus "Scintilla1", target
    Sleep 120
    SendEvent "^v"
    NvdaSay("opened Notepad plus plus and pasted console content")
    return true
}

FindNotepadPlusPlus() {
    registryKeys := [
        "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\notepad++.exe",
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\notepad++.exe",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\notepad++.exe"
    ]

    for key in registryKeys {
        try {
            exe := RegRead(key)
            if (exe != "" && FileExist(exe))
                return exe
        }
    }

    candidates := [
        A_ProgramFiles "\Notepad++\notepad++.exe",
        EnvGet("ProgramFiles(x86)") "\Notepad++\notepad++.exe",
        EnvGet("LOCALAPPDATA") "\Programs\Notepad++\notepad++.exe"
    ]

    for exe in candidates {
        if (exe != "" && FileExist(exe))
            return exe
    }
    return ""
}

; ------------------------------------------------------------- diagnostics

^!+a:: {
    global g_StartedAt
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
          : IsConsole()       ? "keystroke fallback (Windows Terminal)"
          : "pass through - not a console"

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
         . "Both own Ctrl+Shift+A and Ctrl+Shift+V. Stop the other one -- "
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