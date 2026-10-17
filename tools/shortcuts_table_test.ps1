# v3 section 3.3 gate helper, part 2: the shortcut list as the user sees it.
#
# Runs against the packaged launcher and asserts, in Spanish and in English, that
# every rendered row has a key combination, an action and a description, that the
# three columns are three separate places (measured rectangles), and that the
# panel toggles: absent before the button, present after it, absent again after a
# second click. The table's own integrity -- no repeated combination inside a
# category, no row without a Loc key behind it -- is the launcher's
# --validate-shortcuts mode, which verify_all.sh runs from bash: the launcher is a
# WinExe, so PowerShell would capture none of its stdout.
#
# The list lives inside the main window. It used to be its own Window and UIA could
# not see it: after invoking the button the process still owned exactly one
# enumerable top-level window, 'Gaming Scrcpy Launcher', so every read of the
# separate list depended on a window the test could not find. In-panel is also what
# the user asked for (a section of the page, not a dialog).
#
# Language is set through the file the launcher persists it in, so each pass starts
# a process that is already localized. Driving the language combo and restarting
# was tried first and only opened the list in some runs.
param(
    [string]$Launcher = "",
    [int]$MinRows = 20
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Launcher) {
    $Launcher = Join-Path $root 'dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe'
    if (-not (Test-Path $Launcher)) {
        # an extracted package has no build tree: the launcher sits one level up
        $Launcher = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) `
                              '..\launcher\GamingScrcpyLauncher.exe'
    }
}
if (-not (Test-Path $Launcher)) { Write-Output "FAIL launcher not found at $Launcher"; exit 1 }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$uia = [System.Windows.Automation.AutomationElement]::RootElement
$script:Issues = 0
$langFile = Join-Path (Join-Path $env:APPDATA 'GamingScrcpy') 'language.txt'
$saved = $null
if (Test-Path $langFile) { $saved = (Get-Content $langFile -Raw).Trim() }

# Everything prints through Say(): a function that emits with Write-Output also
# *returns* those lines, which is what turned "$x += Check-List" into array math.
function Say([string]$line) { [Console]::WriteLine($line) }

function Find-Window([int]$procId) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    return $uia.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
}

function ById($scope, $id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    return $scope.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Text-Of($el) {
    if (-not $el) { return '' }
    $n = $el.Current.Name
    if ($n) { return $n }
    return $el.Current.Value
}

function Invoke-Btn($win, [string]$id, [string]$label) {
    $btn = ById $win $id
    if (-not $btn) { Say "FAIL $id missing ($label)"; return $false }
    try {
        $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    } catch { Say "FAIL $id not invokable ($label): $_"; return $false }
    return $true
}

# The panel is Collapsed until asked for, so Sc1Key is the row that proves whether
# it is on screen. Collapsed WPF elements leave the UIA tree entirely.
function Wait-Rows([int]$procId, [int]$seconds, [bool]$want) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $w = Find-Window $procId
        if ($w) {
            $r = [bool](ById $w 'Sc1Key')
            if ($r -eq $want) { return $w }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Invoke-Pass([string]$code, [string]$label) {
    Set-Content -Path $langFile -Value $code -NoNewline -Encoding ascii
    $proc = Start-Process -FilePath $Launcher -PassThru
    $win = Wait-Rows $proc.Id 30 $false
    if (-not $win) {
        Say "FAIL launcher window never appeared ($label)"; $script:Issues++
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        return
    }
    Start-Sleep -Seconds 2
    $win = Find-Window $proc.Id

    if (-not (Invoke-Btn $win 'BtnShortcuts' $label)) {
        $script:Issues++
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        return
    }
    $opened = Wait-Rows $proc.Id 15 $true
    if (-not $opened) {
        Say "FAIL the shortcuts panel did not open ($label)"
        $script:Issues++
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        return
    }
    Say "OK the panel opens from its button ($label)"

    $count = 0
    $bad = 0
    for ($i = 1; $i -le 80; $i++) {
        $key = ById $win ("Sc{0}Key" -f $i)
        if (-not $key) { break }
        $count++
        $act = ById $win ("Sc{0}Act" -f $i)
        $desc = ById $win ("Sc{0}Desc" -f $i)
        foreach ($cell in @($key, $act, $desc)) {
            if (-not $cell) { Say "FAIL row $i is missing a cell ($label)"; $bad++; continue }
            if ([string]::IsNullOrWhiteSpace((Text-Of $cell))) { Say "FAIL row $i has an empty cell ($label)"; $bad++ }
        }
        if (-not $act -or -not $desc) { continue }
        # the three columns have to be three places, not one run-on line: the same
        # measurement caught the header bug in directive section 2
        $kb = $key.Current.BoundingRectangle
        $ab = $act.Current.BoundingRectangle
        $db = $desc.Current.BoundingRectangle
        if ($kb.Width -lt 24) {
            Say ("FAIL row {0} combination text is only {1} px wide ({2})" -f $i, [math]::Round($kb.Width), $label)
            $bad++
        }
        if (($ab.X - $kb.X) -lt 120) {
            Say ("FAIL row {0} action starts only {1} px after the combination ({2})" -f $i,
                [math]::Round($ab.X - $kb.X), $label)
            $bad++
        }
        if ($db.Width -lt 200 -or ($db.X - $ab.X) -lt 40) {
            Say ("FAIL row {0} description column is only {1} px wide ({2})" -f $i,
                [math]::Round($db.Width), $label)
            $bad++
        }
        # a keycap is one line of text. It measured 660 px tall when the card sat in
        # the Quick tab's fixed 280 px column and the description star collapsed into
        # a wrapped ribbon, which stretched every cell in the row with it.
        if ($kb.Height -gt 48) {
            Say ("FAIL row {0} keycap is {1} px tall, expected one line ({2})" -f $i,
                [math]::Round($kb.Height), $label)
            $bad++
        }
    }
    if ($count -lt $MinRows) { Say "FAIL only $count rows rendered ($label)"; $bad++ }
    else { Say "OK $count rows with three filled cells each ($label)" }

    # second click = same button dismisses it, which is the behaviour the user asked
    # for on the overlay hotkey and what makes this a panel rather than a dialog.
    if (-not (Invoke-Btn (Find-Window $proc.Id) 'BtnShortcuts' $label)) {
        $bad++
    } else {
        if (Wait-Rows $proc.Id 15 $false) { Say "OK the panel closes from the same button ($label)" }
        else { Say "FAIL the panel stayed open after a second click ($label)"; $bad++ }
    }

    $script:Issues += $bad
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

Invoke-Pass 'es' 'Spanish'
Invoke-Pass 'en' 'English'

if ($null -ne $saved) { Set-Content -Path $langFile -Value $saved -NoNewline -Encoding ascii }

if ($script:Issues) { Say "SHORTCUT-TABLE FAIL issues=$script:Issues"; exit 1 }
Say 'SHORTCUT-TABLE OK'
exit 0
