# Does --game-borderless-fullscreen produce the window it says it produced?
#
# The client logs "Borderless fullscreen on (WxH)" as soon as it has asked SDL
# for the geometry, so the log cannot be the verdict: the only witness is the
# window Windows actually holds. This harness reads GWL_STYLE and GetWindowRect
# through tools/window_style_probe.ps1 and runs the same measurement without the
# flag as a control, so a probe that cannot tell the two apart cannot pass.
#
# What the two arms actually differ in, measured 2026-10-18 on a 1366x768
# desktop with an S23 Ultra: with the flag WS_POPUP is set and without it it is
# not, so the borderless half of the flag works; neither arm covers the work
# area, so the fullscreen half is what is missing. Both are asserted.
#
# Exits 0 when the flag arm is a popup covering the work area and the control is
# neither, 1 when it is not, 2 (SKIP) when no device is attached.
param(
    [string] $Exe = '',
    [int] $Seconds = 14,
    [string] $Adb = ''
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Exe) {
    $Exe = Join-Path $here '..\dist\GamingScrcpy\scrcpy\scrcpy.exe'
}
$devices = @()
if ($Adb) {
    $devices = & $Adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' }
}
if ($devices.Count -eq 0) {
    'BORDERLESS SKIP no device attached (the flag needs a real stream to resize against)'
    exit 2
}

Add-Type -AssemblyName System.Windows.Forms
$wa = [System.Windows.Forms.SystemInformation]::WorkingArea
"work area = $($wa.Width)x$($wa.Height)+$($wa.X)+$($wa.Y)"

function Get-WindowState([string[]] $clientArgs) {
    $err = New-TemporaryFile
    $p = Start-Process -FilePath $Exe -ArgumentList $clientArgs -PassThru `
        -RedirectStandardError $err.FullName -RedirectStandardOutput "$($err.FullName).out"
    Start-Sleep -Seconds ([Math]::Max(3, [int] ($Seconds * 0.45)))
    $probe = 'RESULT window NO VISIBLE WINDOW pid-exited-early'
    if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) {
        $probe = (& (Join-Path $here 'window_style_probe.ps1') -Pid32 $p.Id) -join ' '
    }
    $p.WaitForExit()          # the client buffers stderr: read it only once closed
    $lines = @(Get-Content $err.FullName | Where-Object { $_.Trim() -ne '' })
    Remove-Item $err.FullName, "$($err.FullName).out" -ErrorAction SilentlyContinue
    $rect = $null
    if ($probe -match 'rect\s+(\d+)x(\d+)\+(\d+)\+(\d+)') {
        $rect = [pscustomobject]@{ W = [int] $Matches[1]; H = [int] $Matches[2] }
    }
    [pscustomobject]@{
        Probe  = $probe
        Rect   = $rect
        Popup  = ($probe -match 'popup=1')
        Client = ($lines -join ' ~ ')
    }
}

$issues = 0
function Note([string] $m) { "note  $m" }
function Bad([string] $m) { $script:issues++; "FAIL  $m" }

$flag = Get-WindowState @('--game-borderless-fullscreen', '--no-audio', "--time-limit=$Seconds")
$ctrl = Get-WindowState @('--no-audio', "--time-limit=$Seconds")

Note "with flag : $($flag.Probe)"
Note "control   : $($ctrl.Probe)"
Note "client log: $(if ($flag.Client) { $flag.Client } else { '(nothing captured)' })"

if (-not $flag.Rect) { Bad 'the flag arm produced no measurable window' }
if (-not $ctrl.Rect) { Bad 'the control arm produced no measurable window, so the probe is blind' }

# the borderless half: WS_POPUP is what removes the frame, and it must be the
# thing that differs, not a caption bit that a borderless window can still carry
if ($flag.Popup -and -not $ctrl.Popup) {
    Note 'borderless: the flag arm is a popup window and the control is not'
} elseif (-not $flag.Popup) {
    Bad 'the flag arm is not a popup window: SDL never applied the borderless style'
} else {
    Bad 'the control is a popup too, so popup=1 proves nothing about the flag'
}

# the fullscreen half: the window must cover the work area, which is what the
# flag promises and what upstream's fit-to-content resize destroys
$minW = [int] ($wa.Width * 0.98)
$minH = [int] ($wa.Height * 0.98)
if ($flag.Rect -and $flag.Rect.W -ge $minW -and $flag.Rect.H -ge $minH) {
    Note "geometry: the flag arm covers the work area ($($flag.Rect.W)x$($flag.Rect.H))"
} elseif ($flag.Rect) {
    Bad "the flag arm is $($flag.Rect.W)x$($flag.Rect.H), not the work area $($wa.Width)x$($wa.Height)"
}
if ($ctrl.Rect -and $ctrl.Rect.W -ge $minW -and $ctrl.Rect.H -ge $minH) {
    Bad 'the control fills the work area too, so covering it proves nothing about the flag'
}

if ($issues -eq 0) {
    "BORDERLESS OK the flag is the window state: popup, $($flag.Rect.W)x$($flag.Rect.H) of $($wa.Width)x$($wa.Height)"
    exit 0
}
"BORDERLESS FAIL issues=$issues  (open defect: BUILD_REPORT.md section 5.1b5, task 20)"
exit 1
