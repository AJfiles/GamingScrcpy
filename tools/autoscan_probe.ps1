param(
    [string]$Exe = '',
    [int]$Seconds = 24,
    [int]$MinChildren = 3
)
# Counts the adb.exe children the launcher starts while it is in the foreground.
#
# The 3 s auto-scan (v3 §6) is deliberately invisible: an unchanged device list
# must not move the user's selection, must not disturb a live mirror and must not
# fill the run log. What it cannot be is unmeasured, so this probe counts the only
# external trace it leaves -- one short-lived adb process per tick. Counting
# starts 1.5 s after the window appears, so the startup refresh is already over
# and cannot be mistaken for a tick.
#
# The count is a floor, not a rate: a child is only seen if it is alive when the
# 200 ms WMI sample runs, and `adb devices` can be born and gone inside one
# sample -- 12 s reported 2 of the ~4 expected. The window is therefore 24 s
# (8 ticks) against a threshold of 3, and the build without the timer reported 0
# in the same window. The separation is the assertion, not the exact rate.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/autoscan_probe.ps1
#   powershell ... -File tools/autoscan_probe.ps1 -Exe out\pkg\launcher\GamingScrcpyLauncher.exe

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Poll {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Exe) {
    foreach ($c in (Join-Path $root 'dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe'),
                   (Join-Path $root 'launcher\GamingScrcpyLauncher.exe')) {
        if (Test-Path $c) { $Exe = $c; break }
    }
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    Write-Output 'FAIL launcher not found (build tree or extracted package)'
    exit 1
}

$proc = Start-Process -FilePath $Exe -PassThru
try {
    $end = (Get-Date).AddSeconds(25); $wp = $null
    while ((Get-Date) -lt $end) {
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $wp = $p; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $wp) { Write-Output 'FAIL launcher window never appeared'; exit 1 }
    Start-Sleep -Milliseconds 1500

    [Win32Poll]::SetForegroundWindow($wp.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 300
    $foreground = [Win32Poll]::GetForegroundWindow() -eq $wp.MainWindowHandle

    $seen = @{}
    $stop = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $stop) {
        try {
            foreach ($c in Get-CimInstance -ClassName Win32_Process `
                          -Filter "ParentProcessId=$($proc.Id)" -ErrorAction SilentlyContinue) {
                if ($c.Name -eq 'adb.exe') { $seen[[int]$c.ProcessId] = $true }
            }
        } catch { }
        Start-Sleep -Milliseconds 200
    }

    $count = $seen.Count
    Write-Output ("note  {0} adb children in {1}s, window foreground={2}" -f $count, $Seconds, $foreground)
    if ($count -ge $MinChildren) {
        Write-Output "OK auto-scan polled repeatedly: $count adb children (threshold $MinChildren)"
    } else {
        Write-Output "FAIL only $count adb children in ${Seconds}s: the timer is not firing (threshold $MinChildren)"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        exit 1
    }
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
Write-Output 'AUTOSCAN OK'
