; =================================================================================================
; EditorLockWatcher.ahk  (AutoHotkey v1.1)
; -------------------------------------------------------------------------------------------------
; - Watches a trigger file in C:\AtlasIdeHelper\file_to_edit.txt
; - On trigger:
;     * Creates file_to_edit.txt.lock as ACK
;     * Parses EXE= / ARGS= / BLOCKING=1
;     * Launches the requested editor
; - For BLOCKING=1:
;     * Tracks the launched PID in g_blockingPid
;     * A timer (WatchBlocking) polls that PID and deletes .lock when the editor exits
; - NO focus logic here; that is handled by EditorFocusWatcher.ahk
; =================================================================================================

#NoEnv
#NoTrayIcon
#SingleInstance, Force
#Persistent
SetBatchLines, -1
SetTitleMatchMode, 2
DetectHiddenWindows, Off

; ======================
; === Global config ====
; ======================
global g_triggerFile, g_lockFile, g_logFile
g_triggerFile := "C:\AtlasIdeHelper\file_to_edit.txt"
g_lockFile    := g_triggerFile . ".lock"
g_logFile     := "C:\AtlasIdeHelper\EditorWatcher.log"

; For BLOCKING=1 launches
global g_blockingPid
g_blockingPid := 0

; ======================
; === Init logging  ====
; ======================
FileDelete, %g_logFile%
FileAppend, Started EditorLockWatcher at %A_Now%`n, %g_logFile%
FileAppend, AHK=%A_AhkVersion% IsAdmin=%A_IsAdmin%`n, %g_logFile%

; ======================
; === Timers ===========
; ======================
SetTimer, WatchTrigger, 200
SetTimer, WatchBlocking, 500
return


; ==========================
; === Trigger watcher   ====
; ==========================
WatchTrigger:
    global g_triggerFile, g_lockFile, g_logFile
    global g_blockingPid

    if !FileExist(g_triggerFile)
        return

    FileRead, content, %g_triggerFile%
    if (content = "")
        return

    ; --- ACK: create .lock so Linux sees it ---
    FileDelete, %g_lockFile%
    FileAppend,, %g_lockFile%
    FileAppend, [%A_Now%] Trigger seen, .lock created.`n, %g_logFile%

    exe := ""
    args := ""
    blocking := false

    ; ----------------------------
    ; Parse trigger content
    ; Supports:
    ;   EXE=...
    ;   ARGS=...
    ;   BLOCKING=1 / true / yes
    ; Or a single-line "exe args" format.
    ; ----------------------------
    if InStr(content, "EXE=")
    {
        ; INI-style trigger
        Loop, Parse, content, `n, `r
        {
            line := Trim(A_LoopField)
            if (line = "")
                continue
            if (SubStr(line, 1, 1) = ";")
                continue

            if (SubStr(line, 1, 4) = "EXE=")
            {
                exe := Trim(SubStr(line, 5))
            }
            else if (SubStr(line, 1, 5) = "ARGS=")
            {
                args := SubStr(line, 6)
            }
            else if (SubStr(line, 1, 9) = "BLOCKING=")
            {
                val := Trim(SubStr(line, 10))
                StringLower, val, val
                if (val = "1" or val = "true" or val = "yes")
                    blocking := true
            }
        }
    }
    else
    {
        ; Plain one-line "exe args" trigger
        firstLine := ""
        Loop, Parse, content, `n, `r
        {
            if (Trim(A_LoopField) != "")
            {
                firstLine := Trim(A_LoopField)
                break
            }
        }
        if (firstLine != "")
        {
            pos := InStr(firstLine, " ")
            if (pos = 0)
            {
                exe := firstLine
                args := ""
            }
            else
            {
                exe  := SubStr(firstLine, 1, pos - 1)
                args := SubStr(firstLine, pos + 1)
            }
        }
    }

    if (exe = "")
    {
        FileAppend, [%A_Now%] Trigger had no EXE, ignoring.`n, %g_logFile%
        FileDelete, %g_triggerFile%
        return
    }

    cmd := exe
    if (args != "")
        cmd := cmd . " " . args

    FileAppend, [%A_Now%] Launching cmd="%cmd%" blocking=%blocking%`n, %g_logFile%

    if (blocking)
    {
        Run, %cmd%,, , newPid
        g_blockingPid := newPid
        FileAppend, [%A_Now%] Blocking editor PID=%newPid% started.`n, %g_logFile%
    }
    else
    {
        Run, %cmd%
        FileAppend, [%A_Now%] Non-blocking editor launched.`n, %g_logFile%
    }

    FileDelete, %g_triggerFile%
return


; ==========================
; === Blocking watcher  ====
; ==========================
WatchBlocking:
    global g_blockingPid, g_lockFile, g_logFile

    if (g_blockingPid = 0)
        return

    Process, Exist, %g_blockingPid%
    if (ErrorLevel = 0)  ; process not found => editor closed
    {
        FileAppend, [%A_Now%] Blocking PID %g_blockingPid% exited, deleting lock.`n, %g_logFile%
        FileDelete, %g_lockFile%
        g_blockingPid := 0
    }
return
