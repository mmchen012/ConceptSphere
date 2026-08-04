; ==================================================================================================
; WindowSizer.ahk  (AutoHotkey v1.1)
; ==================================================================================================

#Requires AutoHotkey v1.1
#NoEnv
#SingleInstance Force
#NoTrayIcon
#Warn
SendMode Input
SetWorkingDir %A_ScriptDir%
SetTitleMatchMode, 2

; ==================================================================================================
; GLOBALS (ONLY g_* / h_* / GUI vVars are global)
; ==================================================================================================
global g_Ini := A_ScriptDir . "\WindowSizer.ini"
global g_EditWmHooked := false

global g_GuiBuilt := false

global g_SelOpenHwnd := 0
global g_SelOpenClass := ""
global g_SelTargetSection := ""

global h_Main := 0
global h_LVOpen := 0
global h_LVTarget := 0

global h_BtnAutoSize := 0
global h_BtnEdit := 0
global h_BtnRemove := 0
global h_BtnRefresh := 0
global h_BtnOpenIni := 0
global h_BtnHide := 0
global h_BtnExit := 0

; Main GUI vVars
global LVOpen := ""
global LVTarget := ""
global BtnEdit := ""
global BtnRemove := ""

; Edit Rule dialog globals
global g_EditGuiBuilt := false
global h_Edit := 0
global g_EditSec := ""
global g_EditHwnd := 0

; New-rule flow: when Ctrl+Alt+4 opens the Edit Rule dialog because no existing rule matches,
; do NOT write anything to the INI until the user explicitly presses Save.
global g_EditIsUnsavedNew := false

; Return behavior for Edit dialog
global g_EditReturnHwnd := 0     ; if set, activate this hwnd after save/cancel
global g_EditReturnToMain := false
global g_EditFocusWidthOnShow := false

; vVars for Edit GUI (must be global or static)
global ER_RuleName := ""
global ER_Class    := ""
global ER_Title    := ""
global ER_W := ""
global ER_H := ""
global ER_X := ""
global ER_Y := ""

; Compare + TitleMatch are RADIO GROUPS:
;   Compare:    ER_CompareMode: 1=Class, 2=Title
;   TitleMatch: ER_TitleMatchMode: 1=Exact, 2=Contains
global ER_CompareMode := 1
global ER_TitleMatchMode := 1

; Separate vVars for radio buttons (prevents caption turning into "2")
global ER_CmpClass := 0
global ER_CmpTitle := 0
global ER_TMExact := 0
global ER_TMContains := 0

; HWNDs for spin edits / updowns (so Enter works even if focus is on the spinner)
global h_ER_W := 0, h_ER_H := 0, h_ER_X := 0, h_ER_Y := 0
global h_UD_W := 0, h_UD_H := 0, h_UD_X := 0, h_UD_Y := 0

; CONFIG SECTION (hidden from rules list)
global g_CfgSection := "__WindowSizer__"

; Sound defaults (override via INI)
global g_SoundMode := "Wav"   ; "Beep" or "Wav"
global g_BeepFreq := 400
global g_BeepDur  := 40
global g_WavPath  := "C:\Windows\Media\Speech Misrecognition.wav"

; WinEvent hooks (Alt+Tab + title change auto-apply)
global g_hHookForeground := 0
global g_hHookNameChange := 0
global g_pWinEventProc := 0
global g_LastAutoApplyHwnd := 0
global g_LastAutoApplyTick := 0
global g_LastNameApplyTick := 0

; ==================================================================================================
; AUTO-EXECUTE
; ==================================================================================================
EnsureIni()
InstallWinEventHooks()
OnExit, HandleExit

global g_StartupArg1 := ""
if (IsObject(A_Args) && A_Args.Length() >= 1) {
    g_StartupArg1 := A_Args[1]
} else {
    if 0 >= 1
        g_StartupArg1 = %1%
}

if (IsShowArg(g_StartupArg1))
    ShowGui()

return  ; keep resident for hotkeys

; ==================================================================================================
; ARG HELPERS
; ==================================================================================================
IsShowArg(pArg) {
    pArg := Trim(pArg)
    StringLower, pArg, pArg
    return (pArg = "--show" || pArg = "/show" || pArg = "-show" || pArg = "show")
}

; ==================================================================================================
; SOUND CONFIG + PLAY (ONLY USED WHEN A RULE ACTUALLY APPLIES)
; ==================================================================================================
LoadSoundConfig() {
    global g_Ini, g_CfgSection
    global g_SoundMode, g_BeepFreq, g_BeepDur, g_WavPath

    EnsureIni()

    IniRead, m, %g_Ini%, %g_CfgSection%, SoundMode, Wav
    m := Trim(m)
    StringLower, ml, m
    if (ml = "beep")
        g_SoundMode := "Beep"
    else
        g_SoundMode := "Wav"

    IniRead, f, %g_Ini%, %g_CfgSection%, BeepFreq, 400
    IniRead, d, %g_Ini%, %g_CfgSection%, BeepDur, 40
    IniRead, w, %g_Ini%, %g_CfgSection%, WavPath, C:\Windows\Media\Speech Misrecognition.wav

    if !RegExMatch(Trim(f), "^\d+$")
        f := 400
    if !RegExMatch(Trim(d), "^\d+$")
        d := 40

    g_BeepFreq := f + 0
    g_BeepDur  := d + 0
    g_WavPath  := w
}

ZBeep() {
    global g_SoundMode, g_BeepFreq, g_BeepDur, g_WavPath

    LoadSoundConfig()

    if (g_SoundMode = "Beep") {
        SoundBeep, %g_BeepFreq%, %g_BeepDur%
        return
    }

    if (FileExist(g_WavPath)) {
        SoundPlay, %g_WavPath%   ; non-blocking when param2 omitted
    } else {
        SoundBeep, %g_BeepFreq%, %g_BeepDur%
    }
}

; ==================================================================================================
; HOTKEYS
; ==================================================================================================
^!5::ShowGui()
^!4::OpenRuleFlowForActiveWindow()
^!z::ApplyRuleToActiveWindow()

#If (h_Main && WinActive("ahk_id " . h_Main))
Up::
Left::
    GuardNavHotkey(A_ThisHotkey)
return
#If

#If (h_Edit && WinActive("ahk_id " . h_Edit))
Enter::
NumpadEnter::
    EditRule_EnterKey()
return
#If

GuardNavHotkey(pHotkey) {
    global h_Main, h_BtnAutoSize, h_BtnEdit
    ControlGetFocus, locCtl, ahk_id %h_Main%
    ControlGet, locFHwnd, Hwnd,, %locCtl%, ahk_id %h_Main%
    if (locFHwnd = h_BtnAutoSize || locFHwnd = h_BtnEdit)
        return
    Send, {%pHotkey%}
}

; ==================================================================================================
; MAIN GUI
; ==================================================================================================
ShowGui() {
    global g_GuiBuilt, h_LVOpen, h_Main

    if (!g_GuiBuilt)
        BuildGui()

    RefreshOpenWindows()
    RefreshTargets()
    UpdateTargetButtonsEnable()

    Gui, Main:Show
    WinActivate, ahk_id %h_Main%

    Gui, Main:Default
    Gui, ListView, LVOpen
    if (LV_GetCount() > 0) {
        LV_Modify(1, "Select Focus Vis")
        OnLVOpen_Select()
    }
    ControlFocus,, ahk_id %h_LVOpen%
}

BuildGui() {
    global g_GuiBuilt, h_Main
    global h_LVOpen, h_LVTarget
    global h_BtnAutoSize, h_BtnEdit, h_BtnRemove, h_BtnRefresh, h_BtnOpenIni, h_BtnHide, h_BtnExit
    global LVOpen, LVTarget, BtnEdit, BtnRemove

    locLeftW := 380
    locMidW  := 120
    locRightW := 380
    locGap := 20
    locListH := 245

    Gui, Main:New, +Resize +MinSize920x560 +Hwndh_Main, WindowSizer
    Gui, Main:Font, s10, Segoe UI
    Gui, Main:Margin, 10, 10
    Gui, Main:+LabelMainGui_

    Gui, Main:Add, Text, xm ym, Currently opened windows
    Gui, Main:Add, ListView, xm y+6 w%locLeftW% h%locListH% Grid -Multi +Hwndh_LVOpen vLVOpen gOnLVOpen, Title|Class|HWND

    GuiControlGet, locPos, Main:Pos, LVOpen
    locBtnX := locPosX + locPosW + locGap
    locBtnY := locPosY + Round((locPosH - 40)/2)

    Gui, Main:Add, Button, x%locBtnX% y%locBtnY% w%locMidW% h40 +Hwndh_BtnAutoSize gOnAutoSize, AutoSize

    locTargetX := locBtnX + locMidW + locGap
    Gui, Main:Add, Text, x%locTargetX% ym, Windows targeted by WindowSizer
    Gui, Main:Add, ListView, x%locTargetX% y%locPosY% w%locRightW% h%locListH% Grid -Multi +Hwndh_LVTarget vLVTarget gOnLVTarget, RuleName|Type|Match|Value|Section

    Gui, Main:Add, Button, xm y+20 w100 +Hwndh_BtnEdit    gOnEditTarget   vBtnEdit,   Edit
    Gui, Main:Add, Button, x+10 yp w100 +Hwndh_BtnRemove  gOnRemoveTarget vBtnRemove, Remove
    Gui, Main:Add, Button, x+10 yp w100 +Hwndh_BtnRefresh gOnRefresh, Refresh
    Gui, Main:Add, Button, x+10 yp w160 +Hwndh_BtnOpenIni gOnOpenIniFolder, Open INI Folder
    Gui, Main:Add, Button, x+10 yp w100 +Hwndh_BtnHide gOnHide, Hide
    Gui, Main:Add, Button, x+10 yp w100 +Hwndh_BtnExit gOnExit, Exit

    g_GuiBuilt := true
}

MainGui_Close:
MainGui_Escape:
    Gui, Main:Hide
return

; ==================================================================================================
; LISTVIEW EVENTS
; ==================================================================================================
OnLVOpen:
    if (A_GuiEvent = "I")
        OnLVOpen_Select()
return

OnLVTarget:
    if (A_GuiEvent = "I")
        LVTarget_OnSelect()
return

OnLVOpen_Select() {
    global g_SelOpenClass, g_SelOpenHwnd

    Gui, Main:Default
    Gui, ListView, LVOpen

    locRow := LV_GetNext(0, "F")
    if (!locRow)
        locRow := LV_GetNext(0, "S")
    if (!locRow)
        return

    LV_GetText(locClass, locRow, 2)
    LV_GetText(locHwnd,  locRow, 3)
    g_SelOpenClass := locClass
    g_SelOpenHwnd  := locHwnd + 0
}

LVTarget_OnSelect() {
    global g_SelTargetSection

    Gui, Main:Default
    Gui, ListView, LVTarget

    locRow := LV_GetNext(0, "F")
    if (!locRow)
        locRow := LV_GetNext(0, "S")

    if (!locRow) {
        g_SelTargetSection := ""
    } else {
        LV_GetText(locSec, locRow, 5)
        g_SelTargetSection := locSec
    }
    UpdateTargetButtonsEnable()
}

GetSelectedOpenHwnd() {
    Gui, Main:Default
    Gui, ListView, LVOpen

    row := LV_GetNext(0, "S")
    if (!row)
        row := LV_GetNext(0, "F")
    if (!row)
        return 0

    LV_GetText(hwndText, row, 3)
    return hwndText + 0
}

GetSelectedTargetSection() {
    Gui, Main:Default
    Gui, ListView, LVTarget

    row := LV_GetNext(0, "S")
    if (!row)
        row := LV_GetNext(0, "F")
    if (!row)
        return ""

    LV_GetText(sec, row, 5)
    return sec
}

; ==================================================================================================
; BUTTON ACTIONS (labels)
; ==================================================================================================
OnAutoSize:
    AutoSize_OnClick()
return
OnEditTarget:
    EditTarget_OnClick()
return
OnRemoveTarget:
    RemoveTarget_OnClick()
return
OnRefresh:
    Refresh_OnClick()
return
OnOpenIniFolder:
    OpenIniFolder_OnClick()
return
OnHide:
    Gui, Main:Hide
return
OnExit:
    ExitApp
return

AutoSize_OnClick() {
    hwnd := GetSelectedOpenHwnd()
    if (!hwnd)
        return
    OpenRuleFlowForHwnd(hwnd, 0)
}

EditTarget_OnClick() {
    global g_SelTargetSection
    sec := GetSelectedTargetSection()
    if (!sec)
        return
    g_SelTargetSection := sec
    EditRuleDialog_Open(sec, 0, true, false)
}

RemoveTarget_OnClick() {
    global g_Ini, g_SelTargetSection, h_LVTarget

    sec := GetSelectedTargetSection()
    if (!sec)
        return
    g_SelTargetSection := sec

    IniDelete, %g_Ini%, %sec%
    RefreshTargets()
    UpdateTargetButtonsEnable()

    Gui, Main:Default
    Gui, ListView, LVTarget
    if (LV_GetCount() > 0) {
        row := LV_GetNext(0, "S")
        if (!row)
            row := 1
        LV_Modify(row, "Select Focus Vis")
        LV_GetText(locSec, row, 5)
        g_SelTargetSection := locSec
    } else {
        g_SelTargetSection := ""
    }
    ControlFocus,, ahk_id %h_LVTarget%
}

Refresh_OnClick() {
    RefreshOpenWindows()
    RefreshTargets()
    UpdateTargetButtonsEnable()
}

OpenIniFolder_OnClick() {
    global g_Ini
    SplitPath, g_Ini,, locDir
    if (locDir = "")
        locDir := A_ScriptDir
    Run, explorer.exe "%locDir%"
}

UpdateTargetButtonsEnable() {
    global g_SelTargetSection
    Gui, Main:Default
    Gui, ListView, LVTarget

    locEnabled := (LV_GetCount() > 0) ? 1 : 0
    if (locEnabled) {
        GuiControl, Main:Enable, BtnEdit
        GuiControl, Main:Enable, BtnRemove
    } else {
        GuiControl, Main:Disable, BtnEdit
        GuiControl, Main:Disable, BtnRemove
        g_SelTargetSection := ""
    }
}

; ==================================================================================================
; LOADERS
; ==================================================================================================
RefreshOpenWindows() {
    global h_Main, h_Edit

    Gui, Main:Default
    Gui, ListView, LVOpen
    LV_Delete()

    WinGet, locList, List
    Loop, %locList% {
        locHwnd := locList%A_Index%

        if (locHwnd = h_Main)
            continue
        if (h_Edit && locHwnd = h_Edit)
            continue

        WinGetTitle, locTitle, ahk_id %locHwnd%
        WinGetClass, locClass, ahk_id %locHwnd%

        if (locTitle = "" || locTitle = "(no title)")
            continue
        if (locClass = "Shell_TrayWnd" || locClass = "Progman")
            continue

        if (locClass = "AutoHotkeyGUI" && SubStr(locTitle, 1, 11) = "Edit Rule -")
            continue

        LV_Add("", locTitle, locClass, locHwnd)
    }
}

RefreshTargets() {
    global g_Ini, g_SelTargetSection, g_CfgSection

    Gui, Main:Default
    Gui, ListView, LVTarget
    LV_Delete()

    locSecs := GetIniSections()
    Loop, Parse, locSecs, `n, `r
    {
        locSecName := A_LoopField
        if (locSecName = "")
            continue
        if (locSecName = g_CfgSection)
            continue

        IniRead, locCmp, %g_Ini%, %locSecName%, Compare, Class
        locCmpL := Trim(locCmp)
        StringLower, locCmpL, locCmpL

        if (locCmpL = "title") {
            IniRead, locVal, %g_Ini%, %locSecName%, Title,
            IniRead, locTM,  %g_Ini%, %locSecName%, TitleMatch, Exact
            LV_Add("", locSecName, "Title", locTM, locVal, locSecName)
        } else {
            IniRead, locVal, %g_Ini%, %locSecName%, Class,
            LV_Add("", locSecName, "Class", "Class", locVal, locSecName)
        }
    }

    if (LV_GetCount() > 0) {
        LV_Modify(1, "Select Focus")
        LV_GetText(locFirstSec, 1, 5)
        g_SelTargetSection := locFirstSec
    } else {
        g_SelTargetSection := ""
    }
}

; ==================================================================================================
; RULE FLOW
; ==================================================================================================
OpenRuleFlowForActiveWindow() {
    global g_GuiBuilt
    WinGet, locHwnd, ID, A
    if (!locHwnd)
        return
    OpenRuleFlowForHwnd(locHwnd, 1, true)
}

OpenRuleFlowForHwnd(pHwnd, pPreferTitleName := 0, pHideMainIfExisting := false) {
    global g_Ini, g_GuiBuilt
    global g_EditIsUnsavedNew

    EnsureIni()
    if (!pHwnd)
        return

    WinGetTitle, locTitle, ahk_id %pHwnd%
    WinGetClass, locCls,   ahk_id %pHwnd%
    if (locTitle = "" || locTitle = "(no title)")
        locTitle := locCls

    baseTitle := SanitizeSectionName(locTitle)
    baseClass := SanitizeSectionName(locCls)

    locBase := pPreferTitleName ? ((baseTitle != "") ? baseTitle : baseClass)
                               : ((baseClass != "") ? baseClass : baseTitle)

    locConflict := FindFirstMatchingRule(locCls, locTitle)
    if (locConflict != "") {
        g_EditIsUnsavedNew := false
        if (pHideMainIfExisting && g_GuiBuilt)
            Gui, Main:Hide
        EnsureRuleSectionFromHwnd(locConflict, pHwnd, locCls, locTitle)
        EditRuleDialog_Open(locConflict, pHwnd, false, true) ; focus width
        return
    }

    locNewName := MakeUniqueSectionName(locBase)
    ; IMPORTANT: For a new rule, do NOT pre-write defaults into the INI.
    ; Only write when the user explicitly presses Save.
    g_EditIsUnsavedNew := true
    EditRuleDialog_Open(locNewName, pHwnd, false, false)

    if (pPreferTitleName && baseTitle != "") {
        Gui, Edit:Default
        GuiControl,, ER_RuleName, %baseTitle%
    }

    Gui, Edit:Default
    GuiControl, Focus, ER_RuleName
}

; ==================================================================================================
; MATCHING (Title precedence; case-insensitive)
; ==================================================================================================
FindFirstMatchingRule(pWinClass, pWinTitle) {
    global g_Ini, g_CfgSection
    locSecs := GetIniSections()

    pWinTitle := Trim(pWinTitle)
    pWinClass := Trim(pWinClass)

    ; PASS 1: TITLE RULES FIRST
    Loop, Parse, locSecs, `n, `r
    {
        locSecName := A_LoopField
        if (locSecName = "" || locSecName = g_CfgSection)
            continue

        IniRead, locCmp, %g_Ini%, %locSecName%, Compare, Class
        locCmpL := Trim(locCmp)
        StringLower, locCmpL, locCmpL
        if (locCmpL != "title")
            continue

        IniRead, locT,  %g_Ini%, %locSecName%, Title,
        IniRead, locTM, %g_Ini%, %locSecName%, TitleMatch, Exact
        locT := Trim(locT)
        if (locT = "")
            continue

        locTML := Trim(locTM)
        StringLower, locTML, locTML

        if (locTML = "contains") {
            if (InStr(pWinTitle, locT, false))
                return locSecName
        } else {
            t1 := pWinTitle, t2 := locT
            StringLower, t1, t1
            StringLower, t2, t2
            if (t1 = t2)
                return locSecName
        }
    }

    ; PASS 2: CLASS RULES
    Loop, Parse, locSecs, `n, `r
    {
        locSecName := A_LoopField
        if (locSecName = "" || locSecName = g_CfgSection)
            continue

        IniRead, locCmp, %g_Ini%, %locSecName%, Compare, Class
        locCmpL := Trim(locCmp)
        StringLower, locCmpL, locCmpL
        if (locCmpL = "title")
            continue

        IniRead, locC, %g_Ini%, %locSecName%, Class,
        locC := Trim(locC)
        if (locC = "")
            continue

        c1 := pWinClass, c2 := locC
        StringLower, c1, c1
        StringLower, c2, c2
        if (c1 = c2)
            return locSecName
    }

    return ""
}

EnsureRuleSectionFromHwnd(pSec, pHwnd, pCls, pTitle) {
    global g_Ini

    IniRead, locV, %g_Ini%, %pSec%, Compare, __M__
    if (locV = "__M__")
        IniWrite, Class, %g_Ini%, %pSec%, Compare

    IniRead, locV, %g_Ini%, %pSec%, Class, __M__
    if (locV = "__M__")
        IniWrite, %pCls%, %g_Ini%, %pSec%, Class

    IniRead, locV, %g_Ini%, %pSec%, Title, __M__
    if (locV = "__M__")
        IniWrite, %pTitle%, %g_Ini%, %pSec%, Title

    IniRead, locV, %g_Ini%, %pSec%, TitleMatch, __M__
    if (locV = "__M__")
        IniWrite, Exact, %g_Ini%, %pSec%, TitleMatch

    WinGetPos, lx, ly, lw, lh, ahk_id %pHwnd%
    IniWrite, %lw%, %g_Ini%, %pSec%, W
    IniWrite, %lh%, %g_Ini%, %pSec%, H
    IniWrite, %lx%, %g_Ini%, %pSec%, X
    IniWrite, %ly%, %g_Ini%, %pSec%, Y
}

; ==================================================================================================
; EDIT RULE DIALOG
; ==================================================================================================
EditRuleDialog_Open(pSec, pHwnd := 0, pReturnToMain := false, pFocusWidth := false) {
    global g_Ini, g_EditGuiBuilt, h_Edit, g_EditSec, g_EditHwnd
    global g_EditReturnHwnd, g_EditReturnToMain, g_EditFocusWidthOnShow
    global ER_RuleName, ER_Class, ER_Title, ER_W, ER_H, ER_X, ER_Y
    global ER_CompareMode, ER_TitleMatchMode
    global ER_CmpClass, ER_CmpTitle
    global ER_TMExact, ER_TMContains

    EnsureIni()
    g_EditSec := pSec
    g_EditHwnd := pHwnd

    g_EditReturnToMain := pReturnToMain ? true : false
    g_EditFocusWidthOnShow := pFocusWidth ? true : false
    g_EditReturnHwnd := (pHwnd ? pHwnd : 0)

    if (!g_EditGuiBuilt)
        EditRuleDialog_Build()

    IniRead, locCmp, %g_Ini%, %pSec%, Compare, Class
    IniRead, locCls, %g_Ini%, %pSec%, Class,
    IniRead, locTtl, %g_Ini%, %pSec%, Title,
    IniRead, locTM,  %g_Ini%, %pSec%, TitleMatch, Exact
    IniRead, locW,   %g_Ini%, %pSec%, W,
    IniRead, locH,   %g_Ini%, %pSec%, H,
    IniRead, locX,   %g_Ini%, %pSec%, X,
    IniRead, locY,   %g_Ini%, %pSec%, Y,

    if (pHwnd) {
        WinGetTitle, liveTitle, ahk_id %pHwnd%
        WinGetClass, liveClass, ahk_id %pHwnd%
        WinGetPos, liveX, liveY, liveW, liveH, ahk_id %pHwnd%

        if (liveClass != "")
            locCls := liveClass
        if (Trim(locTtl) = "" && liveTitle != "" && liveTitle != "(no title)")
            locTtl := liveTitle

        locW := liveW, locH := liveH, locX := liveX, locY := liveY
    }

    locCmp := Trim(locCmp)
    StringLower, locCmpL, locCmp
    ER_CompareMode := (locCmpL = "title") ? 2 : 1

    locTM := Trim(locTM)
    StringLower, locTML, locTM
    ER_TitleMatchMode := (locTML = "contains") ? 2 : 1

    ER_RuleName := pSec
    ER_Class := locCls
    ER_Title := locTtl
    ER_W := locW
    ER_H := locH
    ER_X := locX
    ER_Y := locY

    Gui, Edit:Default
    GuiControl,, ER_RuleName, %ER_RuleName%
    GuiControl,, ER_Class,    %ER_Class%
    GuiControl,, ER_Title,    %ER_Title%
    GuiControl,, ER_W, %ER_W%
    GuiControl,, ER_H, %ER_H%
    GuiControl,, ER_X, %ER_X%
    GuiControl,, ER_Y, %ER_Y%

    ER_CmpClass := (ER_CompareMode = 1) ? 1 : 0
    ER_CmpTitle := (ER_CompareMode = 2) ? 1 : 0
    GuiControl,, ER_CmpClass, %ER_CmpClass%
    GuiControl,, ER_CmpTitle, %ER_CmpTitle%

    ER_TMExact := (ER_TitleMatchMode = 1) ? 1 : 0
    ER_TMContains := (ER_TitleMatchMode = 2) ? 1 : 0
    GuiControl,, ER_TMExact, %ER_TMExact%
    GuiControl,, ER_TMContains, %ER_TMContains%

    EditRuleDialog_UpdateCompareUI()

    Gui, Edit:Show,, Edit Rule - %pSec%
    WinActivate, ahk_id %h_Edit%

    ; Explicit focus policy:
    ; - If we're editing an *existing* matched rule, land on Width (fast sizing tweaks).
    ; - Otherwise (new rule / no match), land on Rule name (so user can name it immediately).
    if (g_EditFocusWidthOnShow)
        GuiControl, Focus, ER_W
    else
        GuiControl, Focus, ER_RuleName
}

EditRuleDialog_Build() {
    global g_EditGuiBuilt, h_Edit
    global ER_RuleName, ER_Class, ER_Title, ER_W, ER_H, ER_X, ER_Y
    global ER_CmpClass, ER_CmpTitle
    global ER_TMExact, ER_TMContains
    global h_ER_W, h_ER_H, h_ER_X, h_ER_Y
    global h_UD_W, h_UD_H, h_UD_X, h_UD_Y
    ; Owner fix: use Main window HWND when available (avoids +OwnerMain GUI-name dependency)
    locOpts := "+MinSize600x360 +Hwndh_Edit"
    if (h_Main && WinExist("ahk_id " . h_Main))
        locOpts := "+Owner" . h_Main . " " . locOpts
    Gui, Edit:New, %locOpts%, Edit Rule
    Gui, Edit:Font, s10, Segoe UI
    Gui, Edit:Margin, 12, 12
    Gui, Edit:+LabelEditGui_

    Gui, Edit:Add, Text, xm ym w120, Rule name
    Gui, Edit:Add, Edit, x+10 yp w420 vER_RuleName

    Gui, Edit:Add, Text, xm y+14 w120, Compare
    Gui, Edit:Add, Radio, x+10 yp vER_CmpClass gOnEditCompareChange, Class
    Gui, Edit:Add, Radio, x+18 yp vER_CmpTitle gOnEditCompareChange, Title

    Gui, Edit:Add, Text, xm y+14 w120, Class
    Gui, Edit:Add, Edit, x+10 yp w420 vER_Class

    Gui, Edit:Add, Text, xm y+14 w120, Title
    Gui, Edit:Add, Edit, x+10 yp w420 vER_Title

    Gui, Edit:Add, Text, xm y+14 w120, Title match
    Gui, Edit:Add, Radio, x+10 yp vER_TMExact, Exact
    Gui, Edit:Add, Radio, x+18 yp vER_TMContains, Contains

    Gui, Edit:Add, Text, xm y+18 w120, Width (W)
    Gui, Edit:Add, Edit, x+10 yp w90 Number vER_W +Hwndh_ER_W

    Gui, Edit:Add, Text, x+28 yp w70, Height (H)
    Gui, Edit:Add, Edit, x+10 yp w90 Number vER_H +Hwndh_ER_H

    Gui, Edit:Add, Text, xm y+14 w120, X
    Gui, Edit:Add, Edit, x+10 yp w90 Number vER_X +Hwndh_ER_X

    Gui, Edit:Add, Text, x+28 yp w70, Y
    Gui, Edit:Add, Edit, x+10 yp w90 Number vER_Y +Hwndh_ER_Y

    Gui, Edit:Add, Button, xm y+22 w110 gOnEditSave Default, Save
    Gui, Edit:Add, Button, x+10 yp w110 gOnEditCancel, Cancel

    ER_CmpClass := 1
    ER_CmpTitle := 0
    ER_TMExact := 1
    ER_TMContains := 0

    ; Prevent spin buddy edits from inserting locale thousand separators (",").
    ; UpDown's UDS_SETBUDDYINT style (0x2) can cause comma formatting. Strip it.
    _UpDown_DisableBuddyInt(h_UD_W)
    _UpDown_DisableBuddyInt(h_UD_H)
    _UpDown_DisableBuddyInt(h_UD_X)
    _UpDown_DisableBuddyInt(h_UD_Y)

    g_EditGuiBuilt := true
    EditRuleDialog_UpdateCompareUI()
}

; Strip UDS_SETBUDDYINT (0x2) from an UpDown control so its buddy Edit doesn't auto-format
; numbers with locale thousand separators (e.g., inserting commas).
_UpDown_DisableBuddyInt(hUpDown) {
    if (!hUpDown)
        return
    ; GWL_STYLE = -16
    style := DllCall("GetWindowLong" . (A_PtrSize=8 ? "Ptr" : ""), "Ptr", hUpDown, "Int", -16, "Ptr")
    if (!style)
        return
    newStyle := style & ~0x2
    if (newStyle = style)
        return
    DllCall("SetWindowLong" . (A_PtrSize=8 ? "Ptr" : ""), "Ptr", hUpDown, "Int", -16, "Ptr", newStyle)
    ; SWP_NOMOVE(0x2)|SWP_NOSIZE(0x1)|SWP_NOZORDER(0x4)|SWP_FRAMECHANGED(0x20)=0x27
    DllCall("SetWindowPos", "Ptr", hUpDown, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x27)
}

OnEditCompareChange:
    EditRuleDialog_UpdateCompareUI()
return

; Numeric spin-buddy edits can still receive locale thousand separators on some systems.
; Strip commas immediately on any change so values remain strict integers.
OnSpinEditChange:
    EditRule_StripThousands(A_GuiControl)
return

EditRule_StripThousands(pVarName) {
    global h_ER_W, h_ER_H, h_ER_X, h_ER_Y

    if (pVarName = "")
        return

    Gui, Edit:Default
    GuiControlGet, locVal,, %pVarName%
    if (!InStr(locVal, ","))
        return

    locNew := StrReplace(locVal, ",", "")
    GuiControl,, %pVarName%, %locNew%

    ; Best-effort caret fix: move caret to end of text.
    hCtl := 0
    if (pVarName = "ER_W")
        hCtl := h_ER_W
    else if (pVarName = "ER_H")
        hCtl := h_ER_H
    else if (pVarName = "ER_X")
        hCtl := h_ER_X
    else if (pVarName = "ER_Y")
        hCtl := h_ER_Y

    if (hCtl) {
        pos := StrLen(locNew)
        ; EM_SETSEL = 0xB1
        SendMessage, 0xB1, %pos%, %pos%,, ahk_id %hCtl%
    }
}

EditRuleDialog_UpdateCompareUI() {
    global ER_CmpTitle, ER_CompareMode
    Gui, Edit:Default
    Gui, Edit:Submit, NoHide

    ER_CompareMode := (ER_CmpTitle) ? 2 : 1

    if (ER_CompareMode = 2) {
        GuiControl, Edit:Disable, ER_Class
        GuiControl, Edit:Enable,  ER_Title
        GuiControl, Edit:Enable,  ER_TMExact
        GuiControl, Edit:Enable,  ER_TMContains
    } else {
        GuiControl, Edit:Enable,  ER_Class
        GuiControl, Edit:Disable, ER_Title
        GuiControl, Edit:Disable, ER_TMExact
        GuiControl, Edit:Disable, ER_TMContains
    }
}

EditGui_Close:
EditGui_Escape:
    EditRule_CancelAndReturn()
return

OnEditSave:
    EditRule_Save()
return

OnEditCancel:
    EditRule_CancelAndReturn()
return

EditRule_CancelAndReturn() {
    global g_EditReturnHwnd, g_EditReturnToMain, h_Main
    global g_EditIsUnsavedNew
    Gui, Edit:Hide
    ; Cancel should never persist anything for a brand-new rule.
    g_EditIsUnsavedNew := false
    if (g_EditReturnHwnd) {
        WinActivate, ahk_id %g_EditReturnHwnd%
        return
    }
    if (g_EditReturnToMain && h_Main) {
        WinActivate, ahk_id %h_Main%
        return
    }
}

EditRule_EnterKey() {
    global h_Edit
    global h_ER_W, h_ER_H, h_ER_X, h_ER_Y
    global h_UD_W, h_UD_H, h_UD_X, h_UD_Y

    ControlGetFocus, c, ahk_id %h_Edit%
    if (c = "")
        return
    ControlGet, fh, Hwnd,, %c%, ahk_id %h_Edit%

    if (fh = h_ER_W || fh = h_ER_H || fh = h_ER_X || fh = h_ER_Y
     || fh = h_UD_W || fh = h_UD_H || fh = h_UD_X || fh = h_UD_Y) {
        EditRule_Save()
        return
    }
    Send, {Enter}
}

; ==================================================================================================
; VALIDATION / CLAMP
; ==================================================================================================
ValidateAndClampRect(ByRef w, ByRef h, ByRef x, ByRef y, pHwnd := 0) {
    if (!IsIntegerStrict(w) || !IsIntegerStrict(h) || !IsIntegerStrict(x) || !IsIntegerStrict(y)) {
        MsgBox, 48, Save Rule, Width/Height/X/Y must all be valid integers.
        return false
    }
    w := w + 0, h := h + 0, x := x + 0, y := y + 0
    if (w <= 0 || h <= 0) {
        MsgBox, 48, Save Rule, Width and Height must be greater than 0.
        return false
    }
    return ClampRectToWorkArea(w, h, x, y, pHwnd)
}

ValidateAndClampRect_Quiet(ByRef w, ByRef h, ByRef x, ByRef y, pHwnd := 0) {
    if (!IsIntegerStrict(w) || !IsIntegerStrict(h) || !IsIntegerStrict(x) || !IsIntegerStrict(y))
        return false
    w := w + 0, h := h + 0, x := x + 0, y := y + 0
    if (w <= 0 || h <= 0)
        return false
    return ClampRectToWorkArea(w, h, x, y, pHwnd)
}

ClampRectToWorkArea(ByRef w, ByRef h, ByRef x, ByRef y, pHwnd := 0) {
    if (!pHwnd)
        pHwnd := WinExist("A")

    if (!GetWorkAreaForHwnd(pHwnd, waL, waT, waR, waB)) {
        SysGet, waL, 76
        SysGet, waT, 77
        SysGet, waR, 78
        SysGet, waB, 79
    }

    waW := waR - waL
    waH := waB - waT
    if (waW <= 0 || waH <= 0)
        return false

    if (w > waW)
        w := waW
    if (h > waH)
        h := waH

    if (x < waL)
        x := waL
    if (y < waT)
        y := waT
    if (x + w > waR)
        x := waR - w
    if (y + h > waB)
        y := waB - h

    if (x < waL)
        x := waL
    if (y < waT)
        y := waT

    return true
}

IsIntegerStrict(v) {
    v := Trim(v)
    return RegExMatch(v, "^-?\d+$")
}

GetWorkAreaForHwnd(hwnd, ByRef waL, ByRef waT, ByRef waR, ByRef waB) {
    if (!hwnd)
        return false

    hMon := DllCall("User32.dll\MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    if (!hMon)
        return false

    VarSetCapacity(mi, 40, 0)
    NumPut(40, mi, 0, "UInt")
    ok := DllCall("User32.dll\GetMonitorInfo", "Ptr", hMon, "Ptr", &mi, "UInt")
    if (!ok)
        return false

    waL := NumGet(mi, 20, "Int")
    waT := NumGet(mi, 24, "Int")
    waR := NumGet(mi, 28, "Int")
    waB := NumGet(mi, 32, "Int")
    return true
}

EditRule_Save() {
    global g_Ini, g_EditSec, g_EditHwnd
    global g_EditReturnHwnd, g_EditReturnToMain, h_Main
    global g_EditIsUnsavedNew
    global ER_RuleName, ER_Class, ER_Title, ER_W, ER_H, ER_X, ER_Y
    global ER_CompareMode, ER_TitleMatchMode
    global ER_CmpTitle
    global ER_TMContains

    Gui, Edit:Submit, NoHide

    ER_CompareMode := (ER_CmpTitle) ? 2 : 1
    ER_TitleMatchMode := (ER_TMContains) ? 2 : 1

    locCompare := (ER_CompareMode = 2) ? "Title" : "Class"
    locTitleMatch := (ER_TitleMatchMode = 2) ? "Contains" : "Exact"

    newName := Trim(ER_RuleName)
    if (newName = "")
        return
    newName := SanitizeSectionName(newName)
    if (newName = "")
        return

    w := ER_W, h := ER_H, x := ER_X, y := ER_Y
    if (!ValidateAndClampRect(w, h, x, y, g_EditHwnd ? g_EditHwnd : h_Edit))
        return

    if (w != ER_W || h != ER_H || x != ER_X || y != ER_Y) {
        ER_W := w, ER_H := h, ER_X := x, ER_Y := y
        GuiControl,, ER_W, %ER_W%
        GuiControl,, ER_H, %ER_H%
        GuiControl,, ER_X, %ER_X%
        GuiControl,, ER_Y, %ER_Y%
    }

    if (newName != g_EditSec) {
        if (IniSectionExists(newName)) {
            msg := "A rule named """ . newName . """ already exists.`nWould you like to over-write the rule?"
            MsgBox, 52, Save Rule Alert, %msg%
            IfMsgBox, No
                return
            IniDelete, %g_Ini%, %newName%
        }
        ; If we opened a brand-new rule (Ctrl+Alt+4, no match), the section may not exist yet.
        ; Only copy/delete when the old section actually exists.
        if (IniSectionExists(g_EditSec)) {
            CopyRuleSection(g_EditSec, newName)
            IniDelete, %g_Ini%, %g_EditSec%
        }
        g_EditSec := newName
    }

    IniWrite, %locCompare%,    %g_Ini%, %g_EditSec%, Compare
    IniWrite, %ER_Class%,      %g_Ini%, %g_EditSec%, Class
    IniWrite, %ER_Title%,      %g_Ini%, %g_EditSec%, Title
    IniWrite, %locTitleMatch%, %g_Ini%, %g_EditSec%, TitleMatch
    IniWrite, %ER_W%,          %g_Ini%, %g_EditSec%, W
    IniWrite, %ER_H%,          %g_Ini%, %g_EditSec%, H
    IniWrite, %ER_X%,          %g_Ini%, %g_EditSec%, X
    IniWrite, %ER_Y%,          %g_Ini%, %g_EditSec%, Y

    ; Once Save succeeds, this is no longer an unsaved/new rule.
    g_EditIsUnsavedNew := false

    ; Once saved, it's no longer a transient/unsaved new rule.
    g_EditIsUnsavedNew := false

    RefreshTargets()
    UpdateTargetButtonsEnable()

    Gui, Edit:Hide

    if (g_EditReturnHwnd) {
        WinActivate, ahk_id %g_EditReturnHwnd%
        return
    }
    if (g_EditReturnToMain && h_Main) {
        WinActivate, ahk_id %h_Main%
        return
    }
}

; ==================================================================================================
; INI HELPERS
; ==================================================================================================
EnsureIni() {
    global g_Ini, g_CfgSection

    if !FileExist(g_Ini) {
        FileAppend,
        (
; WindowSizer.ini

[__WindowSizer__]
; SoundMode: Beep or Wav
SoundMode=Wav
; Beep defaults (used when SoundMode=Beep)
BeepFreq=400
BeepDur=40
; Wav path (used when SoundMode=Wav)
WavPath=C:\Windows\Media\Speech Misrecognition.wav

[Example]
Compare=Class
Class=Notepad
Title=Notepad
TitleMatch=Exact
W=
H=
X=
Y=
        ), %g_Ini%
        return
    }

    IniRead, v, %g_Ini%, %g_CfgSection%, SoundMode, __M__
    if (v="__M__")
        IniWrite, Wav, %g_Ini%, %g_CfgSection%, SoundMode

    IniRead, v, %g_Ini%, %g_CfgSection%, BeepFreq, __M__
    if (v="__M__")
        IniWrite, 400, %g_Ini%, %g_CfgSection%, BeepFreq

    IniRead, v, %g_Ini%, %g_CfgSection%, BeepDur, __M__
    if (v="__M__")
        IniWrite, 40, %g_Ini%, %g_CfgSection%, BeepDur

    IniRead, v, %g_Ini%, %g_CfgSection%, WavPath, __M__
    if (v="__M__")
        IniWrite, C:\Windows\Media\Speech Misrecognition.wav, %g_Ini%, %g_CfgSection%, WavPath
}

GetIniSections() {
    global g_Ini
    if !FileExist(g_Ini)
        return ""

    locSecs := ""
    Loop, Read, %g_Ini%
    {
        locLine := A_LoopReadLine
        if RegExMatch(locLine, "^\s*\[([^\]\r\n]+)\]\s*$", locM) {
            locName := Trim(locM1)
            if (locName != "")
                locSecs .= locName . "`n"
        }
    }
    return RTrim(locSecs, "`n")
}

SanitizeSectionName(pName) {
    pName := Trim(pName)
    pName := RegExReplace(pName, "\s+", " ")
    pName := RegExReplace(pName, "[\[\]:\*\?""<>|/\\\t]", "_")
    pName := Trim(pName, " ._")
    if (StrLen(pName) > 80)
        pName := SubStr(pName, 1, 80)
    return pName
}

IniSectionExists(pSec) {
    global g_Ini
    IniRead, locX, %g_Ini%, %pSec%, Compare, __MISSING__
    return (locX <> "__MISSING__")
}

MakeUniqueSectionName(pBase) {
    if !IniSectionExists(pBase)
        return pBase

    locI := 2
    Loop {
        locCand := pBase . " (" . locI . ")"
        if !IniSectionExists(locCand)
            return locCand
        locI++
        if (locI > 9999)
            return pBase . " (" . A_TickCount . ")"
    }
}

CopyRuleSection(pSrc, pDst) {
    global g_Ini

    IniRead, locCmp, %g_Ini%, %pSrc%, Compare, Class
    IniRead, locCls, %g_Ini%, %pSrc%, Class,
    IniRead, locTtl, %g_Ini%, %pSrc%, Title,
    IniRead, locTM,  %g_Ini%, %pSrc%, TitleMatch, Exact
    IniRead, locW,   %g_Ini%, %pSrc%, W,
    IniRead, locH,   %g_Ini%, %pSrc%, H,
    IniRead, locX,   %g_Ini%, %pSrc%, X,
    IniRead, locY,   %g_Ini%, %pSrc%, Y,

    IniWrite, %locCmp%, %g_Ini%, %pDst%, Compare
    IniWrite, %locCls%, %g_Ini%, %pDst%, Class
    IniWrite, %locTtl%, %g_Ini%, %pDst%, Title
    IniWrite, %locTM%,  %g_Ini%, %pDst%, TitleMatch
    IniWrite, %locW%,   %g_Ini%, %pDst%, W
    IniWrite, %locH%,   %g_Ini%, %pDst%, H
    IniWrite, %locX%,   %g_Ini%, %pDst%, X
    IniWrite, %locY%,   %g_Ini%, %pDst%, Y
}

; ==================================================================================================
; APPLY (Ctrl+Alt+Z) — sound only if applied
; ==================================================================================================
ApplyRuleToActiveWindow() {
    WinGet, hwnd, ID, A
    if (!hwnd)
        return

    WinGetTitle, t, ahk_id %hwnd%
    WinGetClass, c, ahk_id %hwnd%

    sec := FindFirstMatchingRule(c, t)
    if (sec = "")
        return

    if (ApplyRuleSectionToHwnd(sec, hwnd))
        ZBeep()
}

ApplyRuleSectionToHwnd(pSec, pHwnd) {
    global g_Ini

    IniRead, w, %g_Ini%, %pSec%, W, __M__
    IniRead, h, %g_Ini%, %pSec%, H, __M__
    IniRead, x, %g_Ini%, %pSec%, X, __M__
    IniRead, y, %g_Ini%, %pSec%, Y, __M__

    if (w="__M__" || h="__M__" || x="__M__" || y="__M__")
        return false

    if (!ValidateAndClampRect_Quiet(w, h, x, y, pHwnd))
        return false

    WinGetPos, cx, cy, cw, ch, ahk_id %pHwnd%
    if (cw = w && ch = h && cx = x && cy = y)
        return false

    WinGet, mm, MinMax, ahk_id %pHwnd%
    if (mm = 1 || mm = -1)
        WinRestore, ahk_id %pHwnd%

    ErrorLevel := 0
    WinMove, ahk_id %pHwnd%,, %x%, %y%, %w%, %h%
    if (ErrorLevel)
        return false

    WinGetPos, nx, ny, nw, nh, ahk_id %pHwnd%
    if (nw = cw && nh = ch && nx = cx && ny = cy)
        return false

    return true
}

; ==================================================================================================
; WinEvent hooks:
;  - Foreground change (Alt+Tab, click to focus, etc.)
;  - Name change (title changes, e.g. Ctrl+Tab inside Notepad++)
; ==================================================================================================
InstallWinEventHooks() {
    global g_hHookForeground, g_hHookNameChange, g_pWinEventProc

    if (g_hHookForeground || g_hHookNameChange)
        return

    EVENT_SYSTEM_FOREGROUND := 0x0003
    EVENT_OBJECT_NAMECHANGE := 0x800C
    WINEVENT_OUTOFCONTEXT := 0x0000

    g_pWinEventProc := RegisterCallback("WinEventProc", "Fast", 7)

    g_hHookForeground := DllCall("User32.dll\SetWinEventHook"
        , "UInt", EVENT_SYSTEM_FOREGROUND
        , "UInt", EVENT_SYSTEM_FOREGROUND
        , "Ptr",  0
        , "Ptr",  g_pWinEventProc
        , "UInt", 0
        , "UInt", 0
        , "UInt", WINEVENT_OUTOFCONTEXT
        , "Ptr")

    g_hHookNameChange := DllCall("User32.dll\SetWinEventHook"
        , "UInt", EVENT_OBJECT_NAMECHANGE
        , "UInt", EVENT_OBJECT_NAMECHANGE
        , "Ptr",  0
        , "Ptr",  g_pWinEventProc
        , "UInt", 0
        , "UInt", 0
        , "UInt", WINEVENT_OUTOFCONTEXT
        , "Ptr")
}

WinEventProc(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    global h_Main, h_Edit
    global g_LastAutoApplyHwnd, g_LastAutoApplyTick, g_LastNameApplyTick

    if (!hwnd)
        return

    ; ignore our own windows
    if (h_Main && hwnd = h_Main)
        return
    if (h_Edit && hwnd = h_Edit)
        return

    ; Foreground change: apply to the new foreground window
    if (event = 0x0003) {
        now := A_TickCount
        if (hwnd = g_LastAutoApplyHwnd && (now - g_LastAutoApplyTick) < 250)
            return
        g_LastAutoApplyHwnd := hwnd
        g_LastAutoApplyTick := now

        TryAutoApplyForHwnd(hwnd)
        return
    }

    ; Title change: only apply if THIS hwnd is currently foreground, and idObject is the window itself.
    if (event = 0x800C) {
        ; Only care about the top-level window name changing.
        if (idObject != 0)  ; OBJID_WINDOW = 0
            return

        fg := DllCall("User32.dll\GetForegroundWindow", "Ptr")
        if (fg != hwnd)
            return

        now := A_TickCount
        ; A lot of apps fire multiple name-change events in a burst.
        if ((now - g_LastNameApplyTick) < 120)
            return
        g_LastNameApplyTick := now

        TryAutoApplyForHwnd(hwnd)
        return
    }
}

TryAutoApplyForHwnd(hwnd) {
    WinGetTitle, t, ahk_id %hwnd%
    WinGetClass, c, ahk_id %hwnd%
    sec := FindFirstMatchingRule(c, t)
    if (sec = "")
        return
    if (ApplyRuleSectionToHwnd(sec, hwnd))
        ZBeep()
}

HandleExit:
    global g_hHookForeground, g_hHookNameChange
    if (g_hHookForeground) {
        DllCall("User32.dll\UnhookWinEvent", "Ptr", g_hHookForeground)
        g_hHookForeground := 0
    }
    if (g_hHookNameChange) {
        DllCall("User32.dll\UnhookWinEvent", "Ptr", g_hHookNameChange)
        g_hHookNameChange := 0
    }
ExitApp
return
