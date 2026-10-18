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

While its window is in the foreground and no session is running, the launcher
repeats that same read-only scan every 3 s: plugging the phone in after the
launcher is already open needs no click, and **Rescan ADB** still works when you
want one immediately. It never repaints an unchanged device list (your selection
and the run log stay put) and it stops by itself if `adb` disappears — the log
then says to use **Rescan ADB**.

Wireless: **Pair wireless** (Android 11+ → Wireless debugging → Pair device →
enter `ip:port` + 6-digit code), then **Connect ip:port**. For older devices use
**Enable ADB over TCP/IP** while still on USB, then connect to `ip:5555`.

## 3. New command-line options (the fork)

| Flag | Values | What it does (PC side only) |
|---|---|---|
| `--game-osd=` | `none`, `compact`, `full` | On-screen telemetry drawn over the mirrored picture. `full` = FPS, target FPS, video/audio bitrate, latency current/avg/max, source size vs on-screen size, bridge + filter state. |
| `--game-upscale=` | `default`, `nearest`, `linear`, `pixelart` | Host upscale filter for the mirror window. `pixelart` is SDL3's adaptive pixel-art scaler; `linear` is the smooth default; `nearest` keeps raw pixels. |
| `--game-window-filter=` | `off`, `point`, `bilinear`, `fast`, `bicubic`, `lanczos` | Resample the **presented** picture to the exact size of the window content area on the host CPU (true Lanczos / bicubic kernels, not the GPU sampler), so the GPU blits 1:1. Sharper than `--game-upscale` at a CPU cost on the render thread; off by default, and the OSD shows `WIN` while it is active. Needs software decoding (`--hwdec=disabled`; with a hardware interop the GPU path is kept and a warning is logged). |
| `--game-postfx=` | `sharp`, `night`, `sat`, `contrast`, `brightness`, `gamma` (comma list) | Enable CPU post-filters on the host copy of the decoded frame. A filter only runs when its own name is here: naming `gamma` without `--game-gamma=` changes nothing instead of blacking out the picture. |
| `--game-sharp=` | 0-100 | CAS-style luma sharpening strength (4-neighbour Laplacian unsharp mask, chroma untouched). |
| `--game-night-boost=` | 0-100 | Shadow lift for dark maps: gamma up to 2.5 plus black-level lift. |
| `--game-saturation=` | 0-200 | Colour grade on the mirrored picture (100 = unchanged). |
| `--game-contrast=` | 0-200 | Luma contrast pivoted at mid grey (100 = unchanged). Shares one 256-entry table with brightness, gamma and night-boost, so the whole grade is a single pass over the Y plane. |
| `--game-brightness=` | 0-200 | Luma offset, 100 = unchanged, 0 = black, 200 = white. Brightens the **PC's** picture: it never writes the device's screen brightness (guarded by `tools/device_filter_test.sh`, which compares a read-only `dumpsys display` snapshot before and after). |
| `--game-gamma=` | 25-200 | Luma transfer curve, 100 = unchanged, above brightens the mid-tones. Below 25 is rejected: the curve would only crush the picture to black. |
| `--game-filter-overlay` | — | Open the **real-time filter panel**: a borderless always-on-top window of its own (496×400) that edits the six `--game-postfx` parameters while the session runs. It adds no pass to the mirrored frame — the sliders only write the engine's parameters — and it is hidden until the hotkey opens it. |
| `--game-overlay-hotkey=` | combo | Global hotkey that shows and hides that panel, written as modifiers joined by `+` plus one key: `super+alt+f` (the default), `ctrl+shift+f9`. Valid modifiers are `ctrl`/`control`, `alt`, `shift`, `super`/`win`/`meta`; valid keys are `f1`-`f9`, one letter or one digit, and at least one modifier is required. Avoid `super/alt+F1-F5`: those are the mirror's own runtime toggles. Registered with Windows, so it works when the mirror is not focused; if another program owns the combo, the log says so and the same key still toggles the panel while the mirror has focus. |
| `--game-overlay-visible` | — | Show the panel at session start instead of waiting for the hotkey. |
| `--game-overlay-english` | — | Paint the panel's labels in English (Spanish is the default; the launcher passes this when its own language is not Spanish). |
| `--game-filter-profiles=` | path | File the panel reads and writes its grades in: one `current c s b g sh n` line plus `profile NAME c s b g sh n` lines. Without it the panel works but says it cannot save. The launcher keeps its grades in this format at `%APPDATA%\GamingScrcpy\filters.profiles`, so a look survives a session restart and travels with the session profile. |
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

The codec has to exist on the phone, not just on the PC: an AV1 encoder needs
Android 10 (SDK 29) and any device audio needs Android 11 (SDK 30). The launcher
reads `ro.build.version.sdk` (read-only `getprop`) when it lists a device, and if
an AV1 profile is launched against an older phone it substitutes h264 and writes
that into the log instead of starting a session the device cannot serve — seen on
a moto g(7) power (Android 9, SDK 28), where the same profile with h264 mirrors
normally and AV1 kills the server before a window appears.

All three `--render-driver` backends are validated on this host without a phone:
`bash tools/render_driver_test.sh` runs the full presentation path (low-latency
hint, borderless fullscreen, window filter, OSD, frame bridge) through
`direct3d11`, `opengl`, `vulkan` and the no-hint default, and fails if any backend
is silently substituted or if the frame bridge differs by even one byte. There it
is also visible that leaving the option unset selects `direct3d11`.

**Which one to actually use, measured against the tablet.** `direct3d11` —
`tools/device_latency_matrix.sh` measured the worst frame of each second over
12 s windows and the backends are not equal: `direct3d11` 48-266 ms median,
`vulkan` 1129/1150 ms, `opengl` 604/1607 ms (with and without
`--game-low-latency`, all three still presenting at 54-62 fps). The first two
columns are inside the run-to-run noise of this harness (the reference
configuration alone measured 48, 166 and 198 ms), so only the backend gap is a
conclusion the data supports: the other two backends work, they are just an
order of magnitude slower to present on this GPU/driver combination.

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

Two things make the difference between bytes and silence when you test this by
hand (both cost a debugging round here, see BUILD_REPORT §5.1au):

* **The reader must own the pipe.** scrcpy dials out (`CreateFile`), so the
  consumer has to be a pipe *server*:
  `New-Object System.IO.Pipes.NamedPipeServerStream('gaming-pcm','InOut')` in
  PowerShell, `\\.\pipe\gaming-pcm` as an OBS/ffmpeg input, or the VB-cable
  device. A second `NamedPipeClientStream` waits for a connection that neither
  side can offer.
* **Start the client from `cmd` or PowerShell, not from MSYS/`bash`.** bash's
  argument conversion turns `'\\.\pipe\name'` into `'\.\pipe\name'`; scrcpy then
  reads it as a file name and, after 10 s, prints `no consumer on ...` — which
  looks like a broken tap but is a mangled argument. `MSYS2_ARG_CONV_EXCL='*'`
  also fixes it if the command has to live in a shell script.

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

The same list is inside the launcher: **Rápido → ATAJOS** opens it as a grouped
table (keycap · action · description), in whichever language the launcher is in.
The table lives in `launcher/Shortcuts.cs` as data, is checked by
`GamingScrcpyLauncher.exe --validate-shortcuts`, and gate section 17 fails if a
row loses a cell, a translation or repeats a combination inside its category.

`MOD` means the shortcut modifier, `Super` (Windows key) or `Alt` by default —
change it with `--shortcut-mod=f1,super`. Key combinations are not translated.

| Key | Action | Note |
|---|---|---|
| **Mirror / device** | | |
| `Super/Alt+F1` | Cycle the OSD | off → compact → full |
| `Super/Alt+F3` | Touch visualizer | rings on the PC image only |
| `Super/Alt+F4` | Show/hide the PC cursor | |
| `MOD+O` | Turn the device screen off | mirror and audio keep running |
| `MOD+Shift+O` | Turn the screen back on | without touching the power button |
| `MOD+R` | Rotate the device | |
| `MOD+H` / `MOD+B` / `MOD+S` | Home / Back / App switch | |
| `MOD+M` | Menu | |
| `MOD+Up` / `MOD+Down` | Volume up / down | |
| `MOD+P` | Power | |
| **Window** | | |
| `Super/Alt+F2` | Borderless fullscreen on/off | see §6 for the startup defect |
| `Super/Alt+F5` | Always-on-top on/off | |
| `MOD+F` / `F11` | Fullscreen | |
| `MOD+G` | Resize the window to 1:1 pixels | one screen pixel per picture pixel |
| `MOD+W` | Remove the black borders | the window shrinks to the image |
| `MOD+Shift+N` | Collapse the panels | closes the notification/settings shade |
| `MOD+Q` | Quit | |
| **Other** | | |
| `MOD+C` / `MOD+V` | Copy from / paste to the device | |
| `MOD+Shift+V` | Inject the clipboard as text | |
| `MOD+I` | Show the performance counters | |
| `MOD+Z` / `MOD+Shift+Z` | Pause / resume the stream | |
| `MOD+Shift+R` | Restart the video encoder | |
| `MOD+N` | Open the notification panel | |
| **Filters (the panel is the client's own window, not the mirror's)** | | |
| `Super+Alt+F` | Show / hide the real-time filter panel | global: works with any other app focused; change it in **Filtros → Panel de filtros** |
| `Esc` | Close the panel | also the only key that works if the combo is taken or unparsable |

Inside the panel (Spanish labels, English with `--game-overlay-english`): drag its
header to move it, `REINICIAR` puts the six sliders back to neutral, `GUARDAR`
writes a named grade and `CARGAR` cycles the stored ones — before any profile file
exists it cycles the five built-in presets Neutral, Vivid, Cinematic, Night and
Competitive. `CANCELAR` returns to the values the panel was opened with, and
`APLICAR` re-applies and persists the grade as `current`. Every slider is already
live while you drag it — none of these buttons is what makes the picture change.
Keyboard: `Tab` cycles the highlight over the six sliders and five buttons,
`Left`/`Right` move a highlighted slider by 5, `Return` presses a highlighted
button, `Esc` closes the panel.

Recording has no shortcut in scrcpy 5 (`MOD+r` is *rotate*), so the launcher does
not invent one: start a recording from the launcher buttons or with
`--record-file`. The filters *do* have one now (`Super+Alt+F`, above); the
**Filtros** tab still sets the grade the session starts with, and the panel edits
that same engine state while it runs.

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

### Opening the panel adds nothing to that number

`bash tools/overlay_test.sh` (gate section 18) runs **each arm twice** with the
same grade — once with no panel, once with the panel open and a show/hide toggle
every 150 frames — and compares the engine's own per-frame census best-rep
against best-rep. That is deliberate: p99 of a CPU-bound pass on a desktop that
is also streaming a phone is dominated by other processes, and one contended rep
moves it by more than the feature under test (the same arm measured 4.855 ms and
9.347 ms in two consecutive reps). Every raw census is printed, so the comparison
stays checkable. The table is one such pair from a quiet desktop
(`out/ov/v3_pr6_overlay.log`):

| run (720x1280, 1000 frames, same grade) | median | p90 | p99 | fps presented |
|---|---|---|---|---|
| no panel | 3.273 ms | 3.811 ms | 5.466 ms | 63.2 |
| panel open + toggles | 3.277 ms | 3.892 ms | 5.472 ms | 64.0 |

|Δmedian| is 0.004 ms and |Δp99| 0.006 ms: the panel only writes parameters, so
the mirror's pipeline is the same code path with the same cost. The panel's own
tick is 12-20 µs when idle and repaints only while you interact (a 496x400
software repaint costs 5-10 ms, and it happens on the panel's window, never on
the mirror's). The directive also asks for `p99 < 3 ms` in absolute terms: the
filter engine alone exceeds that (5.466 ms with no panel at all), so the gate
reports the cap as a measured NOTE with both numbers instead of pretending the
cap passed or degrading the feature to a launcher panel.

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
12. **Brighter dark games, without touching the tablet's settings** — every
    picture filter (`--game-sharp`, `--game-night-boost`, `--game-saturation`,
    `--game-contrast`, `--game-brightness`, `--game-gamma`) is applied on the PC
    to a copy of the decoded frame. The tablet renders exactly what it always
    did; its own brightness, resolution and DPI are never written. Where the
    grade does and does not go: a `--record` file is built from the encoded
    packets coming off the device, so it is never filtered, while
    `--game-frame-bridge` ships the frame that is actually presented, so OBS
    receives the graded picture. If you want the look only on your monitor and
    not in OBS, grade in OBS instead. To see it on your hardware, mirror with
    `--game-postfx=night,brightness --game-night-boost=60 --game-brightness=115`
    and compare against the same scene without the flags. The automated proofs are
    `bash tools/fx_pixel_test.sh` (per-filter pixel statistics, plus PNG dumps of
    every setting under `out/fx/`) and, on a real device,
    `bash tools/device_filter_test.sh`, which additionally asserts the tablet's
    brightness state read before and after is identical.
13. **A mirror that opens and closes itself on an older phone** — if the log
    panel shows a `MediaCodec.createEncoderByType` / `SurfaceEncoder` stack and
    `scrcpy exited with code 2`, the phone refused to create its video encoder;
    nothing on the PC is wrong. Measured on a moto g(7) power (Android 9): 5 of 6
    back-to-back launcher sessions died that way at 60 fps / 50 Mbps, while the
    identical command line run from a terminal started normally, and the launcher
    worked again after ~75 s without a session. Do it yourself to confirm on your
    hardware: start a mirror, press Stop, wait a minute, start again — if the
    second attempt comes up, it was the codec release, not the profile. Lowering
    fps or bitrate also avoids it, and the Android 14 tablet never showed it.
14. **Device audio end-to-end on Android 11+** — gate section 16 runs
    `powershell -NoProfile -ExecutionPolicy Bypass -File tools\audio_e2e_test.ps1`
    (add `-Seconds 15` to listen longer, `-MinSdk 28` to force it onto an older
    phone). It opens a named-pipe PCM consumer, starts a video-less
    `--audio-source=output --audio-codec=opus --no-audio-playback
    --game-audio-pcm=\\.\pipe\gaming-pcm-gate` session and fails unless the tap
    carries real signal: `OK no audio refusal printed by the server`, `OK PCM tap
    received N bytes`, `OK real signal on the PCM tap (peak=…, … dBFS)` (the level
    is computed straight off the s16le stream, peak > -90 dBFS) and `OK no audio
    error reported by the client`, ending in `AUDIO-E2E OK`. It is SKIP-safe on
    purpose — with only a sub-Android-11 phone attached it prints `SKIP no device
    with SDK >= 30 (device audio needs Android 11+)` and counts as neither pass
    nor fail — so on hardware that *can* capture audio this is the check to run by
    hand, together with the rest of the matrix the launcher offers:
    * `--audio-codec=opus` (default) and `--audio-codec=raw` — `raw` must get no
      bitrate flag, and both must be audible on the PC;
    * `--audio-source=output` vs `--audio-source=mic` — `output` silences the
      phone by design, `mic` carries the phone's microphone, so a clap must be
      heard;
    * `--no-audio-playback` with `--game-audio-pcm` still fed (PC silent, OBS
      alive) and with `--game-audio-bridge` (§8) consumed by OBS;
    * open the launcher on the same phone and press **Diagnóstico de audio** /
      **Audio diagnostic**: the badge must read *Audio del dispositivo:
      compatible (Android 11+)* / *Device audio: supported (Android 11+)* in
      green, the codec / bitrate / output-buffer / PCM-tap / bridge / mute
      controls must be enabled, and the log lines must agree with the server
      about SDK, support and sink state.
    Nothing here writes to the device: one `getprop` and scrcpy's own session.

15. **The real-time filter panel on a live mirror** — gate section 18 proves the
    panel paints, stays reachable, keeps its grade in the profiles file and does
    not move the per-frame cost, but it does that against `gamingdemo`, so these
    parts need you:
    * start a mirror from the launcher (Filtros → *Panel de filtros en tiempo
      real* stays checked) and press `Super+Alt+F` while **another program has
      the focus**: the panel must appear over the mirror anyway, because the
      hotkey is registered with Windows;
    * if the log says `overlay: global hotkey '…' is taken (error 1409)`, another
      program owns that combo: the same key still opens the panel while the
      mirror is focused, and `Esc` closes it. Pick a different combo in the
      launcher (e.g. `ctrl+alt+f9`) and restart the session — the log line at
      startup prints the combo the panel is listening for;
    * drag a slider: the mirrored picture changes **while you drag**, with no
      restart; click `CANCELAR` and it must return to the values the panel opened
      with;
    * click `GUARDAR`, close the session, start it again: the grade you saved
      must already be applied at session start, with the panel never opened
      (the OSD or `--game-telemetry-log` shows the same numbers);
    * click a slider inside the panel and check the device: no touch marker or
      phantom tap may reach the phone from panel clicks (the visualizer is the
      detector — gate section 18 covers the event isolation in code, your eyes
      cover the picture);
    * with the panel open, the OSD `postfx` timing must read the same as with it
      closed. On a 1080p mirror it will be higher than the 720x1280 numbers in §6
      — that is the filter engine, not the panel.

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

* **Layout** — dark theme (`#0E0F13` on `#16181F`) with **one** accent
  (`#4FA3FF`, 7.31:1 on the window background); the green, amber and red are
  *state* colours (`Good` / `Warn` / `Danger`), not second accents. Corner radius
  is 6–8 px everywhere, spacing sits on an 8 px rhythm with a 4 px half-step,
  numbers and key combinations are monospaced, and no visible string carries an
  icon glyph — the `▶ ● ■` prefixes the one-click buttons used to have are gone.
  Keyboard focus thickens the control's border instead of only changing its hue.
  `tools/theme_audit.sh` (gate section 20) reads the palette and the templates and
  fails the build if any of that drifts, including a WCAG AA check of the 15
  foreground/background pairs the theme actually paints (worst: 5.37:1). Seven
  tabs: **Quick**, **Capture**, **Presentation**, **Filters**, **Recording /
  OBS**, **Control**, **Advanced**. Nothing was removed by the redesign, only
  regrouped: 93 named controls are asserted present in the live window by
  `tools/launcher_uiauto.ps1` (gate section 10).
* **Device auto-detection** — `adb devices -l` plus `adb mdns services` for
  wireless-only devices; USB vs Wi-Fi classified; model read with `getprop`.
  The header shows it as a state dot, the picker, a count badge, and one quiet
  second line — `USB · moto g(7) power · Android 9 (SDK 28)` — so the Android
  version that gates audio and AV1 is visible without opening a log. The window
  has a 1120 × 600 minimum: below it the Spanish labels were measured drawing the
  device summary over the action buttons, so it is no longer reachable.
* **Language** — Español / English selector in the header. Everything visible
  (labels, combo items, tooltips, status text, dialogs, the run log and the
  command preview) comes from one table in `launcher/Loc.cs`, and the choice is
  remembered. Gate section 15 fails if a key is missing in either language.
* **Shortcut list** — **ATAJOS** on the Quick tab opens the runtime shortcuts as
  a table instead of a wall of text: a keycap-styled monospaced combination
  (`Super/Alt+F1`, wide enough for `Super+Alt+F12`), a short action, and a grey
  description, grouped under Espejo / Ventana / Otros with a collapse switch on
  any group longer than six rows. The same button that opens it closes it, and it
  is a section of the page rather than a dialog — a separate `Window` could not be
  read back by the UI Automation gate, which only ever saw the main window. The
  rows live in `launcher/Shortcuts.cs` as data (see §5), so gate section 17 can
  check the table itself (`--validate-shortcuts`, plus a fixture with a duplicated
  combination that must fail) and check what is actually painted in both
  languages (`tools/shortcuts_table_test.ps1`). Categories with no hotkey in
  scrcpy 5 — recording, filters — are left out rather than filled with invented
  keys.
* **Device panel** — model, battery level and temperature, read with read-only
  `getprop` / `dumpsys battery`. Nothing in the launcher writes a device setting.
* **Audio honesty** — a phone below Android 11 (SDK 30) cannot hand scrcpy its
  own audio, and that is a device limit, not a bug. So instead of leaving a
  checkbox that silently does nothing, the header states it directly: *Audio del
  dispositivo: NO SOPORTADO (requiere Android 11+)* / *Device audio: NOT
  SUPPORTED (needs Android 11+)* in amber, or the green *compatible / supported*
  line on a phone that can. When it cannot, the six audio controls (codec,
  bitrate, output buffer, PCM tap, audio bridge, mute-PC) are disabled with the
  reason in their tooltip, and the command preview sends `--no-audio` rather than
  four flags that would be ignored. **Diagnóstico de audio** / **Audio
  diagnostic** next to the badge prints SDK, support verdict, the server's own
  audio line, what the PC sink is doing, and the phone's `STREAM_MUSIC` volume
  read from `dumpsys audio` (read-only). Gate section 16 checks the working case
  end to end and is SKIP-safe when only an old phone is attached (manual steps:
  §7 item 14).
* **Live performance** — the `LIVE PERFORMANCE` block on the **Quick** tab (not a
  separate tab, so it is visible the moment the launcher opens) shows latency /
  FPS / video and audio bitrate read from the fork's `--game-telemetry-log`
  lines, which the launcher always adds, plus a 1 Hz latency sparkline.
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
  auto-hide and the six picture filters: sharpness, shadow lift, saturation,
  contrast, brightness, gamma — each with a numeric readout, a checkbox that
  decides whether its flag is passed at all, and a `reset` button); dropdowns for codec, renderer,
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

## 12. Troubleshooting: pantalla gris / "No responde"

If the mirror window opens grey and Windows marks it "No responde", run these
three commands from `dist\GamingScrcpy\scrcpy` and read the log. They are the
bisection that found the current bug, so they also find the next one.

```
# (b) minimal fork: no panel, no OSD, no filters
scrcpy.exe --video-codec=h264 --render-driver=direct3d11 --game-telemetry-log

# (d) codec matrix: one of these three is the grey one, if it is the codec
scrcpy.exe --video-codec=h265 --game-telemetry-log
scrcpy.exe --video-codec=av1  --game-telemetry-log

# (e) renderer matrix
scrcpy.exe --render-driver=opengl --game-telemetry-log
scrcpy.exe --render-driver=vulkan --game-telemetry-log
```

`--game-telemetry-log` prints one line per second (`INFO: telemetry: fps=…`).
No lines at all means no frame was ever presented, which is the grey screen;
lines with `fps≈60` mean the picture is live and a complaint is about something
else. As of v4 the fork will not let you sit in front of a grey window: if the
mirror has not presented its first frame within 5 s it logs

```
ERROR: video-stalled: no frame 5000 ms after the mirror opened, the decoder never delivered
```

and closes the session by itself, so the launcher returns to the device list.
`--game-stall-timeout=off` turns that off, `--game-stall-timeout=8000` relaxes it
(a phone with its screen off still delivers a first frame, so this never kills an
idle device). Gate §22 (`tools/stall_test.sh`) keeps all of that honest: the
filter panel must not cost the mirror its first frame, a session shorter than its
stall timeout must end by itself saying why, and `--no-playback` recordings —
which never paint by design — must never be watched.
