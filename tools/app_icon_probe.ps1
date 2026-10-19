# v4 §4.1: the exe logo, checked as three separate claims instead of one look.
#
#   1. the .ico really carries the resolutions Windows picks from, in the v3
#      palette (a 32x32-only .ico would look right in the taskbar and turn into
#      a blurry square in Explorer's small-icon view);
#   2. the built .exe embeds *that* icon, which is what Explorer and a shortcut
#      show -- an exe with no icon at all falls back to the generic Windows one,
#      so this is the claim "no placeholder left" rests on;
#   3. the running window has an icon handle, which is what the taskbar and the
#      title bar draw. A WPF window inherits the application icon only when
#      nothing overrides it, so the handle is worth checking on the live window.
#
# Exit: 0 all three, 1 a finding, 2 a file the probe needs is missing.
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$Exe = ''
)

Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$pass = 0; $fail = 0
function ok($m)  { Write-Output "OK   $m"; $script:pass++ }
function bad($m) { Write-Output "FAIL $m"; $script:fail++ }

$ico = Join-Path $Root 'launcher/Assets/app.ico'
if (-not $Exe) { $Exe = (Join-Path $Root 'dist/GamingScrcpy/launcher/GamingScrcpyLauncher.exe') }
if (-not (Test-Path $ico)) { Write-Output "SKIP no app.ico at $ico"; exit 2 }
if (-not (Test-Path $Exe)) { Write-Output "SKIP no launcher exe at $Exe"; exit 2 }
Write-Output "note exe: $Exe"

# The accent of the v3 palette, and the tolerance it is matched at: the raster is
# anti-aliased over a dark background, so an exact-equality test would fail on
# every real render.
$accent = 79, 163, 255
function AccentPixels($bmp) {
    $n = 0
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if ($c.A -lt 32) { continue }
            if ([Math]::Abs($c.R - 79) -le 40 -and [Math]::Abs($c.G - 163) -le 40 `
                    -and [Math]::Abs($c.B - 255) -le 40) { $n++ }
        }
    }
    return $n
}

# ---- 1. the .ico itself ------------------------------------------------------
$b = [IO.File]::ReadAllBytes($ico)
$type = [BitConverter]::ToUInt16($b, 2)
$count = [BitConverter]::ToUInt16($b, 4)
$sizes = @()
for ($i = 0; $i -lt $count; $i++) {
    $o = 6 + 16 * $i
    $w = $b[$o]; if ($w -eq 0) { $w = 256 }
    $h = $b[$o + 1]; if ($h -eq 0) { $h = 256 }
    $sizes += $w
}
$sizes = $sizes | Sort-Object -Unique
Write-Output "note app.ico: type=$type entries=$count sizes=$($sizes -join ',')"
if ($type -ne 1) { bad "app.ico is not an icon directory (type=$type)" }
if ($sizes.Count -ge 6) { ok "$($sizes.Count) resolutions embedded" }
else { bad "only $($sizes.Count) resolutions in app.ico: Windows will scale one of them" }
foreach ($need in 16, 32, 48, 256) {
    if ($sizes -contains $need) { ok "resolution $need present" }
    else { bad "resolution $need missing (small icon views, taskbar, or shortcuts)" }
}

# ---- 2. what the exe embeds --------------------------------------------------
$fromIco = New-Object System.Drawing.Bitmap 32, 32
$g = [Drawing.Graphics]::FromImage($fromIco)
$g.DrawIcon((New-Object System.Drawing.Icon($ico, 32, 32)), 0, 0)
$g.Dispose()
$icoAccent = AccentPixels $fromIco

$assoc = [System.Drawing.Icon]::ExtractAssociatedIcon($Exe)
if (-not $assoc) {
    bad 'the exe exposes no icon at all (Explorer would show the generic page)'
} else {
    $exeBmp = New-Object System.Drawing.Bitmap $assoc.Width, $assoc.Height
    $g2 = [Drawing.Graphics]::FromImage($exeBmp)
    $g2.DrawIcon($assoc, 0, 0)
    $g2.Dispose()
    $exeAccent = AccentPixels $exeBmp
    Write-Output "note accent pixels: app.ico=$icoAccent exe=$exeAccent at $($assoc.Width)x$($assoc.Height)"
    if ($icoAccent -gt 0 -and $exeAccent -gt 0) {
        ok "the exe draws the accent: the brand image, not a placeholder"
    } else {
        bad "the exe's icon has no accent pixels: it is not app.ico ($icoAccent vs $exeAccent)"
    }
    $assoc.Dispose()
}

# ---- 3. the live window ------------------------------------------------------
# --validate-profiles would exit before a window exists, and the probe needs a
# real one: start it, read the icon handles, close it. The launcher writes its
# profiles on startup, so the probe asks the app to quit the same way the user
# would rather than killing it mid-write.
$proc = Start-Process -FilePath $Exe -PassThru -WindowStyle Normal -ErrorAction SilentlyContinue
if (-not $proc) { bad 'the launcher would not start, so the window icon is unchecked' }
else {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class W {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l,
        uint flags, uint ms, out IntPtr res);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr h, uint flags);
}
"@
    $ready = $false
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 500
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { $ready = $true; break }
    }
    if (-not $ready) {
        bad 'the launcher window never appeared, so its icon handle is unchecked'
    } else {
        $hwnd = $proc.MainWindowHandle
        $want = @(
            @{ label = 'ICON_SMALL (title bar)'; which = 0 },
            @{ label = 'ICON_BIG (taskbar / Alt+Tab)'; which = 1 }
        )
        foreach ($w in $want) {
            $res = [IntPtr]::Zero
            # WM_GETICON = 0x7F; SMTO_ABORTIFHUNG keeps a stuck window from hanging the probe
            $null = [W]::SendMessageTimeout($hwnd, 0x7F, [IntPtr] $w.which, [IntPtr]::Zero, 0x0002, 2000, [ref] $res)
            if ($res -ne [IntPtr]::Zero) { ok "the live window answers WM_GETICON $($w.label)" }
            else { bad "the live window has no $($w.label)" }
        }
        # GCLP_HICON = -14 on 32-bit, -16 on 64-bit; GetClassLongPtr is only
        # reachable through a separate P/Invoke, and WM_GETICON already answers
        # the question the directive asks (taskbar and title bar), so the probe
        # stops here rather than adding a second way to ask the same thing.
    }
    $proc.CloseMainWindow() | Out-Null
    if (-not $proc.WaitForExit(8000)) { $proc.Kill(); bad 'the launcher ignored the close request' }
}

Write-Output ''
Write-Output "ICON PROBE pass=$pass fail=$fail"
if ($fail -eq 0) { Write-Output 'ICON PROBE OK'; exit 0 }
Write-Output 'ICON PROBE FAIL'; exit 1
