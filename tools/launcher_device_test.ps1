# Drives the packaged launcher against a real device through UI Automation.
#
# The other launcher checks only assert the argument string and the control tree.
# This one is the end-to-end §3C test: the running GUI must actually list the
# connected device, start scrcpy from its own directory when Mirror is clicked,
# and stop it again -- which is also how the portable-server packaging bug
# (BUILD_REPORT.md 5.1l) would have been caught without any manual clicking.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/launcher_device_test.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe = Join-Path $root 'dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe'
if (-not (Test-Path $exe)) { Write-Output "MISSING $exe"; exit 1 }

$AE = [System.Windows.Automation.AutomationElement]
$Invoke = [System.Windows.Automation.InvokePattern]

function ById($win, $id) {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}

function Press($win, $id) {
    $el = ById $win $id
    if (-not $el) { return $false }
    $p = $el.GetCurrentPattern($Invoke::Pattern)
    $p.Invoke()
    return $true
}

# The launcher mirrors scrcpy's own stdout into its log panel, so the log holds
# both the argument line it launched with and the client's ERROR lines. Without
# it a failed mirror attempt can only say "no serial", which blames the launcher
# for a session that died on the device.
function Get-Log($win) {
    $el = ById $win 'TxtLog'
    if (-not $el) { return '' }
    $t = $el.Current.Name
    if ([string]::IsNullOrWhiteSpace($t)) {
        try { $t = $el.GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
        catch { $t = '' }
    }
    return $t
}

$proc = Start-Process -FilePath $exe -PassThru
$fail = 0

try {
    $end = (Get-Date).AddSeconds(30)
    $wp = $null
    while ((Get-Date) -lt $end) {
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $wp = $p; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $wp) { Write-Output 'FAIL launcher window never appeared'; exit 1 }
    $win = $AE::FromHandle($wp.MainWindowHandle)

    # device auto-detection on start-up: the badge counts what adb reported, and
    # no click is needed to see it
    $badge = ''
    $end = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $end) {
        $b = ById $win 'DeviceBadge'
        if ($b) { $badge = $b.Current.Name }
        if ($badge -match '[1-9]') { break }
        Start-Sleep -Milliseconds 500
    }
    # the serial the launcher will pass down, straight from the packaged adb
    $adb = Join-Path $root 'dist\GamingScrcpy\launcher\adb.exe'
    $serial = ''
    if (Test-Path $adb) {
        # guarded: a packaged adb that cannot talk to its server (missing
        # AdbWin*.dll, busy tunnel) prints no device line, and calling
        # ToString() on that null used to kill the whole script with a
        # PowerShell error instead of reporting a clean FAIL
        $line = @(& $adb devices 2>&1) | Select-String '\sdevice$' |
            Select-Object -First 1
        if ($line) { $serial = $line.ToString().Split()[0] }
    }
    if ($badge -notmatch '[1-9]' -or -not $serial) {
        Write-Output "RESULT detect badge='$badge' adbSerial='$serial'"
        Write-Output 'FAIL the launcher did not detect the connected device'
        $fail = 1
    } else {
        Write-Output "RESULT detect badge='$badge' serial=$serial"
    }

    # Mirror: the launcher must spawn its own scrcpy.exe and that process must
    # reach a live window (i.e. the server was found and the session started)
    $before = @(Get-Process scrcpy -ErrorAction SilentlyContinue | ForEach-Object Id)
    $child = $null
    $seen = @()
    $log = ''
    $launch = ''
    # Three tries, not one. On this Android 9 phone a fresh MediaCodec is refused
    # while the previous session's encoder is still being released, so scrcpy
    # dies before it creates a window: 5 of 6 back-to-back launcher sessions
    # ended in SurfaceEncoder.createMediaCodec, while the identical command line
    # started fine 75 s later and the same profile mirrors normally on Android 14.
    # That is the device, not the package, so the retry prints a RETRY line per
    # attempt and the FAIL below still fires when every attempt dies -- which is
    # what a missing scrcpy-server or a bad argument list does, with no
    # MediaCodec stack in the log.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not (Press $win 'BtnMirror')) {
            Write-Output 'FAIL BtnMirror not found'
            $fail = 1
            break
        }
        $end = (Get-Date).AddSeconds(35)
        while ((Get-Date) -lt $end) {
            $new = @(Get-Process scrcpy -ErrorAction SilentlyContinue |
                     Where-Object { $before -notcontains $_.Id })
            foreach ($n in $new) {
                if ($seen -notcontains $n.Id) { $seen += $n.Id }
                if ($n.MainWindowTitle -ne '') { $child = $n }
            }
            if ($child) { break }
            Start-Sleep -Milliseconds 300
        }
        if ($child) { break }
        $log = Get-Log $win
        $launch = ($log -split "`r?`n" | Select-String 'launching:' |
                  Select-Object -Last 1)
        [void](Press $win 'BtnStop')
        if ($attempt -lt 3) {
            Write-Output "RETRY $attempt of 3: no scrcpy window in 35 s, settling 15 s"
            Start-Sleep -Seconds 15
        }
    }
    if (-not $child -and $fail -eq 0) {
        # the corpse used to be reported as "started without the serial", which
        # blamed the launcher for a session the device refused
        $died = @($seen | Where-Object {
                     -not (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
        Write-Output ("FAIL mirror never showed a window (3 attempts; scrcpy pids " +
                      "seen: $($seen -join ','); exited before one appeared: " +
                      "$($died -join ','))")
        Write-Output "       launcher launched: ${launch:-'(no launching line)'}"
        (($log -split "`r?`n") | Select-Object -Last 22) |
            ForEach-Object { Write-Output "       log | $_" }
        $fail = 1
    }
    if ($child) {
        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($child.Id)").CommandLine
        Write-Output "RESULT mirror pid=$($child.Id) title='$($child.MainWindowTitle)'"
        # the selected device must be the one the launcher started scrcpy
        # against, otherwise a second phone on the hub would be mirrored. The
        # live cmdline is the evidence; the launcher's own launching line covers
        # the race where this child exits while WMI queries it. Both without the
        # serial means it really was dropped.
        $hasSerial = $cl -match [regex]::Escape("--serial=$serial")
        if (-not $hasSerial -and -not $launch) {
            $launch = (Get-Log $win) -split "`r?`n" |
                Select-String 'launching:' | Select-Object -Last 1
        }
        if (-not $hasSerial) {
            $hasSerial = "$launch" -match [regex]::Escape("--serial=$serial")
        }
        if ($serial -and -not $hasSerial) {
            Write-Output "RESULT args=--serial missing (expected $serial)"
            Write-Output "       cmdline=$cl"
            Write-Output "       launching line: ${launch:-'(none)'}"
            Write-Output 'FAIL scrcpy was started without the detected serial'
            $fail = 1
        } else {
            Write-Output "RESULT args=--serial=$serial present"
        }

        # Stop: the same button path a user presses at the end of a session
        [void](Press $win 'BtnStop')
        $end = (Get-Date).AddSeconds(20)
        $gone = $false
        while ((Get-Date) -lt $end) {
            if (-not (Get-Process -Id $child.Id -ErrorAction SilentlyContinue)) { $gone = $true; break }
            Start-Sleep -Milliseconds 300
        }
        if ($gone) { Write-Output 'RESULT stop scrcpy exited cleanly' }
        else {
            Write-Output 'FAIL Stop did not end the mirror'
            $fail = 1
        }
    }
} finally {
    Get-Process scrcpy -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Output 'OK' }
exit $fail
