#NoTrayIcon
#SingleInstance, Force
SetTitleMatchMode, 2
DetectHiddenWindows, Off

; --- Config: preferred editors in order ---
targets := []
targets.Push("Administrator ahk_exe notepad++.exe") ; Notepad++ as admin
targets.Push("ahk_exe Code.exe")                     ; VS Code
targets.Push("ahk_exe EXCEL.EXE")                    ; Excel

; --- Config: SSH terminal title patterns ---
ssh_terms := ["ATLAS IDE Terminal"
, "accuser@eva-1-vm"
            , "accuser@eva-2-vm"
            , "accuser@p12583-nb-vm"
            , "ntc@ntc-s3-tn-10"
            , "ntc@ntc-s3-tn-12"
            , "jack@NTC-jack-11"]

; --- State ---
global enabled := true
global latched := false
global latched_hwnd := 0

; Start polling
SetTimer, WatchEditors, 500
return

WatchEditors:
    if (!enabled)
        return

    ; If already latched, keep hands off unless that window is gone
    if (latched) {
        if WinExist("ahk_id " . latched_hwnd)
            return
        ; Latched window no longer exists -> reset latch
        latched := false
        latched_hwnd := 0
        ; --- NEW: return focus to SSH VM terminal window ---
        FocusSSH()
    }

    ; Search for the first available target in priority order
    for index, spec in targets {
        if WinExist(spec) {
            hwnd := WinExist(spec)
            ; Activate only once per new window (the latch)
            Sleep, 300
            WinActivate, ahk_id %hwnd%
            WinWaitActive, ahk_id %hwnd%, , 1
            latched := true
            latched_hwnd := hwnd
            break
        }
    }
return

; --- Hotkeys ---
; Ctrl+Alt+R: reset latch manually (next detection will activate again once)
^!r::
    latched := false
    latched_hwnd := 0
    FocusSSH()
return

; --- Helper: focus back to SSH terminal ---
FocusSSH() {
    global ssh_terms
    for each, term in ssh_terms {
        if WinExist(term) {
            hwnd := WinExist(term)
            Sleep, 200
            WinActivate, ahk_id %hwnd%
            return
        }
    }
}
