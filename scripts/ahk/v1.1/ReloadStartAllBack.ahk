; ReloadStartAllBack.ahk
; Ctrl + Alt + R → Fully restart Explorer-related shell processes

^!r::
    TrayTip, Reloading shell, Restarting Explorer and shell helpers..., 3, 1

    ; Kill Explorer and some shell experiences (safe, Windows will respawn missing bits)
    RunWait, taskkill /IM explorer.exe /F,, Hide
    RunWait, taskkill /IM ShellExperienceHost.exe /F,, Hide
    RunWait, taskkill /IM StartMenuExperienceHost.exe /F,, Hide

    Sleep, 1000

    ; Restart Explorer
    Run, explorer.exe

    SoundBeep, 750, 150
return
