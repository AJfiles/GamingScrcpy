$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$demo = 'C:\Users\Administrator\Desktop\GamingCapture\workspace\scrcpy\build-usb\app\gamingdemo.exe'
$env:PATH = 'C:\msys64\ucrt64\bin;' + $env:PATH
$frameBytes = 640 * 360 * 4


Write-Output "=== CASE A: consumer already listening ==="
$loga = 'C:\Users\Administrator\Desktop\GamingCapture\out\pipe_a.txt'
Remove-Item $loga -ErrorAction SilentlyContinue
$job = Start-Job -ScriptBlock {
  param($name, $log)
  $srv = New-Object System.IO.Pipes.NamedPipeServerStream($name, 'InOut')
  $srv.WaitForConnection()
  $total = 0
  $buf = New-Object byte[] 262144
  while ($true) {
    $n = $srv.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $total += $n
  }
  $srv.Dispose()
  Set-Content -Path $log -Value $total
} -ArgumentList 'gaming-frame', $loga
Start-Sleep -Seconds 2
$t0 = Get-Date
& $demo --frames=40 --width=640 --height=360 --bridge='\\.\pipe\gaming-frame' --no-osd 2>&1 |
  Where-Object { $_ -match 'bridge|PASS|FAIL|fps' }
$elapsedA = ((Get-Date) - $t0).TotalSeconds
Wait-Job $job -Timeout 20 | Out-Null
Receive-Job $job
Remove-Job $job -Force
$readA = [int64](Get-Content $loga)
Write-Output ("consumer read {0} bytes; frame={1}; frames={2:N1}; exact_multiple={3}; demo_wall={4:N1}s" -f `
  $readA, $frameBytes, ($readA / $frameBytes), (($readA % $frameBytes) -eq 0), $elapsedA)

Write-Output "=== CASE B: nobody is listening ==="
$t1 = Get-Date
& $demo --frames=40 --width=640 --height=360 --bridge='\\.\pipe\nobody-here' --no-osd 2>&1 |
  Where-Object { $_ -match 'bridge|PASS|FAIL' }
$elapsedB = ((Get-Date) - $t1).TotalSeconds
Write-Output ("run with no consumer took {0:N1}s wall clock (init must NOT block 10s)" -f $elapsedB)

Write-Output "=== CASE C: consumer joins 2s AFTER the bridge started ==="
$logc = 'C:\Users\Administrator\Desktop\GamingCapture\out\pipe_c.txt'
Remove-Item $logc -ErrorAction SilentlyContinue
$demoOut = 'C:\Users\Administrator\Desktop\GamingCapture\out\pipe_c.log'
$producer = Start-Job -ScriptBlock {
  param($demo, $out)
  $env:PATH = 'C:\msys64\ucrt64\bin;' + $env:PATH
  & $demo --frames=700 --width=640 --height=360 --bridge='\\.\pipe\gaming-late' --no-osd 2>&1 |
    ForEach-Object { "$_" } | Set-Content -Path $out
} -ArgumentList $demo, $demoOut
Start-Sleep -Seconds 2
$consumer = Start-Job -ScriptBlock {
  param($log)
  $srv = New-Object System.IO.Pipes.NamedPipeServerStream('gaming-late', 'InOut')
  $srv.WaitForConnection()
  $total = 0
  $buf = New-Object byte[] 262144
  while ($true) {
    $n = $srv.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $total += $n
  }
  $srv.Dispose()
  Set-Content -Path $log -Value $total
} -ArgumentList $logc
Wait-Job $producer -Timeout 60 | Out-Null
Wait-Job $consumer -Timeout 30 | Out-Null
Select-String -Path $demoOut -Pattern 'waiting|connected|frames sent|frames dropped|PASS|FAIL' |
  ForEach-Object { $_.Line }
Remove-Job $producer, $consumer -Force
if (Test-Path $logc) {
  $readC = [int64](Get-Content $logc)
  Write-Output ("late consumer read {0} bytes; frames={1:N1}; exact_multiple={2}" -f `
    $readC, ($readC / $frameBytes), (($readC % $frameBytes) -eq 0))
} else {
  Write-Output "consumer never connected"
}
