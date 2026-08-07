# SuspendVM.ps1
# Suspends a VMware Workstation VM at logoff

$vmxPath = "D:\Virtual_Machines\Ubuntu24.04_EVA-1\Ubuntu24.04_EVA-1.vmx"
$vmrun = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"

try {
    & "$vmrun" suspend "$vmxPath" nogui
    Write-Output "VM suspended successfully."
} catch {
    Write-Output "Failed to suspend VM: $_"
}
