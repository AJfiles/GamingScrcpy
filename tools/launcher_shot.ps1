param(
    [string]$Exe = "$PSScriptRoot\..\dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe",
    [string]$Out = "$PSScriptRoot\..\out\launcher_shot.png",
    [int]$Wait = 6
)
# Start the published launcher, prove the window really exists, and grab the
# screen: the WPF panels only fail at runtime, not at build time.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (Test-Path $Exe) {
    $p = Start-Process -FilePath $Exe -PassThru
} else {
    Write-Output "MISSING_EXE $Exe"
    exit 1
}
Start-Sleep -Seconds $Wait
$alive = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
if (-not $alive) {
    Write-Output "CRASHED: process exited before the screenshot"
    exit 2
}
$title = $alive.MainWindowTitle
$handle = $alive.MainWindowHandle
Write-Output ("WINDOW title='{0}' handle={1} rects={2}" -f $title, $handle, $alive.MainModule.BaseAddress)

$bmp = New-Object System.Drawing.Bitmap([System.Windows.Forms.SystemInformation]::VirtualScreen.Width,
                                        [System.Windows.Forms.SystemInformation]::VirtualScreen.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen([System.Windows.Forms.SystemInformation]::VirtualScreen.X,
                  [System.Windows.Forms.SystemInformation]::VirtualScreen.Y, 0, 0, $bmp.Size)
$g.Dispose()
$full = (Resolve-Path -LiteralPath (Split-Path -Parent $Out) -ErrorAction SilentlyContinue)
if (-not $full) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null }
$bmp.Save((Join-Path (Split-Path -Parent $Out) (Split-Path -Leaf $Out)), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

# crop the launcher window itself so the picture is readable at 1366x768
$rect = New-Object System.Drawing.Rectangle
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
[Win32]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 400
$r = New-Object Win32+RECT
[Win32]::GetWindowRect($handle, [ref]$r) | Out-Null
Write-Output ("RECT {0},{1} {2}x{3}" -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
$bmp2 = New-Object System.Drawing.Bitmap(($r.Right - $r.Left), ($r.Bottom - $r.Top))
$g2 = [System.Drawing.Graphics]::FromImage($bmp2)
$g2.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp2.Size)
$g2.Dispose()
$leaf = [System.IO.Path]::GetFileNameWithoutExtension($Out) + "_window.png"
$bmp2.Save((Join-Path (Split-Path -Parent $Out) $leaf), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp2.Dispose()
Stop-Process -Id $p.Id -Force
Write-Output "SAVED $Out"
