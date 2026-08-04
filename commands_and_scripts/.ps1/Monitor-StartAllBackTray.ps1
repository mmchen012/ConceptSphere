# Monitor-StartAllBackTray.ps1
# Monitors the system tray via UI Automation and, if it appears "broken"
# (no tray icons), restarts Explorer to force StartAllBack to reinject.

# ===================== CONFIG =====================
# How often to poll (in seconds)
$pollInterval  = 3

# How many consecutive failures before we take action
$maxFailures   = 1
# ==================================================

Write-Host "StartAllBack tray monitor starting..." -ForegroundColor Cyan
Write-Host "  Poll interval: $pollInterval sec"
Write-Host "  Failures before restart: $maxFailures"
Write-Host ""

# Load UI Automation assemblies
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes | Out-Null

# Convenience aliases
$TreeScope      = [System.Windows.Automation.TreeScope]
$AutomationElem = [System.Windows.Automation.AutomationElement]
$ControlType    = [System.Windows.Automation.ControlType]
$Condition      = [System.Windows.Automation.Condition]
$PropertyCond   = [System.Windows.Automation.PropertyCondition]

function Get-TaskbarElement {
    # Find the Shell_TrayWnd top-level window (taskbar)
    $root = $AutomationElem::RootElement

    $classCond = New-Object $PropertyCond (
        $AutomationElem::ClassNameProperty,
        'Shell_TrayWnd'
    )

    $taskbar = $root.FindFirst($TreeScope::Children, $classCond)
    return $taskbar
}

function Get-TrayAreaElement {
    param(
        [Parameter(Mandatory=$true)]
        $TaskbarElement
    )

    if (-not $TaskbarElement) {
        return $null
    }

    # 1) Try something literally named "Notification area"
    $nameCond = New-Object $PropertyCond (
        $AutomationElem::NameProperty,
        'Notification area'
    )

    $tray = $TaskbarElement.FindFirst($TreeScope::Descendants, $nameCond)
    if ($tray) { return $tray }

    # 2) Fallback: search descendants whose Name contains "notification"
    $trueCond = $Condition::TrueCondition
    $allDesc  = $TaskbarElement.FindAll($TreeScope::Descendants, $trueCond)

    for ($i = 0; $i -lt $allDesc.Count; $i++) {
        $elem = $allDesc.Item($i)
        try {
            $name  = $elem.Current.Name
        } catch {
            continue
        }

        if ($name -and ($name -like '*notification*')) {
            return $elem
        }
    }

    return $null
}

function Test-SystemTrayOk {
    try {
        $taskbar = Get-TaskbarElement
        if (-not $taskbar) {
            Write-Host "[WARN] Taskbar AutomationElement not found." -ForegroundColor Yellow
            return $false
        }

        $tray = Get-TrayAreaElement -TaskbarElement $taskbar
        if (-not $tray) {
            Write-Host "[WARN] Tray area AutomationElement not found." -ForegroundColor Yellow
            return $false
        }

        # Look for any buttons (tray icons, chevron, etc.)
        $btnCond = New-Object $PropertyCond (
            $AutomationElem::ControlTypeProperty,
            $ControlType::Button
        )

        $buttons = $tray.FindAll($TreeScope::Descendants, $btnCond)
        $count   = $buttons.Count

        Write-Host "[INFO] Tray button count (UIA): $count"

        if ($count -gt 0) {
            return $true
        } else {
            return $false
        }
    }
    catch {
        Write-Host "[ERROR] Exception while checking tray: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Restart-ExplorerAndStartAllBack {
    Write-Host "[ACTION] Restarting Explorer (this also reloads StartAllBack)..." -ForegroundColor Magenta

    # Kill all explorer processes
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2

    # Start Explorer again
    Start-Process explorer.exe | Out-Null
    Write-Host "[ACTION] Explorer restarted." -ForegroundColor Green
}

# ===================== MAIN LOOP =====================
$failureCount = 0

while ($true) {
    $ok = Test-SystemTrayOk

    if ($ok) {
        if ($failureCount -gt 0) {
            Write-Host "[INFO] Tray looks ok again; resetting failure counter." -ForegroundColor Green
        }
        $failureCount = 0
    }
    else {
        $failureCount++
        Write-Host "[WARN] Tray appears broken; failure $failureCount of $maxFailures." -ForegroundColor Yellow

        if ($failureCount -ge $maxFailures) {
            Restart-ExplorerAndStartAllBack
            $failureCount = 0
            # Give Explorer & StartAllBack a few seconds to reinject and rebuild UIA tree
            Start-Sleep -Seconds 15
        }
    }

    Start-Sleep -Seconds $pollInterval
}
