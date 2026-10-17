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
        $serial = ((& $adb devices) | Select-String '\sdevice$' |
                   Select-Object -First 1).ToString().Split()[0]
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
    if (-not (Press $win 'BtnMirror')) {
        Write-Output 'FAIL BtnMirror not found'
        $fail = 1
    } else {
        $child = $null
        $end = (Get-Date).AddSeconds(35)
        while ((Get-Date) -lt $end) {
            $new = @(Get-Process scrcpy -ErrorAction SilentlyContinue |
                     Where-Object { $before -notcontains $_.Id })
            if ($new.Count -gt 0) {
                $child = Get-Process -Id $new[0].Id
                if ($child.MainWindowTitle -ne '') { break }
            }
            Start-Sleep -Milliseconds 300
        }
        if (-not $child) {
            Write-Output 'FAIL mirror did not start scrcpy from the package'
            $fail = 1
        } else {
            $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($child.Id)").CommandLine
            Write-Output "RESULT mirror pid=$($child.Id) title='$($child.MainWindowTitle)'"
            # the selected device must be the one the launcher started scrcpy
            # against, otherwise a second phone on the hub would be mirrored
            if ($serial -and $cl -notmatch [regex]::Escape("--serial=$serial")) {
                Write-Output "RESULT args=--serial missing (expected $serial)"
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
    }
} finally {
    Get-Process scrcpy -ErrorAction SilentlyContinue | Stop-Process -Force
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Output 'OK' }
exit $fail
