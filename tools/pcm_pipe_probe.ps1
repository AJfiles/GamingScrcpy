# v4 §6.1: read the decoded-PCM tap the fork writes to a named pipe, and report
# the real byte count. The first version of this probe added a fixed 65536 per
# Read() call instead of the bytes actually returned, so it could have reported
# bytes that never arrived; it now counts what Read() says it read.
$ErrorActionPreference = 'Stop'
$out = Join-Path $env:TEMP 'gsc_pcm_count.txt'
Remove-Item $out -ErrorAction SilentlyContinue
$total = 0
try {
    $c = [System.IO.Pipes.NamedPipeClientStream]::new('.', 'gsc_pcm_probe', [System.IO.Pipes.PipeOptions]::Async)
    $c.Connect(10000)
    $b = [byte[]]::new(65536)
    $deadline = (Get-Date).AddSeconds(14)
    while ((Get-Date) -lt $deadline) {
        $n = $c.Read($b, 0, $b.Length)
        if ($n -le 0) { break }
        $total += $n
    }
    $c.Dispose()
} catch {
    $total = -1
}
Set-Content -Path $out -Value $total
Write-Output $total
