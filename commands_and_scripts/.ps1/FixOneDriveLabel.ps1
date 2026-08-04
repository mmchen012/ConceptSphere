# FixOneDriveLabel.ps1 — set the label once at logon. No loop, no SHChangeNotify.
$want = 'Accton'
$base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager'
$key = Get-ChildItem $base -EA 0 | Where-Object PSChildName -like 'OneDrive!*Business1*' | Select-Object -First 1
if ($key) {
    Set-ItemProperty -LiteralPath $key.PSPath -Name DisplayNameResource -Value $want -EA 0
}
