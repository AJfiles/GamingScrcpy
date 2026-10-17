# Focus the scrcpy window and send its own "turn the device screen on"
# shortcut (MOD+O). Nothing else is touched: no setting, no key layout, no
# install. scrcpy injects the key through its control channel, exactly as if
# the user had pressed it.
param(
    [string] $TitlePattern = 'scrcpy'
)

$code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
    public static IntPtr Find(string pattern, uint ownPid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(256);
            GetWindowText(h, sb, sb.Capacity);
            uint pid; GetWindowThreadProcessId(h, out pid);
            string t = sb.ToString();
            if (found == IntPtr.Zero && pid == ownPid && t.Length > 0
                    && t.IndexOf(pattern, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = h;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static void WinO() {
        keybd_event(0x5B, 0, 0, UIntPtr.Zero);            // left Windows
        keybd_event(0x4F, 0, 0, UIntPtr.Zero);            // O
        keybd_event(0x4F, 0, 2, UIntPtr.Zero);
        keybd_event(0x5B, 0, 2, UIntPtr.Zero);
    }
}
'@

Add-Type -TypeDefinition $code

$procs = Get-Process -Name scrcpy -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $procs) {
    Write-Output 'RESULT wake NO SCRCPY PROCESS'
    exit 1
}
$h = [W]::Find($TitlePattern, [uint32] $procs.Id)
if ($h -eq [IntPtr]::Zero) {
    # the window title is the device model, not "scrcpy"
    $h = [W]::Find('', [uint32] $procs.Id)
}
if ($h -eq [IntPtr]::Zero) {
    Write-Output "RESULT wake NO WINDOW pid=$($procs.Id)"
    exit 1
}
[W]::ShowWindow($h, 9) | Out-Null  # SW_RESTORE
[W]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 300
[W]::WinO()
Write-Output "RESULT wake sent MOD+O to hwnd=$h pid=$($procs.Id)"
