# v4 §4.1: render the GamingScrcpy app icon and pack it as a multi-resolution
# .ico. ImageMagick and Inkscape are not installed here and the ImageMagick
# 'convert' that IS on PATH belongs to Windows (NTFS volume management), so the
# drawing and packing is done with System.Drawing in this script instead.
#
# The mark is deliberately coarse: a rounded #0E0F13 tile with a solid #4FA3FF
# play triangle. The lightning notch that splits the triangle is only drawn at
# 48 px and above, because at 16 px the cut is under two pixels wide and turns
# the glyph into mud in the Explorer column.
#
# Every GDI+ object is built with [Type]::new(): the `New-Object Type(a, b)`
# shorthand parses the parenthesis as an argument *array* and hands back $null,
# which is how the first version of this script drew nothing at all.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_app_icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$sizes = 16, 24, 32, 48, 64, 128, 256
$dir = Join-Path $root 'launcher\Assets'
$preview = Join-Path $root 'out\icon'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
New-Item -ItemType Directory -Force -Path $preview | Out-Null

$bg = [System.Drawing.Color]::FromArgb(255, 0x0E, 0x0F, 0x13)
$accent = [System.Drawing.Color]::FromArgb(255, 0x4F, 0xA3, 0xFF)
$border = [System.Drawing.Color]::FromArgb(255, 0x2A, 0x2D, 0x3A)

function New-Triangle([double]$k) {
    @(
        [System.Drawing.PointF]::new([single](0.32 * $k), [single](0.24 * $k)),
        [System.Drawing.PointF]::new([single](0.32 * $k), [single](0.76 * $k)),
        [System.Drawing.PointF]::new([single](0.72 * $k), [single](0.50 * $k))
    )
}

function New-Bolt([double]$k) {
    @(
        [System.Drawing.PointF]::new([single](0.575 * $k), [single](0.155 * $k)),
        [System.Drawing.PointF]::new([single](0.420 * $k), [single](0.515 * $k)),
        [System.Drawing.PointF]::new([single](0.510 * $k), [single](0.515 * $k)),
        [System.Drawing.PointF]::new([single](0.430 * $k), [single](0.845 * $k)),
        [System.Drawing.PointF]::new([single](0.640 * $k), [single](0.455 * $k)),
        [System.Drawing.PointF]::new([single](0.545 * $k), [single](0.455 * $k))
    )
}

function New-RoundedPath([double]$w, [double]$h, [double]$r) {
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = [single]($r * 2)
    $r = [single]$r
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc([single]($w - $d), 0, $d, $d, 270, 90)
    $p.AddArc([single]($w - $d), [single]($h - $d), $d, $d, 0, 90)
    $p.AddArc(0, [single]($h - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Draw-Icon([int]$s) {
    $bmp = [System.Drawing.Bitmap]::new($s, $s,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # the tile is inset by 4% so the corners of a square taskbar slot stay clean
    $m = $s * 0.04
    $inner = $s - 2 * $m
    $g.TranslateTransform([single]$m, [single]$m)
    $tile = New-RoundedPath $inner $inner ($s * 0.22)
    $b = [System.Drawing.SolidBrush]::new($bg)
    $g.FillPath($b, $tile)
    $b.Dispose()
    if ($s -ge 32) {
        $p = [System.Drawing.Pen]::new($border, [single]([Math]::Max(1, $s * 0.02)))
        $g.DrawPath($p, $tile)
        $p.Dispose()
    }
    $tile.Dispose()

    $ab = [System.Drawing.SolidBrush]::new($accent)
    $g.FillPolygon($ab, (New-Triangle $inner),
        [System.Drawing.Drawing2D.FillMode]::Winding)
    if ($s -ge 48) {
        # lightning notch, painted in the tile colour so the mark stays one shape
        $cb = [System.Drawing.SolidBrush]::new($bg)
        $g.FillPolygon($cb, (New-Bolt $inner),
            [System.Drawing.Drawing2D.FillMode]::Winding)
        $cb.Dispose()
    }
    $ab.Dispose()
    $g.ResetTransform()
    $g.Dispose()
    return $bmp
}

function Get-PngBytes([System.Drawing.Bitmap]$bmp) {
    $ms = [System.IO.MemoryStream]::new()
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return , $bytes
}

# ---- .ico packing -----------------------------------------------------------
# Entries carry PNG payloads (Vista+ and every modern Explorer read them); the
# container is written by hand because .NET has no multi-size icon writer.
$entries = @()
foreach ($s in $sizes) {
    $bmp = Draw-Icon $s
    $bmp.Save((Join-Path $preview ("app-{0}.png" -f $s)),
        [System.Drawing.Imaging.ImageFormat]::Png)
    $entries += [pscustomobject]@{ Size = $s; Data = (Get-PngBytes $bmp) }
    $bmp.Dispose()
}

$ms = [System.IO.MemoryStream]::new()
$w = [System.IO.BinaryWriter]::new($ms)
$w.Write([UInt16]0)          # reserved
$w.Write([UInt16]1)          # type: icon
$w.Write([UInt16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    # the cast has to be on its own statement: `if` is not an expression in
    # Windows PowerShell, and leaving it to the ternary-free `else` branch meant
    # $dim arrived as an Int32 for the 256 px entry -- BinaryWriter then emitted
    # 4 bytes for the width and 4 for the height, the directory grew past 16
    # bytes per record and csc refused the build with CS7065 "unable to read
    # beyond the end of the stream". That is how a broken app.ico got committed.
    $dim = 0
    if ($e.Size -lt 256) { $dim = $e.Size }
    $dim = [Byte]$dim
    $w.Write($dim)           # width
    $w.Write($dim)           # height
    $w.Write([Byte]0)        # palette
    $w.Write([Byte]0)        # reserved
    $w.Write([UInt16]1)      # planes
    $w.Write([UInt16]32)     # bit depth
    $w.Write([UInt32]$e.Data.Length)
    $w.Write([UInt32]$offset)
    $offset += $e.Data.Length
}
foreach ($e in $entries) { $w.Write($e.Data) }
$w.Flush()
$ico = Join-Path $dir 'app.ico'
[System.IO.File]::WriteAllBytes($ico, $ms.ToArray())
$w.Dispose(); $ms.Dispose()

# Read the container back and check it against itself before calling it done:
# every record must sit in its own 16-byte slot and every payload must land
# inside the file. A writer that produces something only Explorer can judge is
# how the last version of this script shipped an exe that would not compile.
$bytes = [System.IO.File]::ReadAllBytes($ico)
$fail = 0
if ($bytes.Length -lt 6 + 16 * $entries.Count) { $fail++ }
$n = [System.BitConverter]::ToUInt16($bytes, 4)
if ($n -ne $entries.Count) { $fail++ }
for ($i = 0; $i -lt $n; $i++) {
    $o = 6 + 16 * $i
    $sz = [System.BitConverter]::ToUInt32($bytes, $o + 8)
    $ofs = [System.BitConverter]::ToUInt32($bytes, $o + 12)
    $w8 = [System.BitConverter]::ToUInt16($bytes, $o + 4)   # planes
    $d8 = [System.BitConverter]::ToUInt16($bytes, $o + 6)   # bit depth
    $dimRead = $bytes[$o]
    if ($w8 -ne 1 -or $d8 -ne 32) { $fail++ }
    if ($sz -eq 0 -or ($ofs + $sz) -gt $bytes.Length) { $fail++ }
    # the PNG signature is the only thing that proves the payload landed where
    # the directory says it did
    $sig = '{0:X2}{1:X2}{2:X2}{3:X2}' -f $bytes[$ofs], $bytes[$ofs + 1], `
        $bytes[$ofs + 2], $bytes[$ofs + 3]
    if ($sig -ne '89504E47') { $fail++ }
    $px = if ($dimRead -eq 0) { 256 } else { $dimRead }
    Write-Output ("  entry {0}: {1}px planes={2} depth={3} size={4} offset={5} png={6}" -f `
        $i, $px, $w8, $d8, $sz, $ofs, $sig)
}
if ($fail) { throw "app.ico does not parse back cleanly ($fail problem(s))" }

$fi = Get-Item $ico
Write-Output ("app.ico {0} bytes, {1} images: {2}" -f $fi.Length, $entries.Count,
    (($entries | ForEach-Object { $_.Size }) -join ' '))
