param(
    [int]$ProfileIndex = -1,
    [int]$Samples = 4,
    [int]$SampleGapMs = 12000,
    [string]$OutDir = 'out\bug_gray',
    [string]$Label = 'launcher_session'
)
# Reproduce the user's path, not a hand-written command line.
#
# v4 §1.2 could not reproduce the grey window: fifteen fork configurations driven
# straight from scrcpy.exe all mirrored the S23 Ultra fine (see BUILD_REPORT §5.1aq).
# What the user actually presses is the launcher's Mirror button, which builds its own
# argument list from the selected profile -- including the flags no CLI probe sent. So
# this harness drives the real packaged GUI through UI Automation, lets it start
# scrcpy, and measures the window THAT process created.
#
# Two things are recorded because both are what the report claims:
#   * the mirror window, sampled by tools/gray_probe.ps1 -AttachPid (mean/stdev/
#     hung/size, and the screenshot), and
#   * the launcher's own log panel, which mirrors scrcpy's stdout -- it holds the
#     exact argv line and any ERROR the client printed, so a failure names the flag
#     that caused it instead of blaming the launcher.
#
# Nothing here writes to the phone: it presses the same buttons the user presses,
# and scrcpy's own control channel is the only thing that touches the device.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/launcher_session_probe.ps1
#   powershell ... -File tools/launcher_session_probe.ps1 -ProfileIndex 0

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe = Join-Path $root 'dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe'
if (-not (Test-Path $exe)) { Write-Output "FAIL missing $exe"; exit 1 }
New-Item -ItemType Directory -Force -Path (Join-Path $root $OutDir) | Out-Null

$AE = [System.Windows.Automation.AutomationElement]
$Invoke = [System.Windows.Automation.InvokePattern]
$Select = [System.Windows.Automation.SelectionItemPattern]

function ById($scope, $id) {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    return $scope.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}
function Press($win, $id) {
    $el = ById $win $id
    if (-not $el) { return $false }
    try { ($el.GetCurrentPattern($Invoke::Pattern)).Invoke(); return $true } catch { return $false }
}
function Text($win, $id) {
    $el = ById $win $id
    if (-not $el) { return '' }
    return $el.Current.Name
}

$before = @((Get-Process scrcpy -ErrorAction SilentlyContinue).Id)
$proc = Start-Process -FilePath $exe -PassThru
$fail = 0
try {
    $end = (Get-Date).AddSeconds(25); $win = $null
    while ((Get-Date) -lt $end) {
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
            $win = $AE::FromHandle($p.MainWindowHandle); break
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $win) { Write-Output 'FAIL launcher window never appeared'; exit 1 }
    Start-Sleep -Milliseconds 2500

    if ($ProfileIndex -ge 0) {
        # Profiles live on the Advanced tab, and WPF does not realize a tab it has
        # not shown, so the tab has to be selected before the list exists.
        $tabs = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty,
                 [System.Windows.Automation.ControlType]::TabItem)))
        if ($tabs.Count -lt 7) { Write-Output "FAIL only $($tabs.Count) tabs, cannot reach Advanced" }
        else {
            ($tabs.Item($tabs.Count - 1).GetCurrentPattern($Select::Pattern)).Select()
            Start-Sleep -Milliseconds 800
            $list = ById $win 'ProfileList'
            if (-not $list) { Write-Output 'FAIL ProfileList not found on Advanced' }
            else {
                $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children,
                    [System.Windows.Automation.Condition]::TrueCondition)
                if ($ProfileIndex -ge $items.Count) {
                    Write-Output "FAIL profile index $ProfileIndex of $($items.Count)"
                } else {
                    ($items.Item($ProfileIndex).GetCurrentPattern($Select::Pattern)).Select()
                    Start-Sleep -Milliseconds 500
                }
            }
        }
    }

    if (-not (Press $win 'BtnMirror')) { Write-Output 'FAIL BtnMirror not invokable'; exit 1 }

    $child = $null
    $end = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $end) {
        $new = Get-Process scrcpy -ErrorAction SilentlyContinue |
               Where-Object { $before -notcontains $_.Id }
        if ($new) { $child = $new | Select-Object -First 1; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $child) {
        Write-Output 'FAIL scrcpy never started from the launcher'
        Write-Output "note  launcher log:"
        (Text $win 'TxtLog') -split "`n" | Select-Object -Last 12 | ForEach-Object { Write-Output "      $_" }
        exit 1
    }
    Write-Output "note  launcher started scrcpy pid=$($child.Id)"

    $probe = Join-Path $root 'tools\gray_probe.ps1'
    & $probe -Exe $exe -AttachPid $child.Id -Label "z_$Label" -OutDir (Join-Path $root $OutDir) `
             -Samples $Samples -SampleGapMs $SampleGapMs -WaitMs 20000 2>&1 |
        ForEach-Object { Write-Output $_ }

    $alive = Get-Process -Id $child.Id -ErrorAction SilentlyContinue
    Write-Output ("note  scrcpy alive after the samples: {0}" -f [bool]$alive)

    (Text $win 'TxtLog') | Out-File -Encoding utf8 (Join-Path $root (Join-Path $OutDir "$Label.launcherlog.txt"))
    $logtxt = Get-Content (Join-Path $root (Join-Path $OutDir "$Label.launcherlog.txt")) -Raw
    Write-Output '--- launcher log (tail) ---'
    ($logtxt -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 14) | ForEach-Object { Write-Output "      $_" }

    [void](Press $win 'BtnStop')
    Start-Sleep -Milliseconds 2500
    if (Get-Process -Id $child.Id -ErrorAction SilentlyContinue) {
        Write-Output 'NOTE BtnStop did not end the session (stop path itself hangs)'
        $fail = $fail + 1
    } else {
        Write-Output 'OK BtnStop ended the session cleanly'
    }
    if ($logtxt -match '(?m)^\s*(ERROR|error:)') {
        Write-Output 'NOTE the launcher log carries an ERROR line, see the tail above'
    }
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Get-Process scrcpy -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
if ($fail -eq 0) { Write-Output 'LAUNCHERSESSION OK' } else { Write-Output "LAUNCHERSESSION FAIL issues=$fail"; exit 1 }
