# v4 §6.1 "Tap PCM": measure the bytes the decoded-PCM tap actually pushes
# through \\.\pipe\, using the real device.
#
# Two bugs in the first version of this probe made a working feature look dead,
# so both are pinned down in code here:
#   * it opened a NamedPipeClientStream. The tap is a *client* too (sink_try_open
#     calls CreateFileA), so two clients can never connect: the consumer has to
#     be a NamedPipeServerStream, like tools/pcm_tap_pipe_test.ps1 does.
#   * it was launched from MSYS bash, whose argv path conversion collapses
#     '\\.\pipe\x' to '\.\pipe\x'. The fork then treats it as a file, fopen
#     fails and the bridge logs its generic "no consumer" line -- which is how a
#     harness quoting bug was read as a product bug for three runs. The client
#     is therefore started from PowerShell, and the announce line in the client
#     log is checked so the evidence says which name actually arrived.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/pcm_pipe_probe.ps1 `
#     -Exe <scrcpy.exe> -Serial <serial>
param(
    [Parameter(Mandatory = $true)][string] $Exe,
    [Parameter(Mandatory = $true)][string] $Serial,
    [int] $Seconds = 12,
    [string] $Pipe = 'gsc_pcm_probe',
    [string] $OutDir = (Join-Path $env:TEMP 'gsc_pcm_probe')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$raw = Join-Path $OutDir 'pcm.raw'
$err = Join-Path $OutDir 'client.err'
$std = Join-Path $OutDir 'client.out'
$con = Join-Path $OutDir 'consumer.txt'
$res = Join-Path $OutDir 'result.txt'
Remove-Item $raw, $err, $std, $con, $res -ErrorAction SilentlyContinue

# The consumer only counts and appends: scanning samples inside the read loop
# would make PowerShell the slow consumer and legitimately trigger the bridge's
# drop-oldest path. Loudness is checked afterwards, by ffmpeg.
$job = Start-Job -ScriptBlock {
    param($pipe, $raw, $con)
    $total = 0
    $reads = 0
    $firstMs = -1
    $connected = 0
    $detail = ''
    try {
        $srv = New-Object System.IO.Pipes.NamedPipeServerStream($pipe, 'InOut')
        $srv.WaitForConnection()
        $connected = 1
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = New-Object System.IO.FileStream($raw, 'Create', 'Write', 'ReadWrite', 1048576)
        $buf = New-Object byte[] 65536
        while ($true) {
            $n = $srv.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            if ($firstMs -lt 0) { $firstMs = [int] $watch.ElapsedMilliseconds }
            $fs.Write($buf, 0, $n)
            $total += $n
            $reads++
        }
        $fs.Flush()
        $fs.Dispose()
        $srv.Dispose()
    } catch {
        $detail = $_.Exception.Message
    }
    Set-Content -Path $con -Value "$connected $total $reads $firstMs $detail"
} -ArgumentList $Pipe, $raw, $con

# let the job create the pipe before the producer starts
Start-Sleep -Seconds 6

$client = Start-Process -FilePath $Exe -PassThru -NoNewWindow `
    -RedirectStandardError $err -RedirectStandardOutput $std `
    -ArgumentList "--serial=$Serial", '--video-codec=h264', '--audio-codec=raw',
                  "--game-audio-pcm=\\.\pipe\$Pipe", '--window-title=gaming-pcm-probe'

Start-Sleep -Seconds $Seconds
# CloseMainWindow usually works, and then the exited process can no longer be
# opened -- Kill() on it raised "Access denied" and, with Stop preference, lost
# the result line while the numbers were already measured.
$null = $client.CloseMainWindow()
$null = $client.WaitForExit(8000)
if (-not $client.HasExited) {
    try {
        $client.Kill()
        $client.WaitForExit()
    } catch {
        # the tap streams into a pipe, so leaving the client running cannot
        # corrupt a file; the measured byte count still stands
        $closeErr = "client close failed: $($_.Exception.Message)"
    }
}

$null = Wait-Job $job -Timeout 25
Receive-Job $job
Remove-Job $job -Force

if (-not (Test-Path $con)) {
    Write-Output 'CONNECT=0 BYTES=0 READS=0 FIRST_MS=-1 DETAIL=consumer did not finish'
    exit 1
}
$parts = (Get-Content $con) -split ' ', 5
$connected = [int] $parts[0]
$total = [int] $parts[1]
$reads = [int] $parts[2]
$firstMs = [int] $parts[3]
$detail = if ($parts.Count -gt 4) { $parts[4] } else { '' }
if (-not $detail) { $detail = 'ok' }

$result = "CONNECT=$connected BYTES=$total READS=$reads FIRST_MS=$firstMs DETAIL=$detail$closeErr"
# stdout is a pipeline the caller may truncate; the file is what the gate reads
Set-Content -Path $res -Value $result
Write-Output $result
if ($total -le 0 -or ($total % 4) -ne 0) { exit 1 }
exit 0
