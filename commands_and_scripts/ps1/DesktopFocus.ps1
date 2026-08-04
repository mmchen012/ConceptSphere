Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
  public static void Foreground(IntPtr hWnd) {
    uint pid;
    uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint me = GetCurrentThreadId();
    AttachThreadInput(fg, me, true);
    ShowWindow(hWnd, 5); BringWindowToTop(hWnd); SetForegroundWindow(hWnd);
    AttachThreadInput(fg, me, false);
  }
}
"@

Add-Type -AssemblyName UIAutomationClient
$auto  = [System.Windows.Automation.AutomationElement]
$desc  = [System.Windows.Automation.TreeScope]::Descendants
$child = [System.Windows.Automation.TreeScope]::Children

$shell  = New-Object -ComObject Shell.Application
$before = @{}
foreach ($w in $shell.Windows()) { try { $before[[long]$w.HWND] = $true } catch {} }

& "$env:SystemRoot\explorer.exe" "shell:desktop"

# wait for the new Explorer window
$hwnd = 0
for ($i = 0; $i -lt 50 -and -not $hwnd; $i++) {
    Start-Sleep -Milliseconds 100
    foreach ($w in $shell.Windows()) {
        try { $h = [long]$w.HWND; if (-not $before.ContainsKey($h)) { $hwnd = $h; break } } catch {}
    }
}
if (-not $hwnd) { Write-Host "No new window found"; return }

# bring it foreground so focus changes are permitted
[Win]::Foreground([IntPtr]$hwnd)
Start-Sleep -Milliseconds 150

$win = $auto::FromHandle([IntPtr]$hwnd)
if (-not $win) { Write-Host "FromHandle failed"; return }

$listCond = New-Object System.Windows.Automation.PropertyCondition(
    $auto::ControlTypeProperty, [System.Windows.Automation.ControlType]::List)
$itemCond = New-Object System.Windows.Automation.PropertyCondition(
    $auto::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)

$first = $null
for ($i = 0; $i -lt 40 -and -not $first; $i++) {
    foreach ($list in $win.FindAll($desc, $listCond)) {
        $c = $list.FindFirst($child, $itemCond)
        if ($c) { $first = $c; break }
    }
    if (-not $first) { Start-Sleep -Milliseconds 100 }
}
if (-not $first) { Write-Host "Items list / first item not found"; return }

try { $first.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch { Write-Host "Select: $_" }
try { $first.SetFocus() } catch { Write-Host "SetFocus: $_" }
Write-Host ("Focused: " + $first.Current.Name)