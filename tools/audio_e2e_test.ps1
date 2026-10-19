# v3 §1.3 gate helper: audio end-to-end on a device that can actually do it.
# A phone below Android 11 cannot capture its own audio, so this exits 2 (= SKIP)
# unless an attached device reports SDK >= 30.
#
# What it asserts, in order:
#   1. the server starts an audio capture (no "Audio disabled" line),
#   2. the decoded PCM tap receives bytes,
#   3. those bytes are real signal, not silence (ffmpeg volumedetect max_volume),
#   4. the client reports no audio error.
# Everything on the device side is read-only: scrcpy's own session and getprop.
param(
    [int]$Seconds = 10,
    [int]$MinSdk = 30,
    [string]$AdbPath = "",
    [string]$ScrcpyPath = ""
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $AdbPath) { $AdbPath = Join-Path $root 'dist\GamingScrcpy\launcher\adb.exe' }
if (-not $ScrcpyPath) { $ScrcpyPath = Join-Path $root 'dist\GamingScrcpy\scrcpy\scrcpy.exe' }

# No Adb() helper: a parameter cannot be named $args (PowerShell's automatic
# variable), and calling the exe with explicit arguments is what keeps the
# quoting honest.
$lines = @(& $AdbPath devices 2>&1 | ForEach-Object { "$_" })
$serials = @($lines | Where-Object { $_ -match '\sdevice$' } |
             ForEach-Object { ($_ -split '\s+')[0] })
if ($serials.Count -eq 0) { Write-Output 'SKIP no adb device attached'; exit 2 }

$chosen = ''
foreach ($s in $serials) {
    $sdk = ("$(@(& $AdbPath -s $s shell getprop ro.build.version.sdk 2>&1 | Select-Object -First 1))").Trim()
    Write-Output "DEVICE $s sdk=$sdk"
    if ($sdk -match '^\d+$' -and [int]$sdk -ge $MinSdk) { $chosen = $s; break }
}
if (-not $chosen) {
    Write-Output "SKIP no device with SDK >= $MinSdk (device audio needs Android 11+)"
    exit 2
}

$pipe = "\\.\pipe\gaming-pcm-gate"
$pcmFile = Join-Path $env:TEMP "gaming-pcm-gate-$([DateTime]::Now.Ticks).pcm"
$server = Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile','-Command',@"
`$p = New-Object System.IO.Pipes.NamedPipeServerStream('$pipe','In',1,'Byte','None',4096,4096,`$null)
`p.WaitForConnection()
`fs = [System.IO.File]::Create('$pcmFile')
`buf = New-Object byte[] 65536
while (`$p.CanRead) { `$n = `$p.Read(`$buf, 0, `$buf.Length); if (`$n -le 0) { break }; `$fs.Write(`$buf, 0, `$n) }
`fs.Close(); `$p.Dispose()
"@)

$log = Join-Path $env:TEMP "gaming-audio-gate.log"
$scrcpyArgs = @("--serial=$chosen", "--no-window", "--video=false",
                "--audio-source=output", "--audio-codec=opus", "--no-audio-playback",
                "--game-audio-pcm=$pipe", "--record=$($pcmFile).mkv")
$proc = Start-Process -FilePath $ScrcpyPath -ArgumentList $scrcpyArgs -WindowStyle Hidden `
        -PassThru -RedirectStandardError $log -RedirectStandardOutput "$log.out"
Start-Sleep -Seconds $Seconds
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$fail = 0
$all = (@(Get-Content $log -ErrorAction SilentlyContinue) +
        @(Get-Content "$log.out" -ErrorAction SilentlyContinue)) -join "`n"
if ($all -match 'Audio disabled|not supported before Android') {
    Write-Output "FAIL server refused audio on an SDK>=$MinSdk device: $((($all -split "`n" | Where-Object { $_ -match 'Audio disabled|not supported before Android' }) | Select-Object -First 1).Trim())"
    $fail++
} else {
    Write-Output 'OK no audio refusal printed by the server'
}
$bytes = if (Test-Path $pcmFile) { (Get-Item $pcmFile).Length } else { 0 }
# Two different empty things look identical from the tap alone: a broken tap,
# and a phone that is simply not playing anything (Samsung mutes the output
# capture entirely when no app is audible). The recorder is the witness: it is
# fed by the same decoded packets, so if it also got nothing, the device was
# silent and this arm cannot judge anything.
$recFile = "$pcmFile.mkv"
$recBytes = if (Test-Path $recFile) { (Get-Item $recFile).Length } else { 0 }
Write-Output "note bytes: PCM tap=$bytes recorder=$recBytes in $Seconds s"
$inconclusive = $false
if ($bytes -lt 8000) {
    if ($recBytes -lt 2000) {
        Write-Output "SKIP the phone handed the client $recBytes audio bytes in $Seconds s: nothing was playing, so the tap cannot be judged"
        $inconclusive = $true
    } else {
        Write-Output "FAIL the client decoded $recBytes bytes of audio but the PCM tap got $bytes (expected a live stream)"
        $fail++
    }
} else { Write-Output "OK PCM tap received $bytes bytes" }
# Peak amplitude straight off the s16le stream. Deliberately no ffmpeg here: the
# gate's bash PATH has it and PowerShell's does not, and a level read that only
# works in one of the two shells is a flaky test waiting to happen.
$peak = 0
if ($bytes -ge 8000) {
    $raw = [System.IO.File]::ReadAllBytes($pcmFile)
    $samples = New-Object int16[] ($raw.Length / 2)
    [System.Buffer]::BlockCopy($raw, 0, $samples, 0, $samples.Length * 2)
    foreach ($s in $samples) { $a = [Math]::Abs([int]$s); if ($a -gt $peak) { $peak = $a } }
    $db = if ($peak -gt 0) { [Math]::Round(20 * [Math]::Log10($peak / 32767.0), 1) } else { -999 }
    if ($db -gt -90) { Write-Output "OK real signal on the PCM tap (peak=$peak samples, ${db} dBFS)" }
    else { Write-Output "FAIL PCM tap is digital silence (peak=$peak, ${db} dBFS)"; $fail++ }
}
if ($all -match '(?i)audio.*(error|failed)') {
    Write-Output 'FAIL the client reported an audio error'; $fail++
} else { Write-Output 'OK no audio error reported by the client' }

Remove-Item $pcmFile, "$($pcmFile).mkv", $log, "$log.out" -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Output "AUDIO-E2E FAIL issues=$fail"; exit 1 }
if ($inconclusive) {
    Write-Output 'AUDIO-E2E INCONCLUSIVE the device played no audio, so the tap had nothing to copy (manual step: start a video or a game on the phone and re-run)'
    exit 2
}
Write-Output 'AUDIO-E2E OK'
exit 0
