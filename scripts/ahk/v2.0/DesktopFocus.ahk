#Requires AutoHotkey v2.0
#NoTrayIcon

OpenFocused("shell:Desktop")

OpenFocused(target) {
    before := Map()
    for h in WinGetList("ahk_class CabinetWClass")
        before[h] := true

    Run 'explorer.exe "' target '"'

    hwnd := 0
    deadline := A_TickCount + 5000
    while (A_TickCount < deadline) && !hwnd {
        for h in WinGetList("ahk_class CabinetWClass")
            if !before.Has(h) {
                hwnd := h
                break
            }
        Sleep 30
    }
    if !hwnd
        return 0

    WinActivate hwnd
    WinWaitActive hwnd, , 2
    FocusList(hwnd)
    return hwnd
}

FocusList(hwnd) {
    ; Preferred: select+focus the first item via the shell view itself.
    loop 60 {
        try {
            for w in ComObject("Shell.Application").Windows() {
                if (w.HWND != hwnd)
                    continue
                doc := w.Document
                if (doc.Folder.Items.Count > 0) {
                    ; SVSI_SELECT|SVSI_DESELECTOTHERS|SVSI_ENSUREVISIBLE|SVSI_FOCUSED
                    doc.SelectItem(doc.Folder.Items.Item(0), 0x1|0x4|0x8|0x10)
                    return true
                }
            }
        }
        Sleep 50
    }
    ; Fallback: focus the list control directly.
    try {
        ControlFocus "SysListView321", hwnd
        return true
    }
    return false
}