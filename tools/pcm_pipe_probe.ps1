# v4 §6.1: read the decoded-PCM tap the fork writes to a named pipe, and report
# the real byte count. The first version of this probe added a fixed 65536 per
# Read() call instead of the bytes actually returned, so it could have reported
# bytes that never arrived; it now counts what Read() says it read.
$ErrorActionPreference = 'Stop'
$out = Join-Path $env:TEMP 'gsc_pcm_count.txt'
Remove-Item $out -ErrorAction SilentlyContinue
$total = 0
try {
    # the 3-arg overload (server, pipe, PipeOptions) does not bind under
    # Windows PowerShell -- "no overload for new takes 3 arguments" -- and the
    # async option buys nothing here because Read() is driven by a deadline
    $c = [System.IO.Pipes.NamedPipeClientStream]::new('.', 'gsc_pcm_probe')
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
    # -1 alone cannot tell a broken probe from an empty pipe, and the first two
    # versions of this script were indistinguishable from a dead tap
    Set-Content -Path (Join-Path $env:TEMP 'gsc_pcm_err.txt') `
        -Value $_.Exception.Message
}
Set-Content -Path $out -Value $total
Write-Output $total
