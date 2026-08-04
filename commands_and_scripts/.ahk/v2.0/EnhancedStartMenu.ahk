#Requires AutoHotkey v2.0
#SingleInstance Force
#include <UIA>          ; resolves to Lib\UIA.ahk next to this script
                        ; (compiled into the exe -- NOT needed at run time)

; --- stability ---------------------------------------------------------------
; These hotkeys CONSUME keys before the Start menu sees them, so anything that
; stops a handler finishing makes Start go deaf to every key we claim. Two
; defences here, plus a stale-flag recovery in TypeAheadKey/ListArrow and the
; global escape hotkeys at the bottom of the registration block.

; Without this, AHK pops a modal "hotkey pressed too fast" dialog after 70
; hotkeys in 2 seconds -- easy to hit typing quickly, and the dialog itself
; swallows every subsequent key. (These were #directives in v1; in v2 they are
; settable built-in variables.)
A_MaxHotkeysPerInterval := 500
A_HotkeyInterval := 1000

; An uncaught error would otherwise show a modal dialog (same problem) or kill
; the script outright. Log it, clear the busy flag, and carry on.
OnError(HandleError)

CT_EDIT := 50004        ; UIA control type: Edit (the search box)
CT_LIST := 50008        ; UIA control type: List
CT_MENU := 50009        ; UIA control type: Menu (a context menu)
CT_MENUITEM := 50011    ; UIA control type: MenuItem
CT_LISTITEM := 50007    ; UIA control type: ListItem (an app row)

TA_TIMEOUT := 900       ; ms gap that starts a fresh search
taBuffer := ""
taLast := 0
taIndex := 0
taBusy := false         ; true while a type-ahead is running (see TypeAheadKey)
taBusyAt := 0           ; when it was set, so a stuck flag can be recovered
listMode := false       ; true once we've jumped into the list -> type-ahead ignores
                        ; a stale "search box focused" UIA reading. Cleared when
                        ; Escape closes Start (next open starts in search mode).

; Where a context menu was opened from, so focus can be put back there after
; pinning (Start otherwise throws focus onto the new tile in the pinned grid).
menuAnchorName := ""
menuAnchorInFolder := false

; Soft sine beep (built once, in memory) used for no-match / no-toggle cues.
BEEP_HZ  := 400
BEEP_MS  := 40
BEEP_VOL := 0.45
BeepBuf := MakeBeepWav(BEEP_HZ, BEEP_MS, BEEP_VOL)
; Higher, longer tone for the escape hotkeys. SoundBeep is unreliable on this
; machine, so the escapes use the same generated-WAV path as the no-match cue.
HighBuf := MakeBeepWav(900, 90, BEEP_VOL)
; --- diagnostic log (delete these lines once the timing issue is settled) ---
; Handlers append here. A keypress that produces NO line means the hotkey never
; fired -- i.e. the script wasn't running, or its window context didn't match --
; which no logic inside the handlers could fix.
LogPath := A_Temp "\EnhancedStartMenu.log"
LogCount := 0
LOG_MAX := 300
try FileDelete(LogPath)

; Hotkey contexts. Measured with StartWatch: pressing Win opens Start with the
; SEARCH BOX focused, and Windows reports SearchHost.exe as the foreground window
; until Down moves focus into the pinned grid -- only then does it become
; StartMenuExperienceHost.exe. Keys pressed during that window were invisible to
; this script (no hotkey fired, no log line, the key went to Windows and the
; letter landed in search). So the same hotkeys are registered for BOTH
; processes. This is ADDITIVE: the original criterion below is unchanged, so if
; the SearchHost one never matches, nothing is lost.
; (A HotIf(callback) version was tried instead and broke every hotkey -- keep
; the plain WinActive form.)
HotIfWinActive("ahk_exe StartMenuExperienceHost.exe")
RegisterStartHotkeys(true)

HotIfWinActive("ahk_exe SearchHost.exe")
RegisterStartHotkeys(false)             ; false = leave Escape native here, so it
                                        ; still clears a typed search query
HotIf()

; --- global escapes (work anywhere, not just in Start) -----------------------
; If the script ever wedges and Start stops responding to keys, Ctrl+Alt+Shift+S
; suspends every hotkey so Start behaves natively again; press it again to
; resume. Ctrl+Alt+Shift+R reloads the script outright.
; The global escapes are defined in script text further down, with the
; #SuspendExempt directive -- see the end of this file.

; Warm up UI Automation at startup. The first UIA call in a process pays a
; one-time COM-initialization cost; doing it here (well before Start is ever
; opened) moves that cost off the first real interaction, so the first
; type-ahead after boot is as reliable as the second. Retry briefly in case the
; framework isn't ready the instant the script launches.
Log("script start (hotkeys registered)")
WarmUpUIA()
Log("warm-up done - script ready")


; ============================ functions ============================

CloseStart(*) {
    global listMode, menuAnchorName
    focused := 0
    try focused := UIA.GetFocusedElement()
    ; A context menu is open, or we're inside an expanded folder modal -> send a
    ; native Escape to close just that and drop focus back onto the item, rather
    ; than closing Start.
    if InContextMenu(focused) || InListById(focused, ["StartFolderModal"]) {
        Send("{Escape}")
        return
    }
    listMode := false                     ; closing Start -> search mode next open
    menuAnchorName := ""
    Send("{LWin}")
}

; True if focus is on a context menu (a menu item, or inside a Menu flyout).
InContextMenu(el) {
    global CT_MENU, CT_MENUITEM
    if !IsObject(el)
        return false
    if (ElemType(el) = CT_MENUITEM)
        return true
    cur := el
    Loop 15 {
        if !IsObject(cur)
            return false
        t := ElemType(cur)
        if (t = CT_MENU || t = CT_MENUITEM)
            return true
        p := 0
        try p := cur.Parent
        cur := p
    }
    return false
}

TabJump(*) {
    global listMode, CT_EDIT
    focused := SafeFocus()
    Log("TabJump: " ActiveWinInfo() " " DescribeFocus(focused) " listMode=" (listMode ? 1 : 0))

    ; From either toggle, Tab lands on a whole region rather than the next stop
    ; in the tab chain: Tab into the pinned grid, Shift+Tab into the app list.
    if IsPinnedToggle(focused) || IsViewToggle(focused) {
        if FocusFirstPinned()
            return
        Send("{Tab}")
        return
    }

    ; Never jump: inside a context menu / expanded folder / the account-power
    ; strip (UserControl), or already on an app row (tab out).
    if InContextMenu(focused) || InListById(focused, ["StartFolderModal", "UserControl"]) {
        Send("{Tab}")
        return
    }
    if IsAppEntry(focused) {
        listMode := true                  ; we ARE in the list -> letters are type-ahead
        Send("{Tab}")                     ; already in the list -> tab out
        return
    }

    ; Jump from the places that should jump: search box, pinned, recommended.
    jump := (ElemType(focused) = CT_EDIT)
          || InListById(focused, ["PinnedList", "RecommendedList"])

    ; Safety net for the boot-time case where focus can't be read AT ALL. It must
    ; not fire on a perfectly readable element that simply isn't one of our
    ; regions -- that was pulling Tab out of the account flyout ("Manage my
    ; account" / "Sign out", which are a Hyperlink and a Button, not under
    ; UserControl) and into the app list whenever listMode happened to be off.
    if (!jump && !listMode && !IsObject(focused)) {
        Log("TabJump: focus unreadable -> defaulting to the app list")
        jump := true
    }

    if !jump {
        Send("{Tab}")
        return
    }

    listMode := true
    ; Put focus straight on the first app row by finding it in the UI -- this is
    ; independent of the tab chain, so pinned rows and the overflow toggle can't
    ; make it land short or overshoot. Tab is only a fallback.
    if FocusFirstApp()
        return
    Send("{Tab}")                         ; fallback: one native Tab (no runaway walk)
}

; Shift+Tab mirror of TabJump: from an app row, jump straight back to the first
; pinned tile (skipping the view toggle / overflow button). Otherwise native.
ShiftTabJump(*) {
    global listMode
    focused := SafeFocus()

    ; From either toggle, Shift+Tab goes into the app list (Tab goes to pinned).
    if IsPinnedToggle(focused) || IsViewToggle(focused) {
        listMode := true
        if FocusFirstApp()
            return
        Send("+{Tab}")
        return
    }

    if IsAppEntry(focused) {
        if FocusFirstPinned()
            return
    }
    Send("+{Tab}")                        ; native Shift+Tab elsewhere
}

; The "Show all/less pinned apps" overflow toggle (its name contains "pinned
; apps"); only present when more than 12 apps are pinned.
IsPinnedToggle(f) {
    if !IsObject(f)
        return false
    nm := ""
    try nm := f.Name
    return InStr(StrLower(nm), "pinned apps") ? true : false
}

; The list / grid / category view toggle.
IsViewToggle(f) {
    if !IsObject(f)
        return false
    aid := ""
    try aid := f.AutomationId
    return (aid = "ViewSelectionButton")
}

; Put focus on the first pinned tile. Returns true only if focus landed there.
FocusFirstPinned() {
    plist := GetListById("PinnedList")
    if !IsObject(plist)
        return false
    items := 0
    try items := plist.FindElements({Type:"ListItem"})
    if (!IsObject(items) || !items.Length)
        return false
    try items[1].ScrollIntoView()
    try items[1].SetFocus()
    Sleep(40)
    return InListById(SafeFocus(), ["PinnedList"])
}

; Registers the Start-menu hotkeys under whichever HotIf criterion is current.
; withEscape: Escape is only claimed in the Start window, not in the search box.
RegisterStartHotkeys(withEscape) {
    if withEscape
        Hotkey("$Escape", CloseStart)
    Hotkey("$Tab",    TabJump)
    Hotkey("$+Tab",   ShiftTabJump)      ; Shift+Tab: mirror the forward jump
    Hotkey("$^Tab",   FocusPinnedToggle) ; Ctrl+Tab: focus the pinned-overflow toggle
    Hotkey("$^+Tab",  FocusViewToggle)   ; Ctrl+Shift+Tab: focus the list/grid/category toggle
    ; Remember which row a context menu is opened from, and restore focus to it
    ; after "Pin to Start" (which otherwise dumps you in the pinned grid).
    Hotkey("$AppsKey", ContextMenuKey.Bind("{AppsKey}"))
    Hotkey("$+F10",    ContextMenuKey.Bind("+{F10}"))
    Hotkey("$Enter",   EnterKey)
    Hotkey("$^d",     DumpAppsList)      ; Ctrl+D: diagnostic (remove later)
    ; Up/Down inside the app list. Our SetFocus moves focus to a row, but the
    ; list's own "current item" doesn't follow, so a NATIVE arrow key moves
    ; relative to where Start still thinks you are -- back at the search box.
    ; Taking these over keeps list navigation consistent; everywhere else in
    ; Start they stay native (see ListArrow).
    Hotkey("$Down",   ListArrow.Bind(1))
    Hotkey("$Up",     ListArrow.Bind(-1))
    for ch in StrSplit("abcdefghijklmnopqrstuvwxyz0123456789")
        Hotkey("$" ch, TypeAheadKey.Bind(ch))

    ; Special characters, so type-ahead also matches items whose names start with
    ; a symbol. Map key = hotkey (base key, or Shift+key); value = the character
    ; it produces. Wrapped in try so an odd layout can't abort startup.
    specials := Map(
        "-", "-",   "=", "=",   "[", "[",   "]", "]",   '\', '\',
        ";", ";",   "'", "'",   ",", ",",   ".", ".",   "/", "/",
        "+-", "_",  "+=", "+",  "+[", "{",  "+]", "}",  '+\', "|",
        "+;", ":",  "+'", '"',  "+,", "<",  "+.", ">",  "+/", "?",
        "+1", "!",  "+2", "@",  "+3", "#",  "+4", "$",  "+5", "%",
        "+6", "^",  "+7", "&",  "+8", "*",  "+9", "(",  "+0", ")"
    )
    for spec, char in specials
        try Hotkey("$" spec, TypeAheadKey.Bind(char))
}

SafeFocus() {
    f := 0
    try f := UIA.GetFocusedElement()
    return f
}

; One-time UIA framework warm-up (COM init + a real query), retried briefly so a
; cold start right after boot still lands before the user's first interaction.
WarmUpUIA() {
    Loop 10 {
        ok := false
        try {
            root := UIA.ElementFromHandle(WinExist("ahk_class Shell_TrayWnd"))
            if IsObject(root)
                ok := true
        }
        try {
            if UIA.GetFocusedElement()
                ok := true
        }
        if ok
            return
        Sleep(200)
    }
}

; A real app-list row: a ListItem under AppsList that is NOT in the pinned or
; recommended grids and is not the view-selection toggle.
IsAppEntry(f) {
    global CT_LISTITEM
    if !IsObject(f)
        return false
    if !InListById(f, ["AppsList"])
        return false
    if InListById(f, ["PinnedList", "RecommendedList"])
        return false
    aid := ""
    try aid := f.AutomationId
    if (aid = "ViewSelectionButton")
        return false
    return (ElemType(f) = CT_LISTITEM)
}

; First real app row in AppsList (0 if none realized). Items are already known
; to be under AppsList, so we only exclude pinned/recommended and the toggle.
FirstAppEntry(list) {
    try {
        for it in list.FindElements({Type:"ListItem"}) {
            if InListById(it, ["PinnedList", "RecommendedList"])
                continue
            aid := ""
            try aid := it.AutomationId
            if (aid = "ViewSelectionButton")
                continue
            return it
        }
    }
    return 0
}

; Put focus on the first app row directly. Returns true only if focus actually
; landed on an app row.
FocusFirstApp() {
    if TryFocusFirstApp()
        return true
    ; App list absent. When the pinned overflow is EXPANDED ("Show less pinned
    ; apps"), that state hides the alphabetical list entirely -> collapse it and
    ; try once more.
    btn := GetPinnedToggle()
    if IsObject(btn) {
        nm := ""
        try nm := btn.Name
        if InStr(StrLower(nm), "less") {       ; "Show less..." = currently expanded
            ok := false
            try {
                btn.Invoke()
                ok := true
            }
            if !ok
                try btn.Click()
            Sleep(350)                          ; let Start re-render with the list back
            if TryFocusFirstApp()
                return true
        }
    }
    return false                          ; give up quietly; TabJump sends one Tab
}

; Focus the first app row if the app list is present (realizing it by scroll if
; needed). Returns true only if focus actually landed on an app row.
TryFocusFirstApp() {
    list := GetAppsList()
    if !IsObject(list)
        return false
    target := FirstAppEntry(list)
    if !IsObject(target)
        target := ScrollToRealizeApps(list)
    ; The Start app-list UIA tree can still be populating the first time Start
    ; opens after boot -> if nothing came back, wait briefly and re-read.
    if !IsObject(target) {
        Loop 5 {
            Sleep(100)
            list := GetAppsList()
            if IsObject(list)
                target := FirstAppEntry(list)
            if IsObject(target)
                break
        }
    }
    if !IsObject(target)
        return false
    try target.ScrollIntoView()
    try target.SetFocus()
    Sleep(40)
    return IsAppEntry(SafeFocus())
}

; Scroll the app list until its real rows realize; returns the first app row or 0.
; Does not move keyboard focus.
ScrollToRealizeApps(list) {
    ; 1) Try UIA scrolling first (fully silent, no mouse movement).
    Loop 6 {
        ok := false
        try {
            list.Scroll(2, 3)               ; UIA ScrollAmount: NoAmount, LargeIncrement
            ok := true
        }
        if !ok
            break
        Sleep(60)
        t := FirstAppEntry(list)
        if IsObject(t)
            return t
    }
    ; 2) Fallback: mouse-wheel over the Start panel. Scrolls whatever container
    ;    holds the list even if UIA scrolling isn't supported. It doesn't move
    ;    keyboard focus, so NVDA stays quiet; the mouse is put back afterward.
    hwnd := WinActive("ahk_exe StartMenuExperienceHost.exe")
    if !hwnd
        return 0
    MouseGetPos(&mx, &my)
    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    MouseMove(wx + ww // 2, wy + wh // 2, 0)
    found := 0
    Loop 8 {
        Send("{WheelDown}")
        Sleep(60)
        t := FirstAppEntry(list)
        if IsObject(t) {
            found := t
            break
        }
    }
    MouseMove(mx, my, 0)
    return found
}

; Fallback: arrow down from the pinned grid until focus lands on an app row.
DownIntoAppList() {
    Loop 20 {
        Send("{Down}")
        Sleep(45)
        if IsAppEntry(SafeFocus())
            return true
    }
    return false
}

; Fallback: tab forward until focus is on an app row. Bounded, and stops if it
; circles back to the search box rather than tabbing forever.
TabIntoAppList() {
    Loop 12 {
        Send("{Tab}")
        Sleep(45)
        f := SafeFocus()
        if IsAppEntry(f)
            return true
        aid := ""
        try aid := f.AutomationId
        if (aid = "SearchTextBox")
            return false
    }
    return false
}

; True if the pinned grid's overflow toggle is present (it only exists when
; there are more than 12 pinned items). Its label is "Show all pinned apps" or
; "Show less pinned apps" -- both contain "pinned apps".
PinnedToggleExists() {
    return IsObject(GetPinnedToggle())
}

; The pinned-overflow toggle Button (name contains "pinned apps"), or 0.
GetPinnedToggle() {
    hwnd := WinActive("ahk_exe StartMenuExperienceHost.exe")
    if !hwnd
        return 0
    try {
        root := UIA.ElementFromHandle(hwnd)
        for b in root.FindElements({Type:"Button"}) {
            nm := ""
            try nm := b.Name
            if InStr(StrLower(nm), "pinned apps")
                return b
        }
    }
    return 0
}

; Ctrl+P: put focus on the "Show all/less pinned apps" toggle so you can press
; Enter to expand/collapse the pinned overflow. Beeps if there's no overflow.
; Ctrl+Shift+Tab: put focus on the list/grid/category view toggle.
FocusViewToggle(*) {
    btn := GetViewToggle()
    if IsObject(btn) {
        try btn.ScrollIntoView()
        try btn.SetFocus()
    } else {
        PlayBeep()
    }
}

; The view-selection toggle element, or 0.
GetViewToggle() {
    hwnd := WinActive("ahk_exe StartMenuExperienceHost.exe")
    if !hwnd                              ; Start can be up but not reported active
        hwnd := WinExist("ahk_exe StartMenuExperienceHost.exe")
    if !hwnd
        return 0
    try {
        root := UIA.ElementFromHandle(hwnd)
        return root.FindElement({AutomationId:"ViewSelectionButton"})
    }
    return 0
}

FocusPinnedToggle(*) {
    btn := GetPinnedToggle()
    if IsObject(btn) {
        try btn.ScrollIntoView()
        try btn.SetFocus()
    } else {
        PlayBeep()            ; 12 or fewer pinned -> no overflow toggle exists
    }
}

TypeAheadKey(ch, *) {
    global taBusy, taBusyAt
    ; A type-ahead can take a moment on a cold list. If one is still running,
    ; drop this key rather than let two handlers overlap -- when they overlap the
    ; slower one finishes LAST and leaves focus on the wrong item.
    if taBusy {
        if (A_TickCount - taBusyAt > 5000) {   ; a handler died or wedged; if we
            Log("taBusy stuck -> cleared")     ; kept trusting the flag, every
            taBusy := false                    ; later keypress would be dropped
        } else {
            Log("key '" ch "': DROPPED (previous type-ahead still running)")
            return
        }
    }
    taBusy := true
    taBusyAt := A_TickCount
    try TypeAheadCore(ch)
    taBusy := false
}

TypeAheadCore(ch) {
    global taBuffer, taLast, taIndex, TA_TIMEOUT, CT_EDIT, listMode

    focused := 0
    try focused := UIA.GetFocusedElement()
    Log("key '" ch "': " ActiveWinInfo() " " DescribeFocus(focused) " listMode=" (listMode ? 1 : 0))

    ; SearchHost owns the foreground AND the search box really has focus -> the
    ; user is searching. Always type into search, whatever listMode says. This is
    ; what makes registering hotkeys for SearchHost safe.
    if (WinActive("ahk_exe SearchHost.exe") && ElemType(focused) = CT_EDIT) {
        Log("  -> search box (SearchHost) -> typed into search")
        SendText(ch)
        return
    }
    if (ElemType(focused) = CT_EDIT) {   ; search box focused -> type into search,
        if !listMode {                   ; unless we're in list-navigation mode.
            ; A cold Start menu can report a stale search-box focus while we are
            ; really on an app row. Re-read once before committing to search --
            ; sending a letter to the wrong place is the failure we keep hitting.
            Sleep(40)
            f2 := SafeFocus()
            if IsAppEntry(f2) {
                Log("  -> stale CT_EDIT; re-read shows app row -> type-ahead")
                focused := f2
                listMode := true
            } else {
                Log("  -> sent to SEARCH (listMode off) " DescribeFocus(f2))
                SendText(ch)
                return
            }
        }
    } else if InContextMenu(focused) {   ; a context menu is open -> don't hijack the
        Log("  -> sent to context menu")
        SendText(ch)                     ; key; pass it to the menu (type-select etc.)
        return
    }
    listMode := true                    ; committed to type-ahead -> stay in list mode

    ; Scope type-ahead to the region focus is in: an expanded folder's grid, the
    ; pinned grid, the recommended list, or the main app list. Only the app list
    ; needs pinned/recommended filtered out (they're nested inside it).
    excl := false
    if InListById(focused, ["StartFolderModal"])
        list := NearestListAncestor(focused)
    else if InListById(focused, ["PinnedList"])
        list := GetListById("PinnedList")
    else if InListById(focused, ["RecommendedList"])
        list := GetListById("RecommendedList")
    else {
        list := GetAppsList()
        excl := true
    }
    if !IsObject(list)
        return
    items := 0
    try items := list.FindElements({Type:"ListItem"})
    if (!IsObject(items) || !items.Length) {
        Loop 3 {                          ; list still populating (first boot open)?
            Sleep(80)                     ; wait a beat and re-read before giving up
            try items := list.FindElements({Type:"ListItem"})
            if (IsObject(items) && items.Length)
                break
        }
    }
    if (!IsObject(items) || !items.Length)
        return

    now := A_TickCount
    if (now - taLast > TA_TIMEOUT)
        taBuffer := ""
    taLast := now

    curIdx := FocusedIndex(items, focused, excl)
    if !curIdx
        curIdx := taIndex

    candidate := taBuffer . ch

    found := 0
    cycling := false
    if AllSame(candidate) {              ; same letter (incl. 1st press) -> cycle
        cycling := true
        found := NextWithPrefix(items, ch, curIdx, excl)
        taBuffer := ch
    } else {                             ; different letters -> try to extend prefix
        found := FirstWithPrefix(items, candidate, excl)
        if IsObject(found) {
            taBuffer := candidate
        } else {                         ; prefix miss -> fresh jump on the new letter
            found := NextWithPrefix(items, ch, curIdx, excl)
            taBuffer := ch
            cycling := true
        }
    }

    ; While cycling, if the only match is the item we're already on, focus
    ; wouldn't move -> treat it like a no-match. Compare by name (list indices
    ; can shift between keypresses as items realize).
    stuck := false
    foundName := ""
    if (cycling && IsObject(found)) {
        curName := ""
        try curName := focused.Name
        try foundName := found.el.Name
        if (curName != "" && curName = foundName)
            stuck := true
    }

    if (IsObject(found) && !stuck) {
        if (foundName = "")
            try foundName := found.el.Name
        ; SetFocus scrolls the item into view by itself. Calling ScrollIntoView
        ; FIRST can re-virtualise the list and invalidate this element -- and
        ; when the focus call then fails, Start drops focus back on the search
        ; box. That is exactly the "type-ahead went to the search box" symptom.
        try found.el.SetFocus()          ; real focus change -> NVDA announces it
        taIndex := found.idx
        Sleep(40)
        landed := ""
        try landed := SafeFocus().Name

        if (landed != foundName) {       ; missed -- the element reference was
            Log("  -> first SetFocus missed (focus '" landed "'), retrying")
            again := FindByName(list, foundName, excl)   ; probably stale, re-resolve
            if IsObject(again) {
                try again.ScrollIntoView()
                try again.SetFocus()
                Sleep(60)
                landed := ""
                try landed := SafeFocus().Name
            }
        }

        if (landed = foundName)
            Log("  -> moved to '" foundName "'")
        else
            Log("  -> SetFocus FAILED: wanted '" foundName "', focus is '" landed "'")
    } else {
        ; nothing matched, or a repeated key can't advance to a new item -> beep
        Log("  -> no move, beep (" (IsObject(found) ? "stuck on same item" : "no match") ")")
        PlayBeep()                           ; soft sine tone
    }
}

; Up/Down within the app list. Anywhere else -- pinned grid, recommended,
; expanded folder, account strip, search results -- the key is passed through
; untouched, so normal Start navigation is unaffected.
ListArrow(dir, *) {
    global taBusy, taBusyAt, listMode
    key := (dir = 1) ? "{Down}" : "{Up}"

    ; Fast path, no UIA at all: pass the key straight through when we're not
    ; navigating the app list, OR whenever the search box has focus -- SearchHost
    ; owns the foreground at that moment, which is exactly where Start begins
    ; after Win. listMode alone was not enough: it is only cleared by closing
    ; Start with Escape, so closing it any other way left it set, and the next
    ; Win press took the slow UIA path against a still-opening Start menu and
    ; lost the keystroke. That is why this failed only *sometimes*.
    if (!listMode || WinActive("ahk_exe SearchHost.exe")) {
        listMode := false                ; a fresh Start menu -- not in the list
        Send(key)
        return
    }

    focused := SafeFocus()
    if !IsAppEntry(focused) {            ; not on an app row -> native arrow
        Log("arrow " dir ": passed through (" DescribeFocus(focused) ")")
        Send(key)
        return
    }
    if taBusy {                          ; a type-ahead is mid-flight
        if (A_TickCount - taBusyAt > 5000) {
            Log("taBusy stuck -> cleared")
            taBusy := false
        } else {
            Log("arrow " dir ": DROPPED (busy)")
            return
        }
    }
    taBusy := true
    taBusyAt := A_TickCount
    try MoveInList(dir)
    taBusy := false
}

MoveInList(dir) {
    global taIndex
    focused := SafeFocus()
    list := GetAppsList()
    if !IsObject(list) {
        Send((dir = 1) ? "{Down}" : "{Up}")
        return
    }
    items := 0
    try items := list.FindElements({Type:"ListItem"})
    if (!IsObject(items) || !items.Length) {
        Send((dir = 1) ? "{Down}" : "{Up}")
        return
    }

    curName := ""
    try curName := focused.Name
    cur := 0
    Loop items.Length {                  ; locate ourselves, skipping pinned dupes
        it := items[A_Index]
        n2 := ""
        try n2 := it.Name
        if (n2 = curName) {
            if InListById(it, ["PinnedList", "RecommendedList"])
                continue
            cur := A_Index
            break
        }
    }
    if !cur {
        Send((dir = 1) ? "{Down}" : "{Up}")
        return
    }

    ; Step to the next real app row in that direction (no wrap at the ends).
    idx := cur
    target := 0
    Loop {
        idx += dir
        if (idx < 1 || idx > items.Length)
            break
        it := items[idx]
        if InListById(it, ["PinnedList", "RecommendedList"])
            continue
        aid := ""
        try aid := it.AutomationId
        if (aid = "ViewSelectionButton")
            continue
        target := idx
        break
    }
    if !target {
        PlayBeep()                       ; at the top or bottom of the list
        return
    }

    el := items[target]
    nm := ""
    try nm := el.Name
    try el.SetFocus()
    Sleep(40)
    landed := ""
    try landed := SafeFocus().Name
    if (landed != nm) {                  ; same stale-reference retry as type-ahead
        again := FindByName(list, nm, true)
        if IsObject(again) {
            try again.ScrollIntoView()
            try again.SetFocus()
            Sleep(60)
            landed := ""
            try landed := SafeFocus().Name
        }
    }
    taIndex := target
    if (landed = nm)
        Log("arrow " dir " -> '" nm "'")
    else
        Log("arrow " dir " -> FAILED: wanted '" nm "', focus is '" landed "'")
}

; Applications key / Shift+F10: note which row the menu is being opened from,
; then let the key through untouched.
ContextMenuKey(key, *) {
    global menuAnchorName, menuAnchorInFolder
    focused := SafeFocus()
    menuAnchorName := ""
    menuAnchorInFolder := InListById(focused, ["StartFolderModal"])
    if (IsAppEntry(focused) || menuAnchorInFolder)
        try menuAnchorName := focused.Name
    Log("context menu opened on '" menuAnchorName "'" (menuAnchorInFolder ? " (in folder)" : ""))
    Send(key)
}

; Enter is always passed straight through. The only extra behaviour is after
; activating a context-menu item: "Pin to Start" closes the menu and throws
; focus onto the newly pinned tile, so we put it back on the row the menu was
; opened from -- staying where you were in the list or folder.
EnterKey(*) {
    global menuAnchorName, listMode
    focused := SafeFocus()
    inMenu := InContextMenu(focused)
    Send("{Enter}")
    if (!inMenu || menuAnchorName = "")
        return
    Sleep(450)                            ; let Start close the menu and re-render
    if InListById(SafeFocus(), ["PinnedList"]) {
        Log("focus jumped to pinned grid after menu action -> restoring")
        if RestoreMenuAnchor()
            listMode := true
    }
    menuAnchorName := ""
}

; Put focus back on the remembered row, in its expanded folder if that is where
; the menu was opened, otherwise in the app list.
RestoreMenuAnchor() {
    global menuAnchorName, menuAnchorInFolder
    if (menuAnchorName = "")
        return false

    if menuAnchorInFolder {
        modal := 0
        try {
            hwnd := WinExist("ahk_exe StartMenuExperienceHost.exe")
            root := UIA.ElementFromHandle(hwnd)
            modal := root.FindElement({AutomationId:"StartFolderModal"})
        }
        if IsObject(modal) {
            el := FindByName(modal, menuAnchorName, false)
            if IsObject(el) {
                try el.SetFocus()
                Sleep(40)
                Log("restored focus to '" menuAnchorName "' in folder")
                return true
            }
        }
    }

    list := GetAppsList()
    if !IsObject(list)
        return false
    el := FindByName(list, menuAnchorName, true)
    if !IsObject(el) {
        Log("restore FAILED: '" menuAnchorName "' not found in the app list")
        return false
    }
    try el.SetFocus()
    Sleep(40)
    landed := ""
    try landed := SafeFocus().Name
    if (landed != menuAnchorName) {       ; same stale-reference retry as elsewhere
        again := FindByName(list, menuAnchorName, true)
        if IsObject(again) {
            try again.ScrollIntoView()
            try again.SetFocus()
            Sleep(60)
            landed := ""
            try landed := SafeFocus().Name
        }
    }
    Log("restore -> '" landed "' (wanted '" menuAnchorName "')")
    return (landed = menuAnchorName)
}

; Re-resolve a list item by name. Element references can go stale when the
; virtualised list re-renders, which is why a SetFocus can quietly miss.
FindByName(list, nm, excl) {
    if (nm = "")
        return 0
    try {
        for it in list.FindElements({Type:"ListItem"}) {
            n2 := ""
            try n2 := it.Name
            if (n2 != nm)
                continue
            if (excl && InListById(it, ["PinnedList", "RecommendedList"]))
                continue
            return it
        }
    }
    return 0
}

GetAppsList() {
    return GetListById("AppsList")
}

; The Start-menu List with the given AutomationId (0 if not found).
GetListById(id) {
    hwnd := WinActive("ahk_exe StartMenuExperienceHost.exe")
    if !hwnd                              ; Start can be up but not reported active
        hwnd := WinExist("ahk_exe StartMenuExperienceHost.exe")
    if !hwnd
        return 0
    list := 0
    try {
        root := UIA.ElementFromHandle(hwnd)
        list := root.FindElement({Type:"List", AutomationId:id})
    }
    return list
}

; Nearest ancestor List of the focused element (0 if none within 25 levels).
NearestListAncestor(el) {
    global CT_LIST
    cur := el
    Loop 25 {
        if !IsObject(cur)
            return 0
        if (ElemType(cur) = CT_LIST)
            return cur
        p := 0
        try p := cur.Parent
        cur := p
    }
    return 0
}

InListById(focused, ids) {
    if !IsObject(focused)
        return false
    cur := focused
    Loop 25 {
        if !IsObject(cur)
            return false
        aid := ""
        try aid := cur.AutomationId
        for wanted in ids
            if (aid = wanted)
                return true
        p := 0
        try p := cur.Parent
        cur := p
    }
    return false
}

FocusedIndex(items, focused, excl) {
    if !IsObject(focused)
        return 0
    fn := ""
    try fn := focused.Name
    if (fn = "")
        return 0
    Loop items.Length {
        it := items[A_Index]
        n2 := ""
        try n2 := it.Name
        if (n2 = fn) {
            if (excl && InListById(it, ["PinnedList", "RecommendedList"]))
                continue                 ; skip pinned/recommended duplicate
            return A_Index
        }
    }
    return 0
}

NextWithPrefix(items, prefix, startIdx, excl) {
    n := items.Length
    prefix := StrLower(prefix)
    Loop n {
        idx := Mod(startIdx + A_Index - 1, n) + 1
        it := items[idx]
        nm := ""
        try nm := it.Name
        if (nm != "" && StrLower(SubStr(nm, 1, StrLen(prefix))) = prefix) {
            if (excl && InListById(it, ["PinnedList", "RecommendedList"]))
                continue                 ; skip pinned/recommended -> stay in the list
            return {el: it, idx: idx}
        }
    }
    return 0
}

FirstWithPrefix(items, prefix, excl) {
    prefix := StrLower(prefix)
    Loop items.Length {
        it := items[A_Index]
        nm := ""
        try nm := it.Name
        if (nm != "" && StrLower(SubStr(nm, 1, StrLen(prefix))) = prefix) {
            if (excl && InListById(it, ["PinnedList", "RecommendedList"]))
                continue                 ; skip pinned/recommended -> stay in the list
            return {el: it, idx: A_Index}
        }
    }
    return 0
}

AllSame(s) {
    if (s = "")
        return false
    c := SubStr(s, 1, 1)
    Loop Parse s
        if (A_LoopField != c)
            return false
    return true
}

ElemType(el) {
    if !IsObject(el)
        return 0
    t := 0
    try t := el.Type
    return t
}

; ---- diagnostic: in the pinned grid (3rd row present), press Ctrl+D ----
; Reports what AppsList exposes and whether SetFocus on the first app row works.
; NVDA reads the message box; it's also copied to the clipboard. Remove later.
DumpAppsList(*) {
    hwnd := WinActive("ahk_exe StartMenuExperienceHost.exe")
    if !hwnd {
        MsgBox("Start is not the active window.")
        return
    }
    root := UIA.ElementFromHandle(hwnd)
    out := "=== LISTS ===`n"
    try {
        for lst in root.FindElements({Type:"List"}) {
            aid := "", cnt := 0, first := ""
            try aid := lst.AutomationId
            try {
                items := lst.FindElements({Type:"ListItem"})
                cnt := items.Length
                if cnt
                    try first := items[1].Name
            }
            out .= "List id='" aid "' items=" cnt " first='" first "'`n"
        }
    }
    out .= "=== BUTTONS ===`n"
    try {
        for b in root.FindElements({Type:"Button"}) {
            aid := "", nm := ""
            try aid := b.AutomationId
            try nm := b.Name
            out .= "'" nm "' id='" aid "'`n"
        }
    }
    A_Clipboard := out
    MsgBox(out, "Start structure (copied to clipboard)")
}

; ---- soft sine-wave beep, generated in memory and played via winmm ----
; Builds a 16-bit mono WAV (RIFF header + PCM samples) from a sine wave, so it
; plays through the normal audio path -- independent of the "Default Beep" sound
; scheme and not discarded while another system sound is playing.
MakeBeepWav(freq, durationMs, volume) {
    sampleRate := 44100
    nSamples := Integer(sampleRate * durationMs / 1000)
    dataBytes := nSamples * 2                  ; 16-bit mono
    buf := Buffer(44 + dataBytes, 0)

    NumPut("UInt",   0x46464952,    buf,  0)   ; "RIFF"
    NumPut("UInt",   36 + dataBytes, buf, 4)
    NumPut("UInt",   0x45564157,    buf,  8)   ; "WAVE"
    NumPut("UInt",   0x20746D66,    buf, 12)   ; "fmt "
    NumPut("UInt",   16,            buf, 16)   ; fmt chunk size
    NumPut("UShort", 1,             buf, 20)   ; PCM
    NumPut("UShort", 1,             buf, 22)   ; mono
    NumPut("UInt",   sampleRate,    buf, 24)   ; sample rate
    NumPut("UInt",   sampleRate * 2, buf, 28)  ; byte rate
    NumPut("UShort", 2,             buf, 32)   ; block align
    NumPut("UShort", 16,            buf, 34)   ; bits per sample
    NumPut("UInt",   0x61746164,    buf, 36)   ; "data"
    NumPut("UInt",   dataBytes,     buf, 40)

    off := 44
    Loop nSamples {
        s := Round(volume * 32767 * Sin(2 * 3.14159265358979 * freq * (A_Index - 1) / sampleRate))
        NumPut("Short", s, buf, off)
        off += 2
    }
    return buf
}

PlayBeep() {
    global BeepBuf
    ; SND_ASYNC (0x1) | SND_MEMORY (0x4) | SND_NODEFAULT (0x2)
    DllCall("winmm\PlaySound", "Ptr", BeepBuf, "Ptr", 0, "UInt", 0x7)
}

; ---- diagnostic helpers (remove with the log lines above when done) ----
Log(msg) {
    global LogPath, LogCount, LOG_MAX
    if (LogCount >= LOG_MAX)
        return
    LogCount += 1
    try FileAppend(A_Hour ":" A_Min ":" A_Sec "." A_MSec "  t=" A_TickCount "  " msg "`n", LogPath)
}

; Which window Windows currently considers active -- if our hotkeys ever fail to
; fire, this is what to check (the HotIf context is tied to the Start process).
ActiveWinInfo() {
    pn := "", ti := ""
    try pn := WinGetProcessName("A")
    try ti := WinGetTitle("A")
    return "win=" pn " '" ti "'"
}

; Short description of a focused element, for the log.
DescribeFocus(f) {
    if !IsObject(f)
        return "focus=(none)"
    nm := "", aid := "", t := 0
    try nm := f.Name
    try aid := f.AutomationId
    try t := f.Type
    return "focus type=" t " id='" aid "' name='" nm "'"
}

; Reload restarts the script from disk. It gives no feedback of its own, so a
; tone confirms it actually ran -- otherwise it looks like nothing happened.
ReloadScript(*) {
    global HighBuf
    Log("reload requested")
    PlayTone(HighBuf)
    Sleep(250)                            ; let the tone finish before restarting
    Reload()
}

; Suspends/resumes all hotkeys, with a tone so the state is audible:
; high = hotkeys live again, low = suspended (Start gets its keys raw).
ToggleSuspend(*) {
    global BeepBuf, HighBuf
    Suspend(-1)
    PlayTone(A_IsSuspended ? BeepBuf : HighBuf)   ; low = suspended, high = live
    Log("suspend toggled -> " (A_IsSuspended ? "SUSPENDED" : "active"))
}

PlayTone(buf) {
    ; SND_ASYNC | SND_MEMORY | SND_NODEFAULT
    DllCall("winmm\PlaySound", "Ptr", buf, "Ptr", 0, "UInt", 0x7)
}

; Keeps an unexpected error from showing a modal dialog or killing the script.
HandleError(err, mode) {
    global taBusy
    taBusy := false                       ; never strand the guard
    try Log("ERROR: " err.Message " at " err.File ":" err.Line)
    return 1                              ; handled -- no dialog, script lives on
}

; --- global escapes ----------------------------------------------------------
; Defined here in script text, NOT via Hotkey(), so the #SuspendExempt directive
; applies: Suspend disables every other hotkey, and without this exemption it
; would disable the key needed to undo it -- suspending once would be a one-way
; trip with no way back to the features.
;
;   Ctrl+Alt+Shift+S  suspend / resume all hotkeys (low tone = suspended)
;   Ctrl+Alt+Shift+R  restart the script from disk
#SuspendExempt
^!+s::ToggleSuspend()
^!+r::ReloadScript()
#SuspendExempt False
