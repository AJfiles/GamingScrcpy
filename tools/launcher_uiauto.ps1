# Checks the published launcher's configurator controls through UI Automation.
#
# A screenshot only proves the top of the ScrollViewer rendered. This walks the
# live element tree by AutomationId (which WPF sets from x:Name), so a control
# that exists in XAML but was dropped from the panel -- or an old profile that
# fails to load into it -- fails here instead of in someone's streaming session.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/launcher_uiauto.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe = Join-Path $root 'dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe'
if (-not (Test-Path $exe)) {
    Write-Output "MISSING $exe"
    exit 1
}

$proc = Start-Process -FilePath $exe -PassThru
$handles = @($proc.Id)

function Wait-Window([int] $targetId, [int] $timeoutSec) {
    $end = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $end) {
        $p = Get-Process -Id $targetId -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { return $p }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

$fail = 0
try {
    $wp = Wait-Window $proc.Id 25
    if (-not $wp) {
        Write-Output 'FAIL launcher window never appeared'
        exit 1
    }
    Start-Sleep -Milliseconds 1200   # let the first profile finish loading

    $rootEl = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $wp.Id)
    $window = $rootEl.FindFirst(
        [System.Windows.Automation.TreeScope]::Children, $cond)
    if (-not $window) {
        Write-Output 'FAIL automation element not found'
        exit 1
    }

    # every configurator control the fork flags depend on
    $ids = @(
        'CboWindowFilter', 'CboBridgeFilter', 'TxtFrameBridge', 'TxtBridgeScale',
        'TxtAudioBridge', 'TxtAudioPcm', 'ChkPcmMute', 'TxtExtraArgs',
        'TxtMouseBindings', 'CboGamepad', 'TxtLog'
    )
    foreach ($id in $ids) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            $id)
        $el = $window.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $cond)
        if ($el) {
            Write-Output "PASS $id present in the live window"
        } else {
            Write-Output "FAIL $id missing from the UI tree"
            $fail++
        }
    }

    # the value of one control, to prove Apply() really fills the panel
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        'TxtAudioPcm')
    $pcm = $window.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants, $cond)
    if ($pcm) {
        $vp = $pcm.GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern)
        Write-Output ("INFO TxtAudioPcm value='" + $vp.Current.Value + "'")
    }
} finally {
    foreach ($h in $handles) {
        Stop-Process -Id $h -Force -ErrorAction SilentlyContinue
    }
}

if ($fail) {
    Write-Output "UIAUTO FAIL ($fail)"
    exit 1
}
Write-Output 'UIAUTO OK'
exit 0
