# FixOpenSSHFirewall.ps1
# Enforces SSH firewall inbound rule every minute

$ruleNameBuiltin = "OpenSSH-Server-In-TCP"
$ruleNameCustom  = "OpenSSH-Permanent"

# Try enabling the built-in rule
try {
    Enable-NetFirewallRule -DisplayName $ruleNameBuiltin -ErrorAction SilentlyContinue
}
catch {}

# Check if port 22 is allowed by any rule
$port22 = Get-NetFirewallPortFilter -Protocol TCP 2>$null |
          Where-Object { $_.LocalPort -eq 22 }

if (-not $port22) {
    # Create or update a custom persistent rule
    New-NetFirewallRule `
        -Name $ruleNameCustom `
        -DisplayName "OpenSSH Permanent Access" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 22 `
        -Action Allow `
        -ErrorAction SilentlyContinue
}

