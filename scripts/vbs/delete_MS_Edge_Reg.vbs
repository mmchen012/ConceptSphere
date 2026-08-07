' Initialize the Shell object
Set objShell = CreateObject("WScript.Shell")

' Define the full path to the registry value
strRegKey = "HKCU\Software\Microsoft\Windows\CurrentVersion\Run\MicrosoftEdgeAutoLaunch_41789463AE07A8DF7237E1D0AC935C3D"

' Error handling: In case the key is already gone, the script won't crash
On Error Resume Next

' Delete the value
objShell.RegDelete strRegKey

' Clear error handling and exit
On Error GoTo 0
Set objShell = Nothing
