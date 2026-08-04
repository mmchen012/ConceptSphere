# --- Config ---
$vmxPath = "D:\Virtual_Machines\Ubuntu-24.04_P12583-NB\Ubuntu-24.04_P12583-NB.vmx"
$vmrun = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"

# Function: Check VM power state
function Get-VMState {
    $output = & $vmrun list | Out-String
    if ($output -match [regex]::Escape($vmxPath)) {
        return "running"
    } else {
        return "stopped"
    }
}

Write-Host "Suspending VM: $vmxPath ..."
& $vmrun suspend "$vmxPath" nogui

# Wait until VM is no longer running
Write-Host "Waiting for VM to suspend..."
while ((Get-VMState) -eq "running") {
    Start-Sleep -Seconds 2
}

Write-Host "VM is suspended."

# Now exit NVDA
Write-Host "Closing NVDA..."
$nvda = Get-Process nvda -ErrorAction SilentlyContinue
if ($nvda) {
    # Try graceful exit first
    Stop-Process -Id $nvda.Id -Force
    Write-Host "NVDA exited."
} else {
    Write-Host "NVDA not running."
}
