$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot   # repo root: runs from any clone
$demo = Join-Path $root 'workspace\scrcpy\build-usb\app\gamingdemo.exe'
$out  = Join-Path $root 'out\audio_demo.log'
$log  = Join-Path $root 'out\audio_pipe.txt'
Remove-Item $out, $log -ErrorAction SilentlyContinue

$consumer = Start-Job -ScriptBlock {
  param($log)
  $srv = New-Object System.IO.Pipes.NamedPipeServerStream('gaming-audio', 'InOut')
  $srv.WaitForConnection()
  $total = 0
  $chunks = 0
  $buf = New-Object byte[] 65536
  while ($true) {
    $n = $srv.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $total += $n
    $chunks++
  }
  $srv.Dispose()
  Set-Content -Path $log -Value "$total $chunks"
} -ArgumentList $log

# give the job time to actually create the pipe before the producer starts
Start-Sleep -Seconds 8

$env:PATH = 'C:\msys64\ucrt64\bin;' + $env:PATH
& $demo --frames=800 --width=320 --height=240 --audio='\\.\pipe\gaming-audio' --no-osd 2>&1 |
  ForEach-Object { "$_" } | Set-Content -Path $out

Wait-Job $consumer -Timeout 25 | Out-Null
Receive-Job $consumer
Remove-Job $consumer -Force

Select-String -Path $out -Pattern 'audio bridge|PASS|FAIL' | ForEach-Object { $_.Line }
if (Test-Path $log) {
  Write-Output ("pipe consumer received: " + (Get-Content $log))
  Write-Output "expected: 400 packets x 200 B = 80000 bytes (800 frames, one every other frame)"
} else {
  Write-Output "consumer never completed"
}
