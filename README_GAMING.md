# GamingScrcpy — scrcpy 5.0.1 gaming/streaming fork + launcher

A custom build of [scrcpy](https://github.com/Genymobile/scrcpy) v5.0.1 focused
on **gaming, streaming and recording on the PC side**, plus a native launcher
(`GamingScrcpyLauncher.exe`).

The one rule the whole fork obeys: **your phone's internal rendering resolution
is never changed.** No `--max-size`, no `--crop`, no virtual display, no density
change. Everything — upscaling, sharpening, OSD, cursor handling, recording
conveniences, bridges — happens on the PC *after* decoding, so game UI layout
and touch alignment stay exactly as the device produces them.

---

## 1. Layout

```
dist\GamingScrcpy\
├─ launcher\
│   GamingScrcpyLauncher.exe      self-contained .NET 8 (no runtime install)
│   adb.exe, AdbWin*.dll
├─ scrcpy\
│   scrcpy.exe                    the forked client
│   scrcpy-server.jar             version-matched v5.0.1 server (unmodified)
│   scrcpy-server                 same file, name the client looks for
│   gamingdemo.exe                offline validation harness (no phone needed)
│   recorderintegrity.exe         offline recorder harness (no phone needed)
│   SDL3.dll, avcodec-63.dll, avformat-63.dll, avutil-61.dll,
│   swresample-7.dll, swscale-10.dll, …   full transitive dependency set
│   adb.exe, AdbWin*.dll
├─ tools\                         the validation scripts (§7, §8, BUILD_REPORT §5)
├─ README_GAMING.md, BUILD_REPORT.md, PHASE1_AUDIT.md
```

`bash tools/recorder_integrity_test.sh` from an extracted package passes with no
build tree and no phone: it encodes a clip with ffmpeg, muxes it through the
shipped `recorderintegrity.exe`, then decodes the result back. The regression
gate runs exactly that packaged copy as its own section, so the artifact you
download is the artifact that is tested.

The launcher finds `..\scrcpy\scrcpy.exe` automatically. To point it at another
build, write `%APPDATA%\GamingScrcpy\settings.json`:

```json
{ "scrcpy": "C:\\path\\to\\scrcpy.exe" }
```

## 2. Quick start

1. Phone: Developer options → **USB debugging** on.
2. Run `launcher\GamingScrcpyLauncher.exe` → **Rescan ADB**.
3. Pick a profile, press **▶ Mirror (low latency)** or
   **● Mirror + auto-record (dual mode)**.
4. In the mirror window use the runtime shortcuts (§5).

Wireless: **Pair wireless** (Android 11+ → Wireless debugging → Pair device →
enter `ip:port` + 6-digit code), then **Connect ip:port**. For older devices use
**Enable ADB over TCP/IP** while still on USB, then connect to `ip:5555`.

## 3. New command-line options (the fork)

| Flag | Values | What it does (PC side only) |
|---|---|---|
| `--game-osd=` | `none`, `compact`, `full` | On-screen telemetry drawn over the mirrored picture. `full` = FPS, target FPS, video/audio bitrate, latency current/avg/max, source size vs on-screen size, bridge + filter state. |
| `--game-upscale=` | `default`, `nearest`, `linear`, `pixelart` | Host upscale filter for the mirror window. `pixelart` is SDL3's adaptive pixel-art scaler; `linear` is the smooth default; `nearest` keeps raw pixels. |
| `--game-window-filter=` | `off`, `point`, `bilinear`, `fast`, `bicubic`, `lanczos` | Resample the **presented** picture to the exact size of the window content area on the host CPU (true Lanczos / bicubic kernels, not the GPU sampler), so the GPU blits 1:1. Sharper than `--game-upscale` at a CPU cost on the render thread; off by default, and the OSD shows `WIN` while it is active. Needs software decoding (`--hwdec=disabled`; with a hardware interop the GPU path is kept and a warning is logged). |
| `--game-postfx=` | `sharp`, `night`, `sat` (comma list) | Enable CPU post-filters on the host copy of the decoded frame. |
| `--game-sharp=` | 0-100 | CAS-style luma sharpening strength (4-neighbour Laplacian unsharp mask, chroma untouched). |
| `--game-night-boost=` | 0-100 | Shadow lift for dark maps: gamma up to 2.5 plus black-level lift. |
| `--game-saturation=` | 0-200 | Colour grade on the mirrored picture (100 = unchanged). |
| `--game-borderless-fullscreen` | — | Borderless fullscreen sized to the monitor: no DWM frame, but still a normal window, so OBS **Window Capture** and Alt+Tab keep working. |
| `--game-low-latency` | — | Turns off presentation vsync (lowest display latency; may tear). |
| `--game-cursor-autohide=` | ms | Hides the PC cursor when idle, restores it on mouse move. |
| `--game-touch-visualizer` | — | Draws fading touch/pointer markers **on the host overlay** (not on the device). |
| `--game-frame-bridge=` | file, `-`, or `\\.\pipe\name` | Streams presented frames as raw RGBA on a separate thread with a drop-oldest queue. |
| `--game-bridge-scale=` | `WxH` (16-8192 each) | Resample the **bridged** frames to an exact size on the bridge thread, so OBS/FFmpeg get a clean 1080p/1440p/4K feed. Needs `--game-frame-bridge`; the mirror window, the device framebuffer and the touch mapping are untouched. |
| `--game-bridge-filter=` | `default`, `point`, `bilinear`, `fast`, `bicubic`, `lanczos` | Kernel used by `--game-bridge-scale` (swscale). `default` = bilinear. |
| `--game-audio-bridge=` | file, `-`, or `\\.\pipe\name` | Splits the device audio stream (raw encoded packets, no re-encode) to a consumer. |
| `--game-audio-pcm=` | file, `-`, or `\\.\pipe\name` | Second copy of the audio **after decoding**, converted to s16le / 48 kHz / stereo — the format a virtual cable (`VB-Audio`, `VoiceMeeter`) or `ffmpeg -f s16le` actually plays. Works with `--no-audio-playback`, so the game can exist only in the cable. |

Everything upstream still works, with the exact tokens this build accepts
(verified against `scrcpy --help` and its own error messages):
`--video-codec=h264|h265|av1` (note: **h265**, not `hevc`),
`--video-bit-rate=8M…96M`, `--max-fps=30|60|90|120`, `--record=file.mkv|mp4`,
`--record-format=`, `--audio-codec=opus|aac|raw`,
`--render-driver=direct3d11|opengl|vulkan` (there is no `--rendering-driver`),
`--hwdec=auto|disabled|d3d11va`, `--render-fit=letterbox|stretched|unscaled`,
`--keyboard=sdk|uhid|aoa|disabled`, `--mouse=sdk|uhid|aoa|disabled`,
`--gamepad=disabled|uhid|aoa`, `--mouse-bind=`,
`--shortcut-mod=lctrl,lalt,lsuper` (comma separated; the old `s+cc` form was
removed upstream), `--video-buffer=`, `--audio-output-buffer=`.

All three `--render-driver` backends are validated on this host without a phone:
`bash tools/render_driver_test.sh` runs the full presentation path (low-latency
hint, borderless fullscreen, window filter, OSD, frame bridge) through
`direct3d11`, `opengl`, `vulkan` and the no-hint default, and fails if any backend
is silently substituted or if the frame bridge differs by even one byte. There it
is also visible that leaving the option unset selects `direct3d11`.

**Input modes, measured on this build.** The package ships a libusb build, so
`--gamepad=aoa` is accepted and emulates a physical AOAv2 controller (USB only).
`--keyboard=aoa` and `--mouse=aoa` are refused on Windows by upstream design:
*"On Windows, it is not possible to open a USB device already open by another
process (like adb)"*. Use `--keyboard=sdk`, `--keyboard=uhid`, `--mouse=uhid`
instead — those go through ADB and work over Wi-Fi too.

### Audio: silence the phone, keep the sound on the PC

`--audio-source=output` (the launcher default) "forwards the whole audio output,
and disables playback on the device" — the phone's speakers stay silent and the
game audio exists only on the PC, which is what you want while streaming.
`--audio-source=mic` captures the microphone instead.

Three independent audio targets exist, and they can be combined:

| Target | Flag | What it carries |
|---|---|---|
| PC speakers | (default) | decoded audio played through SDL/WASAPI |
| Second recorder / stream | `--game-audio-bridge=` | the device's **encoded** packets, copied without re-encoding (decodes directly when the device sends `--audio-codec=raw`) |
| Virtual cable | `--game-audio-pcm=` | audio **after decoding** as s16le / 48 kHz / stereo — the layout a cable driver or `ffmpeg -f s16le` expects |

For a separate OBS audio track, use the PCM tap with `--no-audio-playback`: the
game sound exists only in the cable, so you monitor it through OBS instead of
hearing it twice. Upstream turns the audio stream off in that situation
(*"No audio playback, no recording: audio disabled"*), so this build counts
either audio output as a consumer and keeps the stream alive. The gate asserts
both directions:

```
PASS  baseline: --no-audio-playback alone disables audio
PASS  --game-audio-pcm keeps audio alive without playback
PASS  --game-audio-bridge keeps audio alive without playback
```

## 4. Recommended setups

### 4.1 Competitive play (lowest latency, sharp image)

```
scrcpy --render-driver=direct3d11 --game-low-latency --max-fps=120 \
       --video-codec=h264 --video-bit-rate=12M --video-buffer=0 \
       --game-upscale=linear --game-osd=full \
       --game-borderless-fullscreen --game-cursor-autohide=1500 \
       --mouse=uhid --shortcut-mod=lsuper,lctrl
```
Latency order of operations: keep the device at native resolution, cap nothing
on the encoder, and do **not** enable `--game-postfx` (see §6).

### 4.2 Streaming with OBS (recommended path)

```
scrcpy --game-borderless-fullscreen --always-on-top --game-osd=compact \
       --render-driver=direct3d11 --game-upscale=linear \
       --video-codec=av1 --video-bit-rate=48M --max-fps=60 --audio-codec=opus
```
In OBS: **Source → Window Capture → "4K Ultra Quality Stream 60FPS"** (the
window title). This is GPU-side, adds no measurable latency, and survives
Alt+Tab. Borderless (not exclusive fullscreen) is exactly what makes it
capturable.

If the picture on your own monitor matters as much as the one OBS sees (a 4K
panel showing a 720p-captured phone), add `--hwdec=disabled
--game-window-filter=lanczos`: the presented frame is resampled with a real
Lanczos(3) kernel and the GPU only blits it 1:1. Costs ~2.5 ms/frame on this
host, needs software decoding, and never changes what the device renders.

For game audio on its **own OBS track** (desktop sound and voice on separate
faders), route the decoded samples into a virtual cable and stay silent
locally:

```
scrcpy ... --audio-codec=opus --game-audio-pcm=\\.\pipe\gaming-pcm \
           --no-audio-playback
```

then in OBS add an Audio Input Capture on `CABLE Output`, or run the ffmpeg
bridge from §8. The launcher exposes the same thing as the *PCM tap* field plus
the *mute PC* checkbox in the STREAMING section.

### 4.3 Recording only, maximum quality

```
scrcpy --record=run-2026-10-16.mkv --record-format=mkv \
       --video-codec=hevc --video-bit-rate=80M --max-fps=60 \
       --no-window --audio-codec=opus --audio-bit-rate=256K
```
The recorder muxes the device's own packets — **no re-encode**, so recording
costs essentially nothing on the PC and cannot degrade the mirror.

### 4.4 Dual mode (mirror live + record at the same time)

Add `--record=file.mkv` to any mirroring command. Recording is a parallel
packet sink next to the display path in scrcpy, so the file and the window
consume the same decoded stream.

## 5. Runtime shortcuts (mirror window)

`Super` (Windows key) or `Alt` + …

| Key | Action |
|---|---|
| F1 | cycle OSD: off → compact → full |
| F2 | borderless fullscreen on/off |
| F3 | touch visualizer on/off |
| F4 | show/hide the PC cursor |
| F5 | always-on-top on/off |

Upstream shortcuts still apply (Alt+Super+… for resize, rotation, clipboard, etc.).

## 6. Measured cost of the post-filters

`gamingdemo.exe --frames=60 --width=720 --height=1280 --fx` on this host
(GCC 16.2, UCRT64, direct3d11):

```
postfx cpu cost avg=3.236ms  max=6.183ms  per 720x1280 frame
```

That is ~7-8 ms/frame at 1080p — enough to eat a 60 fps budget. The filters are
therefore **off by default**, and the OSD exists so you can watch what they cost
on *your* machine. If you want them for a stream but not for play, enable them
only in the recording/bridge profile.

**Recording while mirroring is a different matter: it is nearly free.** Measured
with `recorderintegrity --bench` on 1280x720 H.264 at ~30 kB per packet, pushed
at the stream rate against a live recorder writing to disk
(`BUILD_REPORT.md` §5.1h):

| stream | frame interval | extra cost per delivered frame | slowest single hand-off |
|---|---|---|---|
| 60 fps, 1280x720 | 16 666 µs | 25-63 µs (0.2-0.4 %) | 67 µs - 2.0 ms |
| 120 fps, 1280x720 | 8 333 µs | 13-38 µs (0.5-0.8 %) | 54 µs - 1.7 ms |

The recorder writes the file on its own thread, so what the mirror pays is a
queue hand-off, not disk I/O — and if your disk is briefly slower than the
stream, the queue grows (observed up to 45 packets of 120 at 120 fps) while the
picture stays smooth and the file still ends up complete. That is what makes
"mirror + auto-record" safe for a competitive profile.

### Bridge resample cost (same host, 720x1280 source → 1920x1080, stdout)

Measured inside the bridge thread, per frame, by `gamingdemo.exe`:

```
--bridge-filter=bilinear   resample avg=6.01ms   write avg=10.70ms
--bridge-filter=bicubic    resample avg=7.11ms   write avg= 9.51ms
--bridge-filter=lanczos    resample avg=9.42ms   write avg= 9.79ms
--bridge-filter=point      resample avg=10.35ms  write avg=10.66ms
--bridge-scale=3840x2160   lanczos avg=28.25ms   write avg=39.22ms
```

Read these as *bridge-thread* cost, never as added mirror latency: the render
thread only copies the frame into a queue, and the queue is drop-oldest, so a
slow kernel or a stalled consumer shows up as `frame bridge: N frames dropped`
in the log, not as a stuttering window. The `point` row measured slower than
`bilinear`, which is a reminder that on this laptop the differences under ~2 ms
are run-to-run noise; the 4K row is the real signal (4x the pixels, ~3x the
time). Writing an uncompressed 1080p feed costs ~10 ms/frame by itself, so for
OBS prefer **Window Capture** and keep the bridge for FFmpeg consumers.

### Window kernel cost (`--game-window-filter`, render thread)

Same host, `gamingdemo.exe --window-filter=…`, measured on the presented path
(each run also drags the window and toggles borderless fullscreen, so the
`rebuilds` counter is non-zero):

```
360x640   -> 416x752    point 0.32ms  bilinear 0.39ms  bicubic 0.46ms  lanczos 0.68ms
720x1280  -> 432x768    lanczos 1.75ms (4 rebuilds, 4 distinct presented sizes)
540x960   -> 1232x2192  bicubic 2.05ms  lanczos 2.51ms   (2.3x upscale, 4K-class)
1080x1920 -> 816x1440   bicubic 2.49ms  lanczos 2.91ms   (1440p window)
```

Unlike the bridge, this **is** on the critical path: 2.5 ms added to a frame
still fits a 60 fps budget (16.7 ms) but eats ~30 % of a 120 fps one. That is
why the default is `off` and why the competitive profile keeps the GPU sampler.
The presented size is quantized to 16 px, so dragging the window rebuilds the
resampler a handful of times instead of on every mouse move; the log prints
`window filter: … resampled, avg=X ms (N rebuilds)` on exit.

### Which render backend to pick

All three accelerated backends that `--render-driver` accepts are exercised by the
gate — `bash tools/render_driver_test.sh` — and on each one the window initializes,
presents every frame and feeds the frame bridge, with no silent substitution of a
different backend. Leaving the option unset selects `direct3d11` on this host, so
that is also the path every other measurement in this file was taken on. `opengl`
and `vulkan` behave identically in the sweep, so change it only if a specific
driver misbehaves (a black window after a GPU driver update, or a capture source
that only sees one backend). Nothing about the device stream changes with the
choice: the bytes that reach the PC are produced before the renderer is involved.

That sweep counted frames, and frames are not latency. Against a real device,
`--game-telemetry-log` measured this host presenting through `vulkan` at a median
of 699 ms versus 69 ms through `direct3d11` with the same stream (BUILD_REPORT
§5.1n). So: keep `direct3d11` unless you have a reason not to, and if you do
change it, compare the two medians on your own machine before deciding — the
numbers move with the GPU driver, not with the docs. The same runs showed AV1
mirroring cost 16 fps here, because this GPU has no hardware AV1 *decoder*
(`--video-codec=av1` then falls back to the CPU): use AV1 for recording, where
nothing is decoded, and h264 or h265 for the live mirror.

For the lowest presentation latency the two flags that consistently helped here
were `--video-buffer=0` (mean 20-34 ms instead of 48-169 ms) and
`--game-low-latency`, though the second one flipped between codecs and runs —
measure it with `--game-telemetry-log` rather than trusting this table:

```
scrcpy --video-buffer=0 --game-low-latency --game-telemetry-log
```

### Known issue: `--game-borderless-fullscreen` at startup

Measured against the real window (`tools/window_style_probe.ps1`, BUILD_REPORT
§5.1r): with this flag SDL does apply the borderless display-sized window
(`borderless: requested 1366x768, SDL reports 1366x768`) but the window ends up
at the content size (1270x592 on a 1366x768 desktop) because the first video
frame resizes it, and the two auto-resize paths guarded so far are not the ones
doing it. `--help` says this explicitly rather than promising a borderless
fullscreen. Until it is fixed, use `--always-on-top` (verified: `WS_EX_TOPMOST`
really is set) with a normal window, or `--fullscreen` for upstream's exclusive
fullscreen. The Super+F2 toggle runs the same code and was not measured in this
session, so treat it as "try it and look" rather than a workaround.

## 7. Validate it on your hardware

Some of this has now been run against a real device (Lenovo TB-9707F, SM8550,
Android 14 — see `BUILD_REPORT.md` §5.1l): mirroring with the OSD, hardware decode,
recording at full native 1080x2316 without touching the tablet's own resolution,
the device's audio captured as 48 kHz stereo and muxed, measured A/V offsets, and
the codec matrix — **all three codecs encode there**, and AV1 came out ~4× smaller
than h264 on the same screen even though the server logs one harmless
`IllegalArgumentException` per AV1 session, so judge a codec by the recorded file
and not by the log. The packaged launcher was also driven through its own UI: it
listed the device, started the mirror with the right `--serial`, and Stop ended the
session (`bash`/`powershell -File tools/launcher_device_test.ps1`, gate section 11).
What still needs your hands and eyes:

1. `scrcpy --game-osd=full` → confirm FPS/bitrate/latency move and that
   `SRC` equals the phone's native capture size (it must not change when you
   resize the window — only `ON` changes). For numbers you can keep, add
   `--game-telemetry-log`: it prints the same values once a second and a
   `lat_med/lat_p90/lat_max` summary when the session ends, which is how
   BUILD_REPORT §5.1n was measured (`bash tools/device_latency_probe.sh`
   repeats it against a connected phone).
2. `scrcpy --record=test.mkv --video-codec=h265` → play, stop with `Ctrl+C`,
   then `ffprobe test.mkv` and compare duration to wall clock. The muxing half of
   that is already proven without a phone (`bash
   tools/recorder_integrity_test.sh`, see `BUILD_REPORT.md` §5.1g: real H.264,
   HEVC and AV1 streams are pushed through the recorder and the result is decoded
   back frame by frame, in both containers, with a raw-PCM audio track interleaved
   by pts, and with the recorder stopped mid-stream so the trailer — including the
   MP4 `moov` — is written by the Ctrl+C path), so what this check adds is the
   *device's* encoder. Do watch the OSD FPS while `--record` runs: the host side
   of that claim is measured (`BUILD_REPORT.md` §5.1h — 13-63 µs per delivered
   frame, i.e. no visible drop), but what the phone does while mirroring *and*
   feeding a recorder is its own question. Related: this fork fixes an upstream
   race on exactly this path — the recorder used to publish its muxer context
   without holding the mutex, so a client could crash as soon as the producer
   attached its sinks before the recorder thread had finished opening the file
   (`BUILD_REPORT.md` §5.1i).
3. A/V sync: record with `--audio-codec=opus` and clap once on camera at the
   start; the waveform spike should sit within ~1 frame of the visual clap.
   (The recorder itself is already proven to interleave two timelines by pts and
   to cut both at the same place when stopped — §5.1g — and the two bridges are
   duration-locked host-side, see §8. What this check adds is the device's own
   capture alignment, which nothing on the PC can produce.)
4. Touch alignment: with `--game-borderless-fullscreen` and `--game-upscale=linear`,
   tap in the screen corners; the device must react where you tapped.
5. Bridge: `scrcpy --game-frame-bridge=\\.\pipe\gaming-frame` and consume it
   (§8) while playing — the mirror must stay smooth even if you kill the
   consumer mid-run (drop-oldest queue).
6. Bridge resample: add `--game-bridge-scale=1920x1080
   --game-bridge-filter=lanczos` to the same command. The consumer must see
   1920x1080 frames and the `<path>.meta.txt` sidecar must report that size,
   while the phone still captures at its own native resolution.
7. Window kernel: `scrcpy --hwdec=disabled --game-window-filter=lanczos
   --game-osd=full`, then drag the window. `ON` in the OSD and the log line
   `window filter: lanczos resample WxH -> WxH` must follow the window, the
   touch mapping must stay exact, and the exit log must report the measured
   `avg=X ms` for your CPU. Compare with `--game-window-filter=off` to judge
   whether the extra milliseconds are worth it at your target FPS.
8. Audio splitter: `scrcpy --game-audio-pcm=\\.\pipe\gaming-pcm
   --no-audio-playback` (from cmd or PowerShell) and play music on the phone.
   The PC speakers must stay silent while the cable carries sound, the log must
   show one `pcm tap: <rate> Hz / <n> ch / <fmt> -> 48000 Hz s16le stereo`
   line, and killing the consumer must not stutter the video (the tap is
   drop-oldest, so it can only lose audio chunks, never block the decoder).

9. **Wireless ADB, by hand** — the launcher will not do this for you. Switching
   the device to TCP mode rewrites how `adbd` listens, i.e. it is a *write* on a
   device that this project treats as read-only (see the note below and
   `BUILD_REPORT.md` §5.2). Run it yourself, once, while USB is attached:
   ```
   adb tcpip 5555
   adb shell ip addr show wlan0     # or read it in Settings > Wi-Fi > the network
   adb connect 192.168.1.20:5555    # unplug the cable first
   ```
   After that the launcher's **Pair wireless** / **Connect ip:port** buttons work
   normally: they only touch the host side of the transport. Android 11+ can skip
   the cable entirely with *Developer options > Wireless debugging > Pair device*,
   and the pairing command it shows is what **Pair wireless** expects.
10. **On-device touch dots** — two different features, easy to confuse:
    * the launcher's **Touch visualizer** maps to this fork's
      `--game-touch-visualizer` and draws rings **on the PC picture only**;
    * Android's own dots are a device setting. Ask scrcpy to set them with its
      built-in `-t` / `--show-touches` — the server enables it and *restores the
      initial value on exit*, which is scrcpy's own design and stays inside the
      read-only rule. Note it "only shows physical touches (not clicks from
      scrcpy)". The launcher will not run a settings command for you.
11. **Silencing the phone while keeping the sound on the PC** — this build has no
    `--mute-device`; its help offers `--audio-source=output`, which "forwards the
    whole audio output, and disables playback on the device". That is already the
    launcher's default (`audioSource` in the profile JSON, `output`; there is no
    dropdown for it yet). For the reverse (PC silent, OBS still fed) use
    `--no-audio-playback`, which is what the `ChkPcmMute` checkbox appends
    together with the PCM tap.

### The read-only rule

The test device is somebody's real tablet, so no script, launcher button, test or
tool in this project writes to it: nothing installs or pushes files, nothing
changes a system setting, resolution, DPI or the ADB transport. Only
`adb devices`, `getprop`, read-only `dumpsys`, and whatever scrcpy itself does by
design (video/audio streaming, input injection, its own screen-on/off) are used.
Gate section 14 greps `tools/`, `launcher/`, `scripts/` and this fork's own
diff against upstream for that blacklist and fails on any hit, with a fixture
(`tools/fixtures/device_write_adb_install.sh`) that it must *detect* so a broken
grep cannot pass in false. Every command a harness runs is appended to
`out/dev/adb_audit.log`. If a check would need a device write, it is documented
above as a manual step instead of being automated.

## 8. OBS / FFmpeg frame and audio bridge

The frame bridge writes **raw RGBA** frames plus a `<path>.meta.txt` sidecar
with the exact size. If the phone captures 1080x1920 but you want the consumer
to receive a fixed 1080p picture, add
`--game-bridge-scale=1920x1080 --game-bridge-filter=lanczos`: the resample runs
on the bridge thread, the sidecar reports the *output* size, and nothing about
the mirrored window or the device framebuffer changes.

```bat
:: watch it
ffplay -f rawvideo -pixel_format rgba -video_size 1080x1920 "\\.\pipe\gaming-frame"
:: encode it to a second file without touching the mirror
ffmpeg -f rawvideo -pixel_format rgba -video_size 1080x1920 ^
       -i "\\.\pipe\gaming-frame" -c:v libx264 -preset veryfast out.mp4
:: with --game-bridge-scale=1920x1080 the consumer line becomes
ffplay -f rawvideo -pixel_format rgba -video_size 1920x1080 "\\.\pipe\gaming-frame"
```

Audio bridge (raw encoded packets, so nothing is re-encoded):

```bat
:: --audio-codec=raw: the pipe carries 48 kHz stereo s16le, decode it directly
ffmpeg -f s16le -ar 48000 -ac 2 -i "\\.\pipe\gaming-audio" -f wasapi "CABLE Output"
:: --audio-codec=opus|aac: the bridge forwards the encoded packets verbatim,
:: with no container, so the consumer must do its own depayloading (an OBS
:: audio source fed from the mirrored session is usually the simpler route)
```
Point that at a virtual cable (VB-Audio / VoiceMeeter) to route game audio into a
separate OBS track.

PCM tap (decoded audio, the format a cable driver plays). Because the tap is a
sink of the **audio decoder**, it keeps working with `--no-audio-playback`, which
is the configuration you actually want for a separate OBS track — the game audio
goes to the cable and nowhere else, so you do not hear it twice:

```bat
scrcpy --audio-codec=opus --game-audio-pcm=\\.\pipe\gaming-pcm --no-audio-playback
:: consumer (no codec guessing, no container, always this exact layout)
ffmpeg -f s16le -ar 48000 -ac 2 -i "\\.\pipe\gaming-pcm" -f wasapi "CABLE Output"
```

The tap converts whatever the device sends (any sample rate, any channel count,
planar or interleaved) to 48 kHz stereo s16le with libswresample, logs the
conversion once (`pcm tap: 48000 Hz / 2 ch / flt -> 48000 Hz s16le stereo`) and,
like the other bridges, drops the oldest chunk instead of blocking the decoder.
Verified by `tools/bridge_encode_test.sh`: a 44.1 kHz mono float feed comes out
of the tap as a decodable 48 kHz / 2 ch stream (`RESULT pcm_tap=153532B
rate=48000 ch=2 duration=0.799646 max_vol=-9.0dB`).

Over a real named pipe it is verified by `tools/pcm_tap_pipe_test.ps1`, which
runs a `\\.\pipe\gaming-pcm` consumer and checks what arrives:

```
pcm tap: consumer connected (\\.\pipe\gaming-pcm)
pipe consumer received: 767932 B in 200 reads
ffmpeg decoded the piped bytes as 48 kHz stereo, max_volume=-9 dB
```

200 frames × 3840 B = 768,000 B produced, 767,932 B received (the 68-byte
difference is swresample's priming delay), no chunk dropped.

**Both feeds are encoder-verified, not just byte-checked.** The build machine
has no phone, so instead of trusting the byte counts, `gamingdemo` can emit a
real 48 kHz stereo PCM stream on the audio bridge (`--audio-sine`, one 16.7 ms
packet per rendered frame) and the two raw files are then pushed through
ffmpeg:

```
RESULT frames=40 audio_chunks=40 vsize=640x360
RESULT codecs=h264+aac durations=0.666667/0.666667 delta=0.000000
OK
```

So the frame bridge decodes as a proper video stream at the configured size and
the audio bridge decodes as PCM, and because both are produced by the same
frame loop their durations come out identical — the host-side half of the A/V
question. Reproduce with `bash tools/bridge_encode_test.sh 40 640x360`.

**Order of operations, measured:** the bridge connects from its own thread and
retries for 10 s, so it does **not** matter whether scrcpy or the consumer
starts first. Consumer already listening → connected on the first frame.
Consumer joins 2 s late → `waiting for a consumer`, then `consumer connected`,
and everything after that point is streamed (the frames produced while nobody
was reading are discarded, never queued, so the decoder is never pinned).
Consumer never appears → the bridge logs one error after 10 s and disables
itself; the mirror is unaffected and startup never blocked.

Reproduce that yourself with `tools/bridge_pipe_test.ps1` (it runs all three
orderings against `gamingdemo.exe` and checks the byte math),
`tools/bridge_audio_pipe_test.ps1` for the encoded splitter (400 packets →
80,000 bytes received, none lost) and `tools/pcm_tap_pipe_test.ps1` for the PCM
tap (200 frames → 767,932 bytes received, then decoded again by ffmpeg).

**Shell warning:** in Git Bash / MSYS2, `\\.\pipe\name` gets mangled into
`\.\pipe\name` before scrcpy sees it, so the bridge treats it as a file and
never connects. Run pipe commands from `cmd` or PowerShell, or export
`MSYS2_ARG_CONV_EXCL='*'` first.

**Honest scope note:** this fork does not install a DirectShow "virtual camera"
COM filter — that would need a separate registered system component. OBS
Window Capture on the borderless window is the supported path; the pipe is for
FFmpeg-based consumers.

## 9. Launcher features

* **Device auto-detection** — `adb devices -l` plus `adb mdns services` for
  wireless-only devices; USB vs Wi-Fi classified; model read with `getprop`.
* **Language** — Español / English selector in the header. Everything visible
  (labels, combo items, tooltips, status text, dialogs, the run log and the
  command preview) comes from one table in `launcher/Loc.cs`, and the choice is
  remembered. Gate section 15 fails if a key is missing in either language.
* **Device panel** — model, battery level and temperature, read with read-only
  `getprop` / `dumpsys battery`. Nothing in the launcher writes a device setting.
* **Performance tab** — live latency / FPS / video and audio bitrate read from
  the fork's `--game-telemetry-log` lines (the launcher adds that flag), with a
  1 Hz latency sparkline.
* **Profile manager** — JSON presets in `%APPDATA%\GamingScrcpy\profiles`,
  seeded with ten profiles: *Competitive COD Mobile 120FPS*, *4K Ultra Quality
  Stream 60FPS*, *Recording Only*, *Night/Dark Game Boost*, plus **Lowest
  latency**, **Competitive 120 (host scale)**, **Balanced HEVC 60**, **Recording
  only (clean)**, **Stream OBS (pipes)** and **Wi-Fi low bandwidth**.
  New/Load/Save/Delete, plus Export/Import as JSON. Every one of them is checked
  against the real `scrcpy.exe` by the launcher's own `--validate-profiles` mode.
  None sets `--max-size`, `--crop` or a display id: the device keeps its own
  resolution (see the note in §7 about doing that yourself).
* **One-click launch** — Mirror, Mirror + auto-record, Record only (no window),
  Stop, **Wireless ADB guide** (it shows the manual procedure instead of
  reconfiguring the device), Pair wireless, Connect ip:port.
* **Encoder preset** — `device default / ultrafast / fast / medium`, emitted as
  `--video-codec-options=latency:int=N` (MediaFormat's latency key, the closest
  Android equivalent of an x264 preset; a hardware encoder may ignore it). The
  `key:type=value` spelling matters: `latency:9` alone is rejected by the server.
* **Visual configurator** — discrete dropdowns where an invalid value would be a
  silent bug: max FPS (15/20/25/30/40/50/60/90/120/144), video bitrate
  (5…80 Mb/s in 5s), video buffer (0…200 ms), audio bitrate (32…512 kbps),
  audio output buffer (0…500 ms). A profile holding an off-step value is
  normalised to the nearest step before it runs, so the preview always shows the
  real command. Sliders stay only where a continuous value is meaningful (cursor
  auto-hide, sharpness, shadow lift, saturation); dropdowns for codec, renderer,
  upscale filter,
  **window kernel** (`off` = GPU sampler, `lanczos`, `bicubic`, `bilinear`,
  `fast`, `point` — the CPU resample of the presented frame), host
  target size (1080p/1440p/4K/portrait), fit mode, OSD level, container,
  keyboard/mouse/gamepad mode, hardware decode; frame-bridge target size with
  1080p/1440p/4K quick buttons and a resample-kernel dropdown (Lanczos, bicubic,
  bilinear, fast, point); *Audio bridge* (encoded packets) and *PCM tap*
  (decoded s16le / 48 kHz / stereo) path fields with a *mute PC* checkbox that
  adds `--no-audio-playback`; free-text extra arguments.
* **Keymap / controller loader** — JSON keymaps in
  `%APPDATA%\GamingScrcpy\keymaps` (seeded: *KB-M Mouse Aim (COD/PUBG)*,
  *Gamepad (U-HID)*); applying one sets `--keyboard`, `--mouse`, `--gamepad`,
  `--mouse-bind` and `--shortcut-mod`, and lists the bindings.
* **Live command preview** + "Copy command line" + "OBS: copy ffplay command",
  and a run log that captures scrcpy's own output (including the FPS/bitrate
  lines it logs) and reports the recording path and size on exit.

## 10. Rebuilding from source

```bash
# 1. toolchain (once)
winget install --id MSYS2.MSYS2 --silent
/c/msys64/usr/bin/bash -lc "pacman -Syu --noconfirm && \
  pacman -S --noconfirm --needed \
    mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-meson \
    mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-pkgconf \
    mingw-w64-ucrt-x86_64-sdl3 mingw-w64-ucrt-x86_64-ffmpeg \
    mingw-w64-ucrt-x86_64-libusb"

# 2. client + demo   (meson must run from the REPO ROOT, not app/)
cd workspace/scrcpy
export PATH=/ucrt64/bin:$PATH
# the shipped binary is the libusb build (AOA gamepad support):
meson setup build-usb --buildtype=release -Dv4l2=false -Dcompile_server=false
ninja -C build-usb
./build-usb/app/gamingdemo.exe --frames=120 --fx --bridge=b.raw --shot=s.bmp  # self-check

# 2b. verify everything the docs claim, in one command (59 checks)
bash ../../tools/verify_all.sh

# 3. server (only if you change Java): needs the Android SDK (compileSdk 36)
./gradlew :app:assembleDebug   # produces server/build/.../scrcpy-server

# 4. launcher
cd ../../launcher
dotnet publish -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -o ../dist/GamingScrcpy/launcher
```

## 11. Known limitations

* USB HID (`--otg`) works in the shipped build (libusb 1.0.30, `-Dusb=true`),
  but needs the device released from ADB, so it is a separate session rather
  than something the launcher starts alongside mirroring.
* There is no GLSL/HLSL pass: scrcpy 5.0.1 presents through `SDL_Renderer`
  (no shader pipeline to hook) and SDL 3.4 exposes only
  `nearest|linear|pixelart` texture scale modes. The high-quality kernels in
  this fork are therefore **host CPU swscale** passes — true Lanczos(3)/bicubic
  for the bridged stream (`--game-bridge-*`) and for the presented frame
  (`--game-window-filter`), plus the CAS-style sharpening in `--game-postfx`.
* `--game-window-filter` needs software decoding. With `--hwdec=d3d11va` (or
  `auto` picking it) the frames never become `YUV420P` on the host, so the
  interop would reject a resampled frame; the build logs
  `frames are not YUV420P … GPU scaling kept` and carries on unchanged instead
  of failing.
* Touch visualizer markers follow host pointer/finger events mapped into the
  content rectangle; the device-side `--show-touches` (system setting) is a
  different, device-rendered feature and is not enabled by this fork.
* No DirectShow virtual camera (§8).
