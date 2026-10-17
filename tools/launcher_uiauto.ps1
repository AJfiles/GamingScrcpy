# Checks the published launcher through UI Automation.
#
# Two things this has to prove now that the UI is tabbed and localized:
#   1. every control the fork flags depend on is reachable -- WPF keeps an
#      unselected TabItem's content out of the tree, so the script selects each
#      tab first and then looks for the ids that live in it;
#   2. the language switch is real: a representative control is read before and
#      after flipping the language combo, and its text must actually change.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/launcher_uiauto.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe = Join-Path $root 'dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe'
if (-not (Test-Path $exe)) { Write-Output "MISSING $exe"; exit 1 }

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

function ById($window, $id) {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    return $window.FindFirst($TS::Descendants, $c)
}
function ByType($window, $type) {
    $c = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $type)
    return $window.FindAll($TS::Descendants, $c)
}

$proc = Start-Process -FilePath $exe -PassThru
$fail = 0
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

    $title = $window.Current.Name
    if ($title -match '\?\?\?') {
        Write-Output "FAIL localization table empty (title='$title')"; $fail++
    } else {
        Write-Output "PASS window title localized ('$title')"
    }

    # Index -> expected controls, in XAML order. Keyed by index on purpose: the
    # headers are localized, so looking a tab up by the English word only works
    # in the language the test was written in -- it failed for every tab but
    # 'Control' once the launcher remembered Spanish.
    $plan = @(
        @{ key='TabQuick';        ids=@('BtnMirror','BtnMirrorRecord','BtnRecordOnly',
                                        'BtnStop','TxtDeviceModel','TxtDeviceBattery',
                                        'TxtDeviceTemp','TxtPerfLatency','TxtPerfFps',
                                        'TxtPerfVideo','TxtPerfAudio') }
        @{ key='TabCapture';      ids=@('CboVideoCodec','CboBitrate','LblBitrate',
                                        'CboMaxFps','LblMaxFps','CboAudioCodec',
                                        'CboAudioBitrate','LblAudioBitrate','CboHwdec',
                                        'LblCodecNote','CboEncoderPreset') }
        @{ key='TabPresentation'; ids=@('CboDriver','CboUpscale','CboWindowFilter',
                                        'CboHostPreset','CboRenderFit','CboVideoBuffer',
                                        'LblVideoBuffer','CboAudioOutBuffer',
                                        'LblAudioOutBuffer','ChkLowLatency',
                                        'ChkBorderless','ChkAlwaysOnTop','ChkMipmaps',
                                        'ChkTouchViz','CboOsd','SldCursorHide',
                                        'LblCursorHide') }
        @{ key='TabFilters';      ids=@('ChkFxSharp','ChkFxNight','ChkFxSat','SldSharp',
                                        'LblSharp','SldNight','LblNight','SldSat',
                                        'LblSat') }
        @{ key='TabRecorder';     ids=@('CboContainer','TxtRecordPath','TxtFrameBridge',
                                        'TxtBridgeScale','CboBridgeFilter',
                                        'TxtAudioBridge','TxtAudioPcm','ChkPcmMute',
                                        'TxtExtraArgs') }
        @{ key='TabControl';      ids=@('CboKeyboard','CboMouse','CboGamepad',
                                        'TxtMouseBindings','KeymapList','TxtKeymapHint') }
        @{ key='TabAdvanced';     ids=@('ProfileList','TxtProfileName') }
    )

    # header buttons live outside the TabControl, so they are always in the tree
    foreach ($id in @('BtnRefresh','BtnWireless','BtnPair','BtnConnect','CboLanguage')) {
        if (ById $window $id) { Write-Output "PASS $id (header)" }
        else { Write-Output "FAIL $id missing from the header"; $fail++ }
    }

    $tabs = ByType $window $CT::TabItem
    if ($tabs.Count -ne $plan.Count) {
        Write-Output "FAIL expected $($plan.Count) tabs, found $($tabs.Count)"; $fail++
    }
    $stop = [Math]::Min($tabs.Count, $plan.Count)
    for ($i = 0; $i -lt $stop; $i++) {
        $entry = $plan[$i]
        $name = $tabs[$i].Current.Name
        # a header still showing its resource key means DynamicResource never hit
        if (-not $name -or $name -eq $entry.key -or $name -match '\?\?\?') {
            Write-Output "FAIL tab $i ('$($entry.key)') header not localized (name='$name')"
            $fail++
        }
        try {
            ($tabs[$i].GetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        } catch { Write-Output "FAIL tab '$($entry.key)' unselectable"; $fail++; continue }
        Start-Sleep -Milliseconds 400
        foreach ($id in $entry.ids) {
            if (ById $window $id) { Write-Output "PASS $id ($($entry.key))" }
            else { Write-Output "FAIL $id missing under $($entry.key)"; $fail++ }
        }
    }

    # the language test needs a control that lives in the first tab, so go back
    # to it before reading anything
    if ($tabs.Count -gt 0) {
        $tabs[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Milliseconds 400
    }

    $langBox = ById $window 'CboLanguage'
    $mirror = ById $window 'BtnMirror'
    if (-not $langBox -or -not $mirror) {
        Write-Output 'FAIL language selector or BtnMirror not present'; $fail++
    } else {
        $before = (ById $window 'BtnMirror').Current.Name
        try {
        ($langBox.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
        Start-Sleep -Milliseconds 500
    } catch {}
        $items = ByType $langBox $CT::ListItem
        if ($items.Count -lt 2) {
            Write-Output 'FAIL language selector has fewer than two items'; $fail++
        } else {
            $pick = if ($before -eq 'Espanol' -or $before -match '^[A-Z][a-z]+ ') { 0 } else { 1 }
            $items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            Start-Sleep -Milliseconds 800
            $mid = (ById $window 'BtnMirror').Current.Name
            $items[1].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            Start-Sleep -Milliseconds 800
            $after = (ById $window 'BtnMirror').Current.Name
            if ($mid -and $after -and $mid -ne $after -and $after -notmatch '\?\?\?') {
                Write-Output "PASS hot language switch: '$mid' -> '$after'"
            } else {
                Write-Output "FAIL language switch did not relocalize ('$mid' -> '$after')"; $fail++
            }
            if (-not (ById $window 'TxtCommand')) {
                Write-Output 'FAIL command preview missing after the switch'; $fail++
            }
        }
    }

    if ($fail) { Write-Output "UIAUTO FAIL ($fail)"; exit 1 }
    Write-Output 'UIAUTO OK'
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
