param(
    [string]$ArgFile = 'out\bug_gray\launcher_session.argv.txt',
    [string]$Mode = 'file',
    [string]$Drop = '',
    [string]$Set = '',
    [int]$WaitMs = 14000,
    [int]$Samples = 2,
    [int]$SampleGapMs = 6000,
    [string]$OutDir = 'out\bug_gray',
    [string]$Label = 'ab'
)
# Re-run the launcher's OWN command line under three parents, so the grey window can
# be blamed on either the argv or the way the launcher hosts the child.
#
# v4 §1 measured fifteen hand-written CLI configurations as LIVE while the launcher's
# Mirror button produced FLAT + hung=True. That difference has exactly two causes: the
# argv is not what the CLI sent, or the parenting is. This script takes the argv read
# out of the running child (tools/launcher_session_probe.ps1 writes it with
# CommandLineToArgvW) and holds it fixed while it changes the parent:
#
#   file     stdout/stderr go to files -- always drains, never blocks the writer
#   nodrain  the child owns pipes nobody reads -- the classic backpressure trap
#   drain    pipes read continuously on the thread pool, counting bytes
#
# If all three verdicts agree, the parenting is irrelevant and the argv is guilty; the
# -Drop/-Set switches then bisect it one flag at a time. If they disagree, the fork is
# innocent and the launcher's host code owns the bug.
#
# -Drop '--game-frame-bridge'  removes every argv entry starting with that text.
# -Set  '--video-codec=h264'   replaces the entry starting with '--video-codec=', or
#                              appends it when the profile never set one.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/parent_mode_probe.ps1 `
#     -Mode nodrain -Label ab_nodrain
#   powershell ... -File tools/parent_mode_probe.ps1 -Set '--video-codec=h264' -Label ab_h264

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$exe = Join-Path $root 'dist\GamingScrcpy\scrcpy\scrcpy.exe'
if (-not (Test-Path $exe)) { Write-Output "FAIL scrcpy.exe missing: $exe"; exit 1 }

$path = $ArgFile
if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $root $ArgFile }
if (-not (Test-Path $path)) { Write-Output "FAIL argv file missing: $path"; exit 1 }
$argv = Get-Content $path | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim([char]0xFEFF) }
if ($argv.Count -lt 2) { Write-Output "FAIL argv file holds $($argv.Count) lines"; exit 1 }

$child = @($argv[1..($argv.Count - 1)])
# Comma-separated rather than [string[]]: "powershell -File" binds a repeated
# parameter as one string, so an array parameter would silently arrive as a single
# element holding the whole list and drop nothing at all.
foreach ($d in @($Drop -split ',' | Where-Object { $_ })) {
    $before = $child.Count
    $child = @($child | Where-Object { -not $_.StartsWith($d) })
    Write-Output ("note  drop {0}: {1} -> {2} argv entries" -f $d, $before, $child.Count)
}
foreach ($s in @($Set -split ',' | Where-Object { $_ })) {
    $name = ($s -split '=', 2)[0]
    $hit = $false
    for ($i = 0; $i -lt $child.Count; $i++) {
        if ($child[$i].StartsWith("$name=")) { $child[$i] = $s; $hit = $true }
    }
    if (-not $hit) { $child = $child + $s }
    Write-Output ("note  set {0} ({1})" -f $s, $(if ($hit) { 'replaced' } else { 'appended' }))
}

function Format-Arg([string]$a) {
    # The Windows command-line parser: a bare token passes through, anything with a
    # space or a quote is wrapped, and embedded quotes are preceded by 2n+1
    # backslashes. Getting this wrong silently turns "--window-title 4K Ultra ..."
    # into extra options, so it is implemented here rather than trusted to luck.
    if ($a.Length -eq 0) { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $r = New-Object System.Text.StringBuilder
    [void]$r.Append('"')
    $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $bs = $bs + 1; continue }
        if ($ch -eq '"') {
            for ($i = 0; $i -lt (2 * $bs + 1); $i++) { [void]$r.Append('\') }
            [void]$r.Append('"')
        } else {
            for ($i = 0; $i -lt $bs; $i++) { [void]$r.Append('\') }
            $bs = 0
            [void]$r.Append($ch)
        }
    }
    for ($i = 0; $i -lt (2 * $bs); $i++) { [void]$r.Append('\') }
    [void]$r.Append('"')
    return $r.ToString()
}

$proc = $null
$drained = [hashtable]::Synchronized(@{ out = 0; err = 0 })
$errFile = Join-Path $root (Join-Path $OutDir "$Label.stderr.txt")
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $errFile) | Out-Null

# One quoted command line, used by every mode. Building it once is the point: the
# first run of this script passed the argv as an array to Start-Process, which does
# not quote a value containing spaces, so the file arm died on
# "ERROR: Unexpected additional argument: Ultra" while the other arms ran a real
# session -- three modes that were not the same command.
$argLine = ($child | ForEach-Object { Format-Arg $_ }) -join ' '

if ($Mode -eq 'file') {
    $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru -WindowStyle Hidden `
            -RedirectStandardError $errFile -RedirectStandardOutput "$errFile.out" `
            -WorkingDirectory (Split-Path -Parent $exe)
} else {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.WorkingDirectory = Split-Path -Parent $exe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = ($Mode -ne 'file')
    $psi.RedirectStandardError = ($Mode -ne 'file')
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($Mode -eq 'drain') {
        $cb = [System.Threading.WaitCallback] {
            param($o)
            $s = $o.S; $k = $o.K
            $buf = New-Object byte[] 8192
            try {
                while ($true) {
                    $n = $s.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    # One writer per key, so the synchronized hashtable alone keeps
                    # the running total correct.
                    $o.C.$k = $o.C.$k + $n
                }
            } catch { }
        }
        foreach ($pair in @(@{ S = $proc.StandardOutput; K = 'out' }, @{ S = $proc.StandardError; K = 'err' })) {
            $state = @{ S = $pair.S; K = $pair.K; C = $drained }
            [System.Threading.ThreadPool]::QueueUserWorkItem($cb, $state) | Out-Null
        }
    }
    # nodrain deliberately does the opposite: it holds the pipe handles and never
    # reads them, which is the only way to make a child block on WriteFile.
    $null = $proc.StandardOutput
    $null = $proc.StandardError
}

try {
    $probe = Join-Path $root 'tools\gray_probe.ps1'
    & $probe -Exe $exe -AttachPid $proc.Id -Label $Label -OutDir (Join-Path $root $OutDir) `
             -Samples $Samples -SampleGapMs $SampleGapMs -WaitMs $WaitMs 2>&1 |
        ForEach-Object { Write-Output $_ }

    $me = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($me) {
        $me.Refresh()
        Write-Output ("PARENT mode={0} label={1} responding={2} threads={3} cpu_s={4:N2} drained_out={5} drained_err={6}" -f
            $Mode, $Label, $me.Responding, $me.Threads.Count, $me.TotalProcessorTime.TotalSeconds,
            $drained.out, $drained.err)
        if (Test-Path $errFile) {
            Write-Output '--- child stderr ---'
            Get-Content $errFile | Select-Object -Last 8 | ForEach-Object { Write-Output "      $_" }
        }
    } else {
        Write-Output ("PARENT mode={0} label={1} exited={2} drained_out={3} drained_err={4}" -f
            $Mode, $Label, $true, $drained.out, $drained.err)
    }
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $proc.Id -Timeout 8 -ErrorAction SilentlyContinue
}
