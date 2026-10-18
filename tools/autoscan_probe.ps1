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
# It SUBSCRIBES to process starts (Win32_ProcessStartTrace) rather than polling
# Win32_Process, because polling was proven to lose ticks: from the extracted
# package the same build that reported 5 children inside the gate reported
# `1 ... window foreground=True` here -- once the adb server is warm, each
# `adb devices` is born and gone inside the 200 ms sample interval, so the count
# became a lottery. An event queue cannot miss a start, which is what makes the
# threshold mean what it says. If the subscription is unavailable the probe still
# runs, but says so: instrument=poll is a warning that the number is a floor
# again, never a silent downgrade.
#
# The foreground is re-asserted each second because the app only polls while its
# window is active, and another harness can steal it mid-run.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/autoscan_probe.ps1
#   powershell ... -File tools/autoscan_probe.ps1 -Exe out\pkg\launcher\GamingScrcpyLauncher.exe

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Management
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

    $seen = @{}
    $stop = (Get-Date).AddSeconds($Seconds)
    $instrument = 'event'

    $watcher = $null
    try {
        $watcher = New-Object System.Management.ManagementEventWatcher(
            'SELECT * FROM Win32_ProcessStartTrace')
        $watcher.Options.Timeout = [TimeSpan]::FromMilliseconds(900)
        $watcher.Start()
    } catch {
        $instrument = 'poll'
        Write-Output "note  process-start trace unavailable ($($_.Exception.Message)); falling back to sampling"
    }

    $foreground = $false
    while ((Get-Date) -lt $stop) {
        if ((Get-Date) -gt $nextAssert -or -not $nextAssert) {
            [Win32Poll]::SetForegroundWindow($wp.MainWindowHandle) | Out-Null
            $nextAssert = (Get-Date).AddSeconds(1)
        }
        if ($instrument -eq 'event') {
            try {
                $ev = $watcher.WaitForNextEvent()
                if ([int]$ev['ParentProcessID'] -eq $proc.Id -and
                    $ev['ProcessName'] -eq 'adb.exe') {
                    $seen[[int]$ev['ProcessID']] = $true
                }
            } catch [System.Management.ManagementException] {
                # Options.Timeout: nothing started in this slice, keep waiting.
            }
        } else {
            foreach ($c in Get-CimInstance -ClassName Win32_Process `
                          -Filter "ParentProcessId=$($proc.Id)" -ErrorAction SilentlyContinue) {
                if ($c.Name -eq 'adb.exe') { $seen[[int]$c.ProcessId] = $true }
            }
            Start-Sleep -Milliseconds 200
        }
    }
    if ($watcher) { $watcher.Stop() }
    $foreground = [Win32Poll]::GetForegroundWindow() -eq $wp.MainWindowHandle

    $count = $seen.Count
    Write-Output ("note  {0} adb children in {1}s via {2}-subscription, window foreground={3}" -f
        $count, $Seconds, $instrument, $foreground)
    if ($count -ge $MinChildren) {
        Write-Output "OK auto-scan polled repeatedly: $count adb children (threshold $MinChildren)"
    } else {
        Write-Output "FAIL only $count adb children in ${Seconds}s: the timer is not firing (threshold $MinChildren, instrument=$instrument)"
        exit 1
    }
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
Write-Output 'AUTOSCAN OK'
