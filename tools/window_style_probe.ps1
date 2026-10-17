# Report the Win32 style bits and geometry of a window, so "borderless
# fullscreen" and "always on top" can be verified against the window the app
# actually created instead of against the flag that asked for it.
param(
    [Parameter(Mandatory = $true)][uint32] $Pid32
)

$code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class G {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static IntPtr Find(uint want) {
        IntPtr best = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            var sb = new StringBuilder(256); GetWindowText(h, sb, sb.Capacity);
            if (pid == want && IsWindowVisible(h) && sb.Length > 0 && best == IntPtr.Zero) {
                best = h;
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}
'@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition $code

$h = [G]::Find($Pid32)
if ($h -eq [IntPtr]::Zero) {
    Write-Output "RESULT window NO VISIBLE WINDOW pid=$Pid32"
    exit 1
}
$style = [G]::GetWindowLong($h, -16)   # GWL_STYLE
$ex = [G]::GetWindowLong($h, -20)      # GWL_EXSTYLE
$r = New-Object G+RECT
[G]::GetWindowRect($h, [ref]$r) | Out-Null
$cap = $style -band 0x00C00000         # WS_CAPTION
$thick = $style -band 0x00040000       # WS_THICKFRAME
$popup = $style -band 0x80000000       # WS_POPUP
$topmost = $ex -band 0x00000008        # WS_EX_TOPMOST
$work = [System.Windows.Forms.SystemInformation]::VirtualScreen
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
Write-Output ("RESULT window hwnd={0} style=0x{1:x8} exstyle=0x{2:x8}" -f $h, $style, $ex)
Write-Output ("RESULT flags caption={0} thickframe={1} popup={2} topmost={3}" -f `
        (($cap -ne 0) -as [int]), (($thick -ne 0) -as [int]), (($popup -ne 0) -as [int]), `
        (($topmost -ne 0) -as [int]))
Write-Output ("RESULT rect {0}x{1}+{2}+{3} workarea={4}x{5}+{6}+{7}" -f `
        ($r.R - $r.L), ($r.B - $r.T), $r.L, $r.T, `
        $scr.Width, $scr.Height, $scr.X, $scr.Y)
