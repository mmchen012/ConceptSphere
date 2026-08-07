; =================================================================================================
; EditorFocusWatcher.ahk  (AutoHotkey v.1.1)
; -------------------------------------------------------------------------------------------------
; - Runs independently of EditorLockWatcher.
; - Watches for editor windows becoming active.
; - Remembers which window was active *before* the editor (ideally ATLAS IDE Terminal).
; - When that editor process exits, re-activates the remembered window and sends a wake key.
;
; This is generic: it doesn't know about .lock or triggers at all.
; =================================================================================================

#NoEnv
#NoTrayIcon
#SingleInstance, Force
#Persistent
SetBatchLines, -1
SetTitleMatchMode, 2
DetectHiddenWindows, Off

; ======================
; === Config ===========
; ======================

; Title substring of your terminal window (used only for sanity/logging, not required for logic)
global g_terminalTitle
g_terminalTitle := "ATLAS IDE Terminal"

; Comma-delimited list of editor EXE names to watch
; Add/remove as needed
global g_editorExeList
g_editorExeList := ",notepad++.exe,Code.exe,code.exe,excel.exe,EXCEL.EXE,notepad.exe,"

; Delay (in ms) to give NVDA time to detect focus and announce the window title
; You can tweak this (e.g. 300, 500, 800) if NVDA is still too quiet.
global g_focusDelayMs
g_focusDelayMs := 350

; State tracking
global g_prevActiveHwnd
global g_prevActiveTitle
global g_prevActiveExe

global g_currentEditorPid
global g_currentEditorExe
global g_lastNonEditorHwnd
global g_waitingForClose

g_prevActiveHwnd   := 0
g_prevActiveTitle  := ""
g_prevActiveExe    := ""

g_currentEditorPid := 0
g_currentEditorExe := ""
g_lastNonEditorHwnd:= 0
g_waitingForClose  := 0

; Log file (separate from lock watcher if you like)
global g_focusLog
g_focusLog := "C:\AtlasIdeHelper\EditorFocusWatcher.log"

FileDelete, %g_focusLog%
FileAppend, Started EditorFocusWatcher at %A_Now%`n, %g_focusLog%
FileAppend, AHK=%A_AhkVersion% IsAdmin=%A_IsAdmin%`n, %g_focusLog%

; ======================
; === Timers ===========
; ======================
SetTimer, CheckActiveWindow, 200
SetTimer, WatchEditorClose, 500

; Optional hotkey to refocus last non-editor window (Ctrl+Alt+Y)
^!y::
    if (g_lastNonEditorHwnd)
    {
        FileAppend, [%A_Now%] Hotkey ^!y -> focusing lastNonEditorHwnd`n, %g_focusLog%
        FocusWindowByHwnd(g_lastNonEditorHwnd)
    }
return

return


; ==============================
; === Helper: is editor?   ====
; ==============================
IsEditorExe(exe)
{
    global g_editorExeList
    ; Wrap with commas to avoid partial matches
    list := g_editorExeList
    exeWithCommas := "," . exe . ","
    if InStr(list, exeWithCommas)
        return 1
    return 0
}

; ==============================
; === Helper: focus hwnd   ====
; ==============================
FocusWindowByHwnd(hWnd)
{
    global g_focusLog, g_focusDelayMs

    if (!hWnd)
        return

    ; Activate this window
    WinActivate, ahk_id %hWnd%
    if (ErrorLevel)
    {
        FileAppend, [%A_Now%] FocusWindowByHwnd: WinActivate failed for hwnd=%hWnd%`n, %g_focusLog%
        return
    }

    ; Wait until it is the active window
    WinWaitActive, ahk_id %hWnd%,, 0.7

    ; Extra delay so NVDA has time to see the focus change and speak the title
    Sleep, %g_focusDelayMs%

    ; Wake key
    SendInput {vk07}
    FileAppend, [%A_Now%] FocusWindowByHwnd: sent vk07 to hwnd=%hWnd% after %g_focusDelayMs%ms delay`n, %g_focusLog%
}


; =================================
; === Timer: track active window ==
; =================================
CheckActiveWindow:
    global g_prevActiveHwnd, g_prevActiveTitle, g_prevActiveExe
    global g_currentEditorPid, g_currentEditorExe
    global g_lastNonEditorHwnd, g_waitingForClose
    global g_focusLog

    ; Get current active window
    WinGet, curHwnd, ID, A
    if (!curHwnd)
        return

    WinGetTitle, curTitle, ahk_id %curHwnd%
    WinGet, curExe, ProcessName, ahk_id %curHwnd%
    WinGet, curPid, PID, ahk_id %curHwnd%

    ; If this is the same hwnd as last time, nothing to do except update prev
    if (curHwnd = g_prevActiveHwnd)
    {
        g_prevActiveTitle := curTitle
        g_prevActiveExe   := curExe
        return
    }

    ; Window changed
    ; Was this *new* active window one of the editor EXEs?
    if IsEditorExe(curExe)
    {
        ; Only record new editor if we're not already tracking one
        if (g_currentEditorPid = 0)
        {
            g_currentEditorPid := curPid
            g_currentEditorExe := curExe
            g_lastNonEditorHwnd:= g_prevActiveHwnd
            g_waitingForClose  := 1

            FileAppend, [%A_Now%] New editor active: exe=%curExe% pid=%curPid% prevHwnd=%g_prevActiveHwnd%`n, %g_focusLog%
        }
    }

    ; Update previous active window info
    g_prevActiveHwnd  := curHwnd
    g_prevActiveTitle := curTitle
    g_prevActiveExe   := curExe
return


; =================================
; === Timer: watch editor close ===
; =================================
WatchEditorClose:
    global g_currentEditorPid, g_currentEditorExe
    global g_lastNonEditorHwnd, g_waitingForClose
    global g_focusLog

    if (!g_waitingForClose or g_currentEditorPid = 0)
        return

    Process, Exist, %g_currentEditorPid%
    if (ErrorLevel != 0)
        return  ; editor still running

    ; Editor has closed
    FileAppend, [%A_Now%] Editor pid=%g_currentEditorPid% exe=%g_currentEditorExe% closed.`n, %g_focusLog%

    pid := g_currentEditorPid
    exe := g_currentEditorExe
    hLast := g_lastNonEditorHwnd

    ; Reset tracking
    g_currentEditorPid := 0
    g_currentEditorExe := ""
    g_waitingForClose  := 0
    g_lastNonEditorHwnd:= 0

    ; If we have a previous non-editor window, focus it
    if (hLast)
    {
        FileAppend, [%A_Now%] Focusing last non-editor hwnd=%hLast% after editor close.`n, %g_focusLog%
        FocusWindowByHwnd(hLast)
    }
return
