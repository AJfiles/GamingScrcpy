param(
    [int]$Tab = 0,
    [string]$Out = "$PSScriptRoot\..\out\shots\tab.png",
    [switch]$Bottom,
    [string]$Exe = ''
)
# Capture one tab of the published launcher, selected by index.
#
# The screenshot tour has to be produced by the same walk the UIA contract uses:
# tab headers are localized and WPF keeps an unselected TabItem out of the
# automation tree, so a shot taken by clicking a header found by its English word
# only proves the English build. Index is the only stable key here.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/launcher_tab_shot.ps1 -Tab 3 -Bottom -Out out\shots\v5_tab_4_filters.png

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not $Exe) {
    foreach ($c in "$PSScriptRoot\..\dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe",
                   "$PSScriptRoot\..\launcher\GamingScrcpyLauncher.exe") {
        if (Test-Path $c) { $Exe = $c; break }
    }
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    Write-Output 'MISSING GamingScrcpyLauncher.exe (build tree or extracted package)'
    exit 1
}

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Shot {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$proc = Start-Process -FilePath $Exe -PassThru
try {
    $end = (Get-Date).AddSeconds(30); $wp = $null
    while ((Get-Date) -lt $end) {
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $wp = $p; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $wp) { Write-Output 'FAIL launcher window never appeared'; exit 1 }
    Start-Sleep -Milliseconds 1500

    $window = $AE::RootElement.FindFirst($TS::Children,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $wp.Id)))
    if (-not $window) { Write-Output 'FAIL automation element not found'; exit 1 }

    $tabs = $window.FindAll($TS::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::TabItem)))
    if ($tabs.Count -le $Tab) {
        Write-Output "FAIL only $($tabs.Count) tabs found, asked for index $Tab"; exit 1
    }
    $sel = $tabs[$Tab].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $sel.Select()
    Write-Output ("selected tab index {0} named '{1}'" -f $Tab, $tabs[$Tab].Current.Name)
    Start-Sleep -Milliseconds 800

    if ($Bottom) {
        # WPF exposes the ScrollViewer of a tab as a Pane carrying ScrollPattern;
        # jumping to 100% vertical proves the lowest block is really painted.
        $panes = $window.FindAll($TS::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Pane)))
        $n = 0
        foreach ($pane in $panes) {
            try {
                $sp = $pane.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
                if ($sp.Current.VerticallyScrollable) { $sp.SetScrollPercent(-1, 100); $n++ }
            } catch {}
        }
        Write-Output "scrolled $n vertical viewports to the bottom"
        Start-Sleep -Milliseconds 500
    }

    [Win32Shot]::SetForegroundWindow($wp.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 500
    $r = New-Object Win32Shot+RECT
    [Win32Shot]::GetWindowRect($wp.MainWindowHandle, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { Write-Output "FAIL bad window rect ${w}x${h}"; exit 1 }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    $dir = Split-Path -Parent $Out
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bmp.Save((Join-Path (Resolve-Path $dir) (Split-Path -Leaf $Out)),
              [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output "SAVED $Out ${w}x${h}"
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
