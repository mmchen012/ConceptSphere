# Reset-Audio.ps1
# "Mini logoff" for Windows audio / per-app volume settings

# 0) Restart NVDA last-known instance cleanly

# Kill any running NVDA
Get-Process nvda -ErrorAction SilentlyContinue | Stop-Process -Force

# 1) Wipe per-app volume / routing cache
$paths = @(
    'HKCU:\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore',
    'HKCU:\Software\Microsoft\Multimedia\Audio\PolicyConfig\PropertyStore'
)

foreach ($p in $paths) {
    if (Test-Path $p) {
        Write-Host "Removing $p ..." -ForegroundColor Cyan
        Remove-Item $p -Recurse -Force
    }
}

# 2) Restart audio engine (Audio Device Graph Isolation)
Write-Host "Restarting audiodg.exe ..." -ForegroundColor Cyan
Get-Process audiodg -ErrorAction SilentlyContinue | Stop-Process -Force

Start-Sleep -Seconds 2  # brief pause while Windows restarts audiodg

# 3) Optional: restart Explorer (sometimes helps if shell hooks are involved)
Write-Host "Restarting explorer.exe ..." -ForegroundColor Cyan
Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process explorer.exe
Start-Process "C:\Program Files (x86)\NVDA\nvda.exe"

Write-Host "Audio reset complete. Try your beep() again." -ForegroundColor Green
