# Get the current status of the firewall for all profiles
$firewallStatus = Get-NetFirewallProfile | Select-Object Name, Enabled

# Toggle firewall based on the current status
foreach ($profile in $firewallStatus) {
    if ($profile.Enabled -eq $true) {
        Write-Host "Disabling firewall for $($profile.Name) profile."
        Set-NetFirewallProfile -Name $profile.Name -Enabled False
        Start-Sleep -Seconds 2
    } else {
        Write-Host "Enabling firewall for $($profile.Name) profile."
        Set-NetFirewallProfile -Name $profile.Name -Enabled True
        Start-Sleep -Seconds 2
    }
}
