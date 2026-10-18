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
    $dim = if ($e.Size -ge 256) { 0 } else { [Byte]$e.Size }
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

$fi = Get-Item $ico
Write-Output ("app.ico {0} bytes, {1} images: {2}" -f $fi.Length, $entries.Count,
    (($entries | ForEach-Object { $_.Size }) -join ' '))
