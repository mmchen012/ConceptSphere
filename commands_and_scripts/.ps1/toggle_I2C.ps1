# Find the I2C HID Device
$device = Get-PnpDevice | Where-Object { $_.FriendlyName -like "*I2C HID Device*" }

if ($device) {
    if ($device.Status -eq "OK") {
        Write-Host "Disabling device: $($device.InstanceId)"
        Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
        Start-Sleep -Seconds 2
    } else {
        Write-Host "Enabling device: $($device.InstanceId)"
        Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
        Start-Sleep -Seconds 2
    }
} else {
    Write-Host "I2C HID Device not found!"
}
