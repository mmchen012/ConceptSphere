' Initialize the Shell object
Set objShell = CreateObject("WScript.Shell")

' Define the full path to the registry value
strRegKey = "HKCU\Software\Microsoft\Windows\CurrentVersion\Run\GoogleDriveFS"

' Error handling: In case the key is already gone, the script won't crash
On Error Resume Next

' Delete the value
objShell.RegDelete strRegKey

' Clear error handling and exit
On Error GoTo 0
Set objShell = Nothing
