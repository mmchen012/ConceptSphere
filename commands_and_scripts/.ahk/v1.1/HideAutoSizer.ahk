; HideAutoSizer.ahk  (AutoHotkey v1.1)
; After logon, if the *active* window title is exactly "AutoSizer",
; send Alt+F4 once, then exit.

#NoEnv
#SingleInstance Force
#Persistent
SetBatchLines, -1
DetectHiddenWindows, On
SetTitleMatchMode, 3  ; exact title match

targetTitle := "AutoSizer"

pollMs   := 30        ; fast polling
timeoutMs := 120000   ; give up after 2 minutes

startTick := A_TickCount
closedOnce := false

SetTimer, WatchOnce, %pollMs%
return

WatchOnce:
    if (closedOnce) {
        ExitApp
        return
    }

    ; Timeout
    if ((A_TickCount - startTick) > timeoutMs) {
        ExitApp
        return
    }

    ; Read active window title
    WinGet, aHwnd, ID, A
    if (!aHwnd)
        return

    WinGetTitle, aTitle, ahk_id %aHwnd%
    if (aTitle = "")
        return

    ; Only close if EXACT title matches
    if (aTitle = targetTitle) {
        ; Send Alt+F4 to the active window
        Send, !{F4}

        closedOnce := true

        ; Optional: shove focus somewhere safe so Tab doesn't keep going to a ghost owner
        if WinExist("ahk_class Shell_TrayWnd")
            WinActivate, ahk_class Shell_TrayWnd

        ; Exit shortly after
        SetTimer, WatchOnce, Off
        SetTimer, ExitSoon, -300
    }
return

ExitSoon:
    ExitApp
return
