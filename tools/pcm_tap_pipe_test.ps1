$ErrorActionPreference = 'Continue'
# Proves the decoded PCM tap (--game-audio-pcm) over \\.\pipe\, which is how it
# is actually used: a virtual cable or ffmpeg reading a named pipe. The file
# path is covered by tools/bridge_encode_test.sh; this covers the transport.
#
# The consumer only counts and appends -- scanning samples inside the read loop
# makes PowerShell the slow consumer, which then legitimately triggers the
# bridge's drop-oldest path. Loudness is checked afterwards, by ffmpeg.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/pcm_tap_pipe_test.ps1

$root = Split-Path -Parent $PSScriptRoot   # repo root: runs from any clone
$demo = Join-Path $root 'workspace\scrcpy\build-usb\app\gamingdemo.exe'
$dir  = Join-Path $root 'out'
$out  = Join-Path $dir 'pcm_pipe_demo.log'
$raw  = Join-Path $dir 'pcm_pipe.raw'
$log  = Join-Path $dir 'pcm_pipe.txt'
Remove-Item $out, $raw, $log -ErrorAction SilentlyContinue

$frames = 200
# the demo feeds the tap 882 samples at 44.1 kHz per frame -> 960 at 48 kHz,
# stereo s16le = 3840 B per frame
$expect = $frames * 3840

$consumer = Start-Job -ScriptBlock {
  param($pipe, $raw, $log)
  $fs = New-Object System.IO.FileStream($raw, 'Create', 'Write', 'ReadWrite', 1048576)
  $srv = New-Object System.IO.Pipes.NamedPipeServerStream($pipe, 'InOut')
  $srv.WaitForConnection()
  $total = 0
  $chunks = 0
  $buf = New-Object byte[] 65536
  while ($true) {
    $n = $srv.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $fs.Write($buf, 0, $n)
    $total += $n
    $chunks++
  }
  $fs.Flush()
  $srv.Dispose()
  $fs.Dispose()
  Set-Content -Path $log -Value "$total $chunks"
} -ArgumentList 'gaming-pcm', $raw, $log

# let the job create the pipe before the producer starts
Start-Sleep -Seconds 8

$env:PATH = 'C:\msys64\ucrt64\bin;' + $env:PATH
& $demo "--frames=$frames" --width=320 --height=240 `
   "--pcm-tap=\\.\pipe\gaming-pcm" --no-osd 2>&1 |
  ForEach-Object { "$_" } | Set-Content -Path $out

Wait-Job $consumer -Timeout 40 | Out-Null
Receive-Job $consumer
Remove-Job $consumer -Force

$fail = 0
Select-String -Path $out -Pattern 'pcm tap|PASS|FAIL' | ForEach-Object { Write-Output $_.Line }
if (-not (Select-String -Path $out -Pattern 'gamingdemo: PASS' -Quiet)) {
  Write-Output 'FAIL demo did not report PASS'
  $fail++
}
if (-not (Select-String -Path $out -Pattern 'consumer connected' -Quiet)) {
  Write-Output 'FAIL the tap never connected to the pipe'
  $fail++
}
if (Test-Path $log) {
  $parts = (Get-Content $log) -split ' '
  $total = [int] $parts[0]
  $chunks = [int] $parts[1]
  Write-Output ("pipe consumer received: $total B in $chunks reads")
  Write-Output "expected: $frames frames x 3840 B = $expect B of 48 kHz stereo s16le"
  if ($total * 10 -lt $expect) {
    Write-Output 'FAIL the pipe delivered far less than the produced audio'
    $fail++
  }
  if ($total % 4) {
    Write-Output 'FAIL byte count is not a whole number of s16le stereo frames'
    $fail++
  }
} else {
  Write-Output 'FAIL consumer never completed'
  $fail++
}

# decodability + non-silence of what actually crossed the pipe
$ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ff -and (Test-Path $raw)) {
  $vd = & ffmpeg -hide_banner -f s16le -ar 48000 -ac 2 -i $raw `
        -af volumedetect -f null NUL 2>&1 | Out-String
  $maxv = ($vd | Select-String 'max_volume: (-?[0-9.]+) dB').Matches
  if ($maxv.Count -eq 1) {
    $db = [double] $maxv[0].Groups[1].Value
    Write-Output "ffmpeg decoded the piped bytes as 48 kHz stereo, max_volume=$db dB"
    if ($db -lt -40) {
      Write-Output 'FAIL the piped stream is (near) silence'
      $fail++
    }
  } else {
    Write-Output 'FAIL ffmpeg could not decode the piped bytes'
    $fail++
  }
}

if ($fail) { Write-Output "PCMPIPE FAIL ($fail)"; exit 1 }
Write-Output 'PCMPIPE OK'
exit 0
