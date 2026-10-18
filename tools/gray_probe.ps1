param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Args = '',
    [string]$Serial = '',
    [int]$AttachPid = 0,
    [int]$WaitMs = 12000,
    [int]$Samples = 3,
    [int]$SampleGapMs = 1200,
    [string]$OutDir = '',
    [string]$Label = 'probe'
)
# Decides whether a mirror window shows the phone, a grey placeholder or black --
# and whether Windows thinks it has stopped responding -- without a human looking
# at it.
#
# v4 §1 asks "¿se ve la imagen?" for seven configurations on two devices. Answering
# that by eye is not evidence, and "grey" is a description of a symptom that Windows
# and the fork produce for different reasons. So this probe captures the window with
# PrintWindow (works even when it is not the foreground window), twice per sample,
# and reports three numbers that separate the cases:
#
#   mean / stdev over the captured pixels   -> black (mean~0), uniform grey
#                                              (mean~mid, stdev~0), real picture
#                                              (stdev large)
#   diff between two captures of the SAME  -> a live mirror changes; a stalled
#   window                                 decoder does not, even while the phone
#                                          is animating
#   IsHungAppWindow                        -> exactly the "No responde" the user
#                                              reported, as a boolean
#
# The script only reads pixels; it sends no input to the phone. $Args is passed to
# the binary as given, so the driver owns every flag and this file cannot quietly
# change what is being tested.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/gray_probe.ps1 `
#     -Exe dist\GamingScrcpy\scrcpy\scrcpy.exe -Args '--video-codec=h264' -Serial XXX

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class GrayWin {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
}
"@

function Capture([IntPtr]$h) {
    $r = New-Object GrayWin+RECT
    [GrayWin]::GetClientRect($h, [ref]$r) | Out-Null
    $w = $r.right - $r.left; $ht = $r.bottom - $r.top
    if ($w -lt 16 -or $ht -lt 16) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $ht, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $ok = [GrayWin]::PrintWindow($h, $hdc.GetHdc(), 2)   # PW_RENDERFULLCONTENT
    } finally { $hdc.ReleaseHdc() }
    $g.Dispose()
    if (-not $ok) { $bmp.Dispose(); return $null }
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $ht)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $stride = [Math]::Abs($data.Stride)
    $bytes = New-Object byte[] ($stride * $ht)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)
    $bmp.Dispose()
    # Sample a 64x64 lattice so the cost is fixed regardless of window size.
    $vals = New-Object double[] (64 * 64)
    $i = 0
    for ($y = 0; $y -lt $ht; $y += [Math]::Max(1, [int]($ht / 64))) {
        for ($x = 0; $x -lt $w; $x += [Math]::Max(1, [int]($w / 64))) {
            $o = $y * $stride + $x * 3
            if ($o + 2 -ge $bytes.Length) { continue }
            $b = $bytes[$o]; $gg = $bytes[$o + 1]; $rr = $bytes[$o + 2]
            $vals[$i] = 0.299 * $rr + 0.587 * $gg + 0.114 * $b
            $i = $i + 1
            if ($i -ge $vals.Length) { break }
        }
        if ($i -ge $vals.Length) { break }
    }
    return @{ vals = $vals[0..($i - 1)]; bytes = $bytes; w = $w; h = $ht }
}

function Stats($vals) {
    $mean = ($vals | Measure-Object -Average).Average
    $sd = [Math]::Sqrt((($vals | ForEach-Object { [Math]::Pow($_ - $mean, 2) } |
            Measure-Object -Sum).Sum) / $vals.Count)
    return @{ mean = [Math]::Round($mean, 1); sd = [Math]::Round($sd, 1) }
}

function Diff($a, $b) {
    $n = [Math]::Min($a.bytes.Length, $b.bytes.Length)
    $diff = 0; $maxd = 0
    for ($i = 0; $i -lt $n; $i += 37) {
        $d = [Math]::Abs([int]$a.bytes[$i] - [int]$b.bytes[$i])
        if ($d -gt 12) { $diff = $diff + 1 }
        if ($d -gt $maxd) { $maxd = $d }
    }
    return @{ changed = $diff; max = $maxd }
}

$log = "$Label.stderr.txt"
if ($OutDir) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null; $log = Join-Path $OutDir $log }

$p = $null
$owns = $true
if ($AttachPid -gt 0) {
    # Attach to a session somebody else started -- the launcher's Mirror button, or
    # a scrcpy already on screen. The user's bug report is about that path, and a
    # probe that can only look at windows it launched itself could never see it.
    $owns = $false
    $p = Get-Process -Id $AttachPid -ErrorAction SilentlyContinue
    if (-not $p) { Write-Output "FAIL no process $AttachPid to attach to"; exit 1 }
} else {
    $full = @()
    if ($Serial) { $full += @('-s', $Serial) }
    if ($Args) { $full += ($Args -split '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)') | ForEach-Object { $_ -replace '^"|"$', '' } }
    $p = Start-Process -FilePath $Exe -ArgumentList $full -PassThru `
            -RedirectStandardError $log -RedirectStandardOutput "$log.out" -WindowStyle Hidden
}
try {
    $h = [IntPtr]::Zero
    $end = (Get-Date).AddMilliseconds($WaitMs)
    while ((Get-Date) -lt $end) {
        $pp = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
        if ($pp -and $pp.MainWindowHandle -ne [IntPtr]::Zero) { $h = $pp.MainWindowHandle; break }
        if ($pp -eq $null -or $pp.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    if ($h -eq [IntPtr]::Zero) {
        Write-Output ("RESULT {0} label={1} window=none exit={2}" -f 'NOSESSION', $Label,
            (Get-Process -Id $p.Id -ErrorAction SilentlyContinue).HasExited)
        exit 2
    }

    $prev = $null
    # The size is the first signal, and it is the one that nearly produced a false
    # verdict here: scrcpy resizes its window when the first video frame is decoded,
    # so a window still at SDL's 256x256 default after the wait has never shown a
    # frame. Capturing that and calling its pixels "textured" is meaningless -- the
    # content is the placeholder, not the phone.
    $probeLog = ''
    if (Test-Path $log) { $probeLog = Get-Content $log -Raw -ErrorAction SilentlyContinue }
    if ($probeLog -match 'video disabled') {
        Write-Output "RESULT NOVIDEO label=$Label reason=stderr says video playback is off"
        exit 3
    }
    for ($s = 0; $s -lt $Samples; $s++) {
        Start-Sleep -Milliseconds $SampleGapMs
        $c1 = Capture $h
        if ($c1 -eq $null) { Write-Output "RESULT label=$Label sample=$s capture=failed"; continue }
        $c2 = Capture $h
        $st = Stats $c1.vals
        $d = @{ changed = -1; max = -1 }
        if ($c2 -ne $null) { $d = Diff $c1 $c2 }
        $hung = [GrayWin]::IsHungAppWindow($h)
        $live = if ($null -ne $d.changed) { [int]$d.changed -gt 20 } else { $false }
        $verdict = 'LIVE'
        if ($c1.w -le 300 -and $c1.h -le 300) { $verdict = 'NOFRAME' }
        elseif ($st.mean -lt 12) { $verdict = 'BLACK' }
        elseif ($st.sd -lt 6) { $verdict = 'FLAT' }
        Write-Output ("RESULT {0} label={1} sample={2} mean={3} stdev={4} changed={5} maxdelta={6} moving={7} hung={8} window={9}x{10}" -f
            $verdict, $Label, $s, $st.mean, $st.sd, $d.changed, $d.max, $live, $hung, $c1.w, $c1.h)
        if ($OutDir -and $s -eq 0 -and $c2) {
            $bmp = New-Object System.Drawing.Bitmap($c1.w, $c1.h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $rect = New-Object System.Drawing.Rectangle(0, 0, $c1.w, $c1.h)
            $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                                  [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $stride = [Math]::Abs($data.Stride)
            for ($y = 0; $y -lt $c1.h; $y++) {
                [System.Runtime.InteropServices.Marshal]::Copy(
                    $c1.bytes, $y * $c1.w * 3, [IntPtr]([Int64]$data.Scan0 + $y * $stride), $c1.w * 3)
            }
            $bmp.UnlockBits($data)
            $bmp.Save((Join-Path $OutDir "$Label.png"), [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
        $prev = $c1
    }
} finally {
    if ($owns) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $p.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
}
