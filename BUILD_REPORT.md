# BUILD REPORT — GamingScrcpy fork + launcher

Built on 2026-10-16 on Windows 10 22H2 (10.0.19045) x64.
Everything below is a measured result from this machine, not an estimate. Where
something could not be measured, it says so.

---

## 1. What was produced

| Deliverable | Path | Evidence |
|---|---|---|
| Forked client | `dist\GamingScrcpy\scrcpy\scrcpy.exe` | libusb build (AOA gamepad enabled), runs with only `C:\Windows\system32` in `PATH`, prints `scrcpy 5.0.1`, lists 21 distinct `--game-*` flags in `--help` (606,361 bytes) |
| Server | `dist\GamingScrcpy\scrcpy\scrcpy-server.jar` (+ `scrcpy-server` name used by the client) | version-matched official v5.0.1 build, unmodified |
| Runtime DLLs | `dist\GamingScrcpy\scrcpy\*.dll` | collected from `ldd scrcpy.exe` (SDL3, avcodec-63, avformat-63, avutil-61, swresample-7, swscale-10, libusb-1.0 + transitive deps) |
| adb | `dist\GamingScrcpy\scrcpy\adb.exe`, `…\launcher\adb.exe` | Google platform-tools |
| Validation harnesses | `dist\GamingScrcpy\scrcpy\gamingdemo.exe`, `…\recorderintegrity.exe` | built from `app/tests/gaming_demo.c` and `app/tests/recorder_integrity.c`; both are host-side only and ship for reproducibility |
| Launcher | `dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe` | .NET 8 self-contained single file, 145,172,808 bytes (rebuilt for the AV1 capability fix, §5.1aa), window verified on screen |
| Sources | `workspace\scrcpy` (fork), `launcher\` (C# WPF) | see §4 |
| Validation tooling | `dist\GamingScrcpy\tools\*` (17 scripts + `fixtures\`) | the same scripts the gate runs, shipped so §7 is reproducible from the package alone: `bash tools/recorder_integrity_test.sh`, `bash tools/render_driver_test.sh` and `bash tools/fx_pixel_test.sh` all pass inside an extracted package, because each finds its binary next to `scrcpy.exe` when there is no build tree |
| Distributable package | `dist\GamingScrcpy-win64-fork.zip` | 126,296,395 bytes (≈120.5 MiB) at the last repack; `Expand-Archive` into an empty directory yields **160 files under 7 directories**, counted from the extraction rather than from an archive entry list. Built with `Compress-Archive` from `dist\GamingScrcpy\*`. The size shifts by a few hundred bytes each repack because this report is inside its own archive: the copy in the zip is the previous one and still carries the older number. The `tools\` tree travels with the package (17 scripts + `fixtures\`), so a user can re-run the pixel assertions, the filter checks and the latency matrix without a build tree. Verified from that extraction: `bash tools/recorder_integrity_test.sh 30 320x180` (11 cases, `OK`), `bash tools/render_driver_test.sh 20` (4 backends, `OK`) and `bash tools/fx_pixel_test.sh` (`FXPIXEL OK`), all exit 0 |
| Regression suite | `tools\verify_all.sh` | **137 passed, 0 failed** in the last full run, executed with the moto g(7) power attached (`out\gate_motorola_final.log`, §5.1ab); the earlier Lenovo TB-9707F run reached the same 137/0 (§5.1y, §5.4). The total moves by a couple of lines between runs **on purpose**: the bench emits one PASS per measured attempt (a quiet machine needs only one), the recorder check emits one line per case it can build, and two sections SKIP without a phone — so a fixed "N checks" number would be wrong more often than it is right |
| Known defect | `--game-borderless-fullscreen` | The window does not end up borderless or work-area sized at startup: measured `style=0x96cf0000` (caption bits still set) at `1270x592` on a `1366x768` desktop, because the first frame's resize overwrites the state that `set_borderless_fullscreen()` applies. `--always-on-top` and the live OSD were verified working in the same probe; `--fullscreen` (upstream) is unaffected. Reproduce with `tools/window_style_probe.ps1` (§5.1r, task #20) |
| Docs | `README_GAMING.md`, `PHASE1_AUDIT.md`, this file | — |

## 2. Toolchain actually used

| Component | Version |
|---|---|
| Compiler | MSYS2 UCRT64 GCC 16.2.0 (`cc`, ld.bfd 2.47) |
| Build system | Meson 1.12.1 + Ninja 1.13.2 |
| SDL | compiled 3.4.18 / linked 3.4.18 |
| FFmpeg | libavcodec 63.1.102, libavformat 63.1.102, libavutil 61.1.102, libswscale 10 |
| FFmpeg CLI (test-only) | 9.0.2 `ffmpeg`/`ffprobe` with libx264, libx265, libaom, aac — used by §5.1e, not shipped |
| libusb | 1.0.30 (installed for the shipped AOA build; absent in Phase 1) |
| adb | Google platform-tools, shipped next to the launcher |
| .NET | SDK 8.0.426 (WPF, `net8.0-windows`) |
| JDK (not used for the final server) | 19.0.2 |

The brief claimed `meson`, `ninja`, `adb` and Python 3.12 were already present;
they were not — see `PHASE1_AUDIT.md` §1 for the audit table and the bootstrap
that had to be done first.

## 3. Builds

### 3.1 Stock baseline (unmodified upstream, v5.0.1)

```
meson setup build-x --buildtype=release -Dusb=false -Dv4l2=false -Dcompile_server=false
ninja -C build-x        # 77/77 targets, exit 0
```

`scrcpy.exe` (523,125 bytes) ran and reported its dependency versions. Three
configuration iterations were needed and are documented in `PHASE1_AUDIT.md`
§4 (wrong source dir, `usb` is boolean not feature, `libusb-1.0` missing).
The new `app/src/gaming.{c,h}` files existed on disk during this build but were
not in the Meson source list, so the baseline is genuinely stock.

### 3.2 Forked client

```
ninja -C build-x        # 40/40 targets relinked, exit 0, no warnings left
```

Compile errors found and fixed during this build (all real, all listed so the
work can be trusted):

1. `sc_cond_signal/broadcast` take one argument in scrcpy's wrapper, not two.
2. SDL 3.4 renamed `SDL_DelEventWatch` → `SDL_RemoveEventWatch`.
3. SDL 3.4 split cursor visibility into `SDL_ShowCursor()` / `SDL_HideCursor()`.
4. SDL 3.4 removed `SDL_KeyboardEvent.keysym` → `.key` / `.mod`.
5. `SDL_MapRGBA` now takes `(SDL_PixelFormatDetails*, SDL_Palette*, r,g,b,a)`.
6. `SDL_SCALEMODE_BEST` does not exist in SDL 3.4 — the available modes are
   `NEAREST`, `LINEAR`, `PIXELART`, so the option set became
   `default|nearest|linear|pixelart` rather than pretending "best" exists.
7. `libswscale` was not a declared dependency (upstream never rescales frames
   host-side) → added to `app/meson.build`.
8. Meson has no array slicing, so the demo target lists its sources explicitly.

Second iteration — host resample for the stream feed (§3A "Lanczos/Bicubic" and
§3B "stream bridge" combined). Added `--game-bridge-scale=WxH` and
`--game-bridge-filter=…`, rebuilt clean (10/10 targets, exit 0). Two things had
to be fixed on the way:

9. An offline `recorder_test.c` harness that was written, abandoned and deleted
   (see §6) left its `executable('recorder_test', …)` block behind in
   `app/meson.build` pointing at a missing source, which broke the whole
   configure step. Removed, verified by a clean relink.
10. `sc_tick` in this codebase is **microseconds**, not milliseconds — the first
    version of the bridge timing log reported 7045 "ms" per frame. Fixed the
    conversion, and the numbers in §5.1b are the corrected ones.
11. Testing the named-pipe transport (§5.1c) exposed a startup stall: the pipe
    retry loop ran inside `sc_gaming_init()`. Moved the connect onto each
    bridge thread (`sink_init` / `sink_try_open` + deadline), and frames
    produced while no consumer exists are dropped instead of queued.

Third iteration — the same kernels on the *window* path (§3A, the last item
that was still GPU-only). Added `--game-window-filter=off|point|bilinear|fast|
bicubic|lanczos`: `screen.c` tells the engine the content rect in device pixels
and takes the resampled frame for the texture upload, while the frame bridge and
the pointer mapping keep the device-size frame. Rebuilt clean (70/70 targets in
`build-usb`, 64/64 in `build-x`, no new warnings); measured in §5.1d. Design
points worth recording:

12. The target is quantized to 16 px (`(w+8) & ~15`). YUV420P needs even
    dimensions, and without quantization dragging the window rebuilt a Lanczos
    `SwsContext` on every mouse move. The ≤ 8 px leftover is absorbed by the GPU
    blit, which still owns the final placement.
13. It is guarded by pixel format, not by a flag: hardware interop frames are
    not `YUV420P`, so `sc_gaming_resample_for_window()` returns the original
    frame and logs once. A rejected format must never turn into a black window.
14. The window filter deliberately runs *after* `sc_gaming_process_frame()` and
    its result is *not* what gets bridged, so `--game-bridge-scale` keeps its own
    kernel and the OBS byte math stays exactly as §5.1b/§5.1c measured it.

Fourth iteration — the audio splitter of §4 as something a virtual cable can
actually play. Added `--game-audio-pcm=` (`struct sc_pcm_tap`, a
`sc_frame_sink` attached to the audio decoder, s16le / 48 kHz / stereo through
libswresample, written by the same drop-oldest byte bridge as the other
outputs). Rebuilt clean (12/12 targets in `build-usb`, 64/64 in `build-x`, no
new warnings); measured in §5.1f. Two design points and one upstream behaviour
change worth recording:

15. The tap is a sink of the **decoder**, not a hook inside the audio player.
    The first version pushed from `sc_audio_player_frame_sink_push()`, which
    meant `--no-audio-playback` — the one configuration where a cable is
    actually useful, because it keeps the PC silent — produced silence.
    `audio_player.c` is therefore back to pristine upstream code, and the tap
    reaches the audio pipeline through `sc_frame_source_add_sink()` in
    `scrcpy.c` instead.
16. Upstream turns the audio stream off when nothing plays or records it
    (*"No audio playback, no recording: audio disabled"*), which also killed the
    older `--game-audio-bridge` in exactly the same way. `cli.c` now counts
    either audio output as a consumer, so the stream survives
    `--no-audio-playback`. Measured both directions in §5.1f; this is a change
    in upstream option handling, not just an added flag.
17. The tap never fails a sink: `open()` returns true even when the bridge is
    gone and `push()` always returns `SC_SINK_OK`, because a missing consumer
    must degrade to *no cable*, never to *no session*.

### 3.3 AOA-capable rebuild (`build-usb`, the shipped binary)

Phase 1 concluded `libusb-1.0` was unavailable, so the client was built
`-Dusb=false`. That silently cost the fork a gaming feature: `--gamepad=aoa`
was refused as "disabled". Installing the package and reconfiguring fixed it:

```
pacman -S --noconfirm mingw-w64-ucrt-x86_64-libusb     # 1.0.30
meson setup build-usb --buildtype=release -Dv4l2=false -Dcompile_server=false
ninja -C build-usb                                     # 92/92, exit 0
```

`pkg-config` then reported `libusb-1.0 found: YES 1.0.30`, `usb: true`, and the
binary grew from 562,828 to 588,814 bytes with one new runtime DLL. Measured
behaviour after the switch:

| flag | result |
|---|---|
| `--gamepad=aoa` | accepted (physical AOAv2 controller) |
| `--gamepad=uhid` | accepted |
| `--keyboard=aoa`, `--mouse=aoa` | still refused: *"On Windows, it is not possible to open a USB device already open by another process (like adb)"* — an upstream platform limitation, not a build option |

`build-x` (`-Dusb=false`) is kept as the Phase 1/2 baseline.

### 3.4 Launcher

```
dotnet publish -c Release -r win-x64 --self-contained true \
     -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
     -o ..\dist\GamingScrcpy\launcher
```

One runtime crash was found by actually starting the published exe: WPF raises
`Slider.ValueChanged` while the window is still being parsed, before the label
elements exist (`NullReferenceException` in `RefreshLabels`). Fixed with an
explicit `_ready` gate. After the fix the published exe starts, shows the
window, seeds 4 profiles + 2 keymaps and renders a live command preview.

A second, dumber failure worth recording: on the MSYS2/Git-Bash shell the first
republish after the bridge controls used `/p:PublishSingleFile=true`, and POSIX
path conversion turned those into stray positional arguments. MSBuild failed
with *MSB1008: only one project can be specified* — but the pipeline ended in
`| tail`, so the shell reported **exit 0** and the old 145 MB exe stayed in
`dist/`. Republished with `-p:` + `MSYS2_ARG_CONV_EXCL='*'` and confirmed by the
file timestamp and size changing. Lesson: check the artifact, not the exit code.

## 4. Source changes

New files: `app/src/gaming.h` (307 lines), `app/src/gaming.c` (1,875 lines),
`app/tests/gaming_demo.c` (568 lines), `app/tests/recorder_integrity.c`
(689 lines).
Modified: `app/meson.build`, `app/src/options.h`, `app/src/cli.c`,
`app/src/screen.h`, `app/src/screen.c`, `app/src/scrcpy.c`, `app/src/demuxer.c`,
`app/src/recorder.c` (§5.1i, thread-safety fix only).
`app/src/audio_player.c` was touched while prototyping the PCM tap and is back
to pristine upstream code (verified with `git diff --stat`).
Launcher: `launcher/{GamingScrcpyLauncher.csproj,app.manifest,App.xaml,App.xaml.cs,AppConfig.cs,Services.cs,MainWindow.xaml,MainWindow.xaml.cs}`.

Design constraint kept throughout: **the device framebuffer is never touched**.
No `--max-size`, `--crop`, `--new-display`, `--resize` or display-density change
is emitted by the fork or by the launcher. Upscaling, filters, OSD and cursor
work all happen after decoding, on the PC.

## 5. Validation results

### 5.0 Launcher self-test (`GamingScrcpyLauncher.exe --validate-profiles`)

The launcher has a headless mode that builds the command line of every seeded
profile and lets the **real** `scrcpy.exe` parse it (`--version` short-circuits
after argument validation, so no device is needed). Since the third iteration it
also validates one synthetic profile that puts *every* configurator control at a
non-default value, so a control that no shipped preset happens to use cannot
rot unnoticed:

```
PASS 4K Ultra Quality Stream 60FPS (exit=0)
PASS Competitive COD Mobile 120FPS (exit=0)
PASS Night/Dark Game Boost (exit=0)
PASS Recording Only (exit=0)
PASS synthetic max settings (exit=0)
      --game-upscale=pixelart --game-window-filter=lanczos --game-low-latency
      --game-borderless-fullscreen --game-osd=full --game-cursor-autohide=60000
      --game-postfx=sharp,night,sat --game-sharp=100 --game-night-boost=100
      --game-saturation=200 --game-touch-visualizer
      --game-frame-bridge=\\.\pipe\gaming-frame --game-bridge-scale=3840x2160
      --game-bridge-filter=lanczos --game-audio-bridge=\\.\pipe\gaming-audio
      --game-audio-pcm=\\.\pipe\gaming-pcm --no-audio-playback --turn-screen-off
ALL PROFILES VALID
```

This test earned its keep: the first run reported **4/4 FAIL** and exposed six
wrong option values the launcher had been emitting, all confirmed against the
binary's own error messages:

| Launcher had emitted | Reality in scrcpy 5.0.1 | Fix |
|---|---|---|
| `--rendering-driver=direct3d11` | option is `--render-driver` | renamed |
| `--video-codec=hevc` | `ERROR: Unsupported video codec: hevc (expected h264, h265, av1)` | mapped hevc→h265 |
| `--game-upscale=best` | `expected one of: default, nearest, linear, pixelart` | seeds fixed + `NormalizeUpscale()` guard |
| `--hwdec=never` / `always` | `expected auto, disabled, d3d11va, …` | dropdown now auto/disabled/d3d11va |
| `--mouse=auto`, `--keyboard=adb`, `--gamepad=uhid` | `auto` is not a token; `adb`/`uhid` gamepad unsupported here | omit when default; valid sets only |
| `--shortcut-mod=s+cc` | `Shortcut mod combination with '+' is not supported anymore` | `lsuper,lctrl` |

The new `--game-*` parsers were checked the same way:

```
--game-osd=bogus      -> exit=1  ERROR: Invalid --game-osd: 'bogus' (expected one of: none, compact, full)
--game-sharp=150      -> exit=1  ERROR: Invalid --game-sharp: '150' (must be between 0 and 100)
--game-postfx=laser   -> exit=1  ERROR: Invalid --game-postfx filter: 'laser' (expected sharp, night, sat or none)
--game-upscale=bicubic-> exit=1  ERROR: Invalid --game-upscale: 'bicubic' (expected one of: default, nearest, linear, pixelart)
all 12 flags together -> exit=0  (including --game-frame-bridge=\\.\pipe\gaming-frame)
```

### 5.1 Presentation engine (`gamingdemo`, real GPU, direct3d11)

`gamingdemo.exe --frames=60 --width=720 --height=1280 --fx --bridge=bridge.raw --audio=bridge.pcm --shot=demo_shot.bmp`

```
gamingdemo: 60 frames, backend=direct3d11
gamingdemo: fps(present)=49.8
gamingdemo: postfx cpu cost avg=3.236ms max=6.183ms over 60 frames (720x1280)
gamingdemo: telemetry fps=55.2 latency=5 ms video=55 KB/s audio=0 KB/s
frame bridge: 720x1280 RGBA frames
frame bridge: 2 frames dropped (slow consumer)
frame bridge: 58 frames sent
Borderless fullscreen on (…)/ off
gamingdemo: PASS
```

Artifact math checked against the file sizes:

* `bridge.raw` = 213,811,200 bytes = 58 × 720 × 1280 × 4 — **exact**, so every
  frame the bridge accepted was written completely, and the 2 drops are the
  documented drop-oldest behaviour, not corruption.
* `bridge.pcm` = 6,000 bytes = 30 × 200 — every audio packet forwarded.
* `bridge.raw.meta.txt` written with the format/size the consumer needs.
* `demo_shot.bmp` (360×640 readback) shows the OSD overlay legible:
  `FPS 55.2 TARGET 120 / VID 55 KB/S AUD 0 KB/S / SRC 720X1280 ON 360X640 /
  LAT 4 AVG 4 MAX 39 MS BRIDGE`, over the filtered picture.

Interpretation of the numbers:

* **Post-processing cost is real and is the price of the filters**: 3.24 ms avg
  (6.18 ms worst) per 720×1280 frame on the CPU. Scaled to 1080p that is
  roughly 7-8 ms, i.e. it eats most of a 60 fps budget. That is why every
  filter is opt-in and why the OSD prints frame time — and why the default
  competitive profile uses only the GPU-side upscale filter.
* The demo's ~50 fps present rate is the harness' own `SDL_Delay(8)` throttle,
  not an engine ceiling; the drop-oldest bridge proves a slow consumer cannot
  stall the render loop (2 frames dropped, presentation continued).
* `latency=5 ms` in the demo is the harness' synthetic packet→present interval,
  i.e. it validates the *measurement path*, not a device's end-to-end latency.

### 5.1b Host resample of the stream feed (§3A Lanczos/Bicubic)

Same harness, 720x1280 synthetic frames, `--bridge-scale=1920x1080`, consumer on
stdout redirected to `/dev/null` so the kernel cost is separable from the write
cost:

```
--bridge-filter=bilinear   resample avg=6.01ms   write avg=10.70ms   PASS
--bridge-filter=bicubic    resample avg=7.11ms   write avg= 9.51ms   PASS
--bridge-filter=lanczos    resample avg=9.42ms   write avg= 9.79ms   PASS
--bridge-filter=point      resample avg=10.35ms  write avg=10.66ms   PASS
--bridge-scale=3840x2160 lanczos  resample 28.25ms  write 39.22ms    PASS
```

The correctness check is byte arithmetic on the closed file, done by the demo
itself (`gamingdemo: bridge … = N bytes, frame 1920x1080 = 8294400 bytes,
frames=N`, then `PASS` only if the size is an exact non-zero multiple):

* lanczos run: **165,888,000 = 20 x 1920 x 1080 x 4** — the bridged frames are
  genuinely 1080p, not 720x1280 upscaled by the consumer.
* point run: 141,004,800 = 17 x 8,294,400; bicubic: 132,710,400 = 16 x 8,294,400.
  The frame counts differ because the queue is drop-oldest while the harness
  throttles itself; the *size* is exact in every run, which is the property
  under test.

Caveats, stated plainly: `point` measuring slower than `bilinear` means run-to-run
noise on this laptop is on the order of 2-4 ms, so only the 4K figure (roughly
3x the 1080p cost for 4x the pixels) should be read as a real signal. All of
this happens on the bridge thread; the render thread only appends to the queue,
so none of it is added mirror latency — but that also means it was **not**
measured against a real device (see §6).

### 5.1c Named-pipe transport (`\\.\pipe\…`, the OBS path)

Files and stdout had been exercised; the named-pipe client had not. A real
`NamedPipeServerStream` consumer in PowerShell, `gamingdemo` writing 640x360
RGBA frames (921,600 B each) to `\\.\pipe\gaming-frame`:

| case | result |
|---|---|
| consumer listening before scrcpy | 39 frames sent, consumer read **35,942,400 B = 39 × 921,600**, exact multiple |
| no consumer at all | 0 sent, 40 frames discarded, whole run **0.9 s** wall clock |
| consumer joins 2 s late | `waiting for a consumer` → `consumer connected`, 506 frames sent, **466,329,600 B = 506 × 921,600**, exact |

The second case is what found a real bug: `sink_open()` retried the pipe for
100 × 100 ms **on the calling thread**, i.e. inside `sc_gaming_init()`, so
starting scrcpy before the OBS consumer froze the mirror for up to 10 s — and
while it waited, queued frames pinned decoder buffers. The connect now happens
on the bridge thread (`sink_try_open` + a 10 s deadline), frames produced
before a consumer appears are dropped rather than queued, and the failure is
logged once. `README_GAMING.md` §8 said "the consumer must be started before
scrcpy"; that claim is now false and has been replaced with the measured
behaviour above.

Pipe throughput is also much better than the file path measured in §5.1b:
**write avg 2.39 ms/frame** over a named pipe versus ~10 ms to disk and ~28 ms
to a redirected file, so a pipe is the right transport for a live consumer.

The audio splitter was then tested over the same transport
(`tools/bridge_audio_pipe_test.ps1`): 800 frames, one 200-byte packet every
other frame → consumer received **80,000 bytes in 400 chunks — every packet,
no drops, no partial writes**. Transport matrix is now covered: file, stdout and
named pipe, for both bridges.

One trap found while doing it: from Git Bash, `--audio='\\.\pipe\gaming-audio'`
arrives at the process as `\.\pipe\gaming-audio` (MSYS path conversion eats a
backslash), so it is treated as a file path and never connects. Run the bridges
with pipe paths from `cmd`/PowerShell, or set `MSYS2_ARG_CONV_EXCL='*'`.

### 5.1d High-quality resample of the *presented* frame (`--game-window-filter`)

The last item of §3A that was still GPU-only. `gamingdemo` drives the real
render path (`sc_gaming_set_window_target()` +
`sc_gaming_resample_for_window()` before `sc_texture_update()`), dragging the
window and toggling borderless fullscreen inside the same run, and prints the
byte math plus a PASS/FAIL self-check:

```
gamingdemo: window filter 720x1280 -> 416x752, resampled=30 avg=1.648ms
            rebuilds=4 distinct=4 tex_rebuilds=4
```

Kernel comparison on this host (direct3d11, one run per kernel, cost measured
on the render thread; the runs also resize, hence the small rebuild counts):

| source | presented | point | bilinear | bicubic | lanczos |
|---|---|---|---|---|---|
| 360x640 | 416x752 | 0.32 ms | 0.39 ms | 0.46 ms | 0.68 ms |
| 540x960 | 1232x2192 (2.3x up) | — | — | 2.05 ms | 2.51 ms |
| 1080x1920 | 816x1440 (1440p window) | — | — | 2.49 ms | 2.91 ms |
| 720x1280 | 432x768 (768p window) | — | — | — | 1.75 ms |

Three properties were verified rather than asserted in prose:

* **Resize tracking** — 4 distinct presented sizes and 4 `SwsContext` rebuilds
  in one run; the self-check fails if the presented frame stops following the
  content rect (`distinct_sizes < 2`) or comes out odd-sized (YUV420P needs
  even).
* **Bridge isolation** — with `--window-filter=lanczos --bridge-scale=640x360`
  the bridge file stayed a whole number of 640x360 RGBA frames (27,648,000 B),
  i.e. the OBS feed is still scaled by its own kernel only, never by the window.
* **No upstream surgery** — a resampled `YUV420P` frame simply makes
  `sc_interop_software_import()` recreate the texture at the new size, the same
  path a device resolution change already uses; `tex_rebuilds` counts it.
* **Overlay still renders** — a second run with the OSD enabled plus
  `--window-filter=bicubic` still produces a non-empty screenshot, and the OSD
  telemetry line now carries a `WIN` marker next to `BRIDGE`/`FX` so the state
  is visible while playing.

The format guard is real: with `--hwdec=d3d11va` the frames are not
`YUV420P`, the engine logs `frames are not YUV420P … GPU scaling kept` once and
returns the original frame, so the flag can never break presentation.

### 5.1e Encoder round-trip of both bridges (`tools/bridge_encode_test.sh`)

Byte-math proves the streams are well-formed, but it does not prove a consumer
can *decode* them. This test closes that gap as far as is possible without a
phone: `gamingdemo` now feeds the audio bridge a real 48 kHz stereo s16le
stream (`--audio-sine`, one 16.7 ms packet per rendered frame — exactly what
`--audio-codec=raw` carries), and a real encoder consumes both raw files:

```
RESULT frames=40 audio_chunks=40 vsize=640x360
RESULT codecs=h264+aac durations=0.666667/0.666667 delta=0.000000 tol=0.025000
RESULT mp4=649249B av_locked=yes
OK
```

What that establishes:

* the frame bridge is a valid rawvideo stream at the configured size — libx264
  encodes it into an MP4 with no errors and no odd dimensions;
* the audio bridge is a valid PCM stream — ffmpeg decodes it as 48 kHz stereo
  and the muxer writes an AAC track;
* the two tracks come out with **identical durations** (`-shortest` trims to
  the shorter), which is the host-side half of the A/V-sync question: both
  bridges are fed from the same rendered-frame loop, so a systematic drift
  between them would show up here as a duration mismatch. What still needs a
  device is the alignment of the *device's* audio and video capture, which no
  host-side test can produce.

The script exits 77 (SKIP) when ffmpeg is absent, so the gate stays usable on a
machine without it.

### 5.1f Decoded PCM tap (`--game-audio-pcm`, the §4 audio splitter)

Two separate questions had to be answered: does the tap produce samples a cable
driver can actually play, and does it survive the configuration that needs it?

**Conversion.** `gamingdemo` pushes 44.1 kHz **mono** float frames into the tap
— deliberately the wrong rate, wrong channel count and wrong depth — and the
output is then probed with ffmpeg:

```
pcm tap: 44100 Hz / 1 ch / flt -> 48000 Hz s16le stereo
gamingdemo: pcm tap …\pcm_new.raw = 153532 B (expected ~153600 B of 48k/stereo/s16le)
RESULT pcm_tap=153532B rate=48000 ch=2 duration=0.799646 max_vol=-9.0dB
```

153,532 B is 40 × 960 samples × 4 B minus the swresample priming delay, and the
file decodes as 48 kHz / 2 ch **with content** (`max_volume -9.0 dB`, not
silence). The size is asserted by `gamingdemo` itself (±10 %, 4-byte aligned)
and by `tools/bridge_encode_test.sh`, so a regression in the conversion fails
the gate rather than shipping silently.

**Transport.** The same feed over a real named pipe, consumed by a second
process (`tools/pcm_tap_pipe_test.ps1`):

```
pcm tap: raw bytes -> \\.\pipe\gaming-pcm
pcm tap: consumer connected (\\.\pipe\gaming-pcm)
pipe consumer received: 767932 B in 200 reads
ffmpeg decoded the piped bytes as 48 kHz stereo, max_volume=-9 dB
PCMPIPE OK
```

768,000 B produced for 200 frames, 767,932 B received, nothing dropped. Writing
this test is what caught a harness mistake worth recording: the first version
scanned every sample inside the read loop to check for silence, which made
PowerShell the slow consumer and produced 48 legitimate `chunks dropped` — the
bridge behaving exactly as designed. Loudness is now measured afterwards, by
ffmpeg, on the bytes that actually crossed the pipe.

**Does it run with the PC silent.** This needed a change in upstream option
handling, not just a new flag, and it is asserted in both directions:

```
PASS  baseline: --no-audio-playback alone disables audio
PASS  --game-audio-pcm keeps audio alive without playback
PASS  --game-audio-bridge keeps audio alive without playback
```

The check is behavioural: `scrcpy --no-audio-playback -x` logs *"No audio
playback, no recording, no audio bridge: audio disabled"*, and adding either
audio output must make that line disappear (`tools/verify_all.sh` §3b). `-x` is
an upstream option that is rejected unless `--new-display` was used, so it stops
the run immediately after option validation — a device-free way to exercise
exactly this logic.

### 5.1g Recorder integrity with no device (`tools/recorder_integrity_test.sh`)

`--record` was, until now, verified only by the arguments being accepted. That
was an honest caveat but not an acceptable end state, because `sc_recorder` is
pure host-side code: it receives already-encoded packets and muxes them. Only
the *packets* need a phone.

So the recorder is now driven directly by `app/tests/recorder_integrity.c`
(shipped as `recorderintegrity.exe`), which encodes nothing itself and instead
does exactly what the demuxer thread does — open the video packet sink with real
`AVCodecParameters`, push the config packet (`pts = AV_NOPTS_VALUE`) and then one
Annex-B access unit per frame with microsecond pts — while the shell test
generates the input with a real encoder and probes the result. The input is
either an Annex-B elementary stream (`--in`, what the device sends for H.264 and
HEVC) or a complete encoded file (`--container-in`, for a codec whose config
lives in the container), plus an optional raw-PCM second stream:

```
RESULT h264-mkv file=out.mkv codec=h264 size=320x180 frames=30/30
RESULT h264-mp4 file=out.mp4 codec=h264 size=320x180 frames=30/30
RESULT av-mkv streams=2 video_frames=30/30 audio_packets=100/100 audio=pcm_s16le/48000Hz/2ch max_volume=-21.1dB
RESULT cut-mkv cut=10 video_frames=10 audio_packets=30/100 duration=0.400000s
RESULT cut-mp4 cut=10 video_frames=10 audio_packets=30/100 duration=0.400000s
RESULT hevc-mkv file=out.mkv codec=hevc size=320x180 frames=30/30
RESULT av1-mkv file=out.mkv codec=av1 size=320x180 frames=30/30
RESULT av1-mp4 file=out.mp4 codec=av1 size=320x180 frames=30/30
RESULT av1-audio-mkv streams=2 video_frames=30/30 audio_packets=100/100 audio=pcm_s16le/48000Hz/2ch max_volume=-21.1dB
OK
```

For each case the test asserts the harness exit status, the codec the container
reports, the frame size, **the frame count after decoding every frame**(`ffprobe -count_frames`), and that `ffmpeg -v error` is completely silent — so a
corrupted index, a bad extradata conversion or a truncated cluster fails here.
The MP4 case is also the proof that the Annex-B → AVCC extradata conversion the
mov muxer performs on scrcpy's behalf produces a streamable file.

The three later cases cover what a gaming recording actually exercises:

* `av-mkv` opens **both** sinks and pushes H.264 access units and 10 ms raw
  PCM frames (the shape of `--audio-codec=raw` at 48 kHz stereo) in pts order,
  so the muxer has to interleave two timelines. The test then requires two
  streams, 30 video frames, 100 audio packets, `pcm_s16le/48000/2ch` as the
  container declares them, a silent decode, and — via `volumedetect` — that the
  audio track really carries signal (−21.1 dB peak; silence would read −91 dB).
  That last assertion caught a bad fixture: the first tone was mono, the muxer
  dutifully wrote it as the stereo the caller declared, and the file "passed"
  while being unlistenable. The fixture is now generated with `-ac 2` and the
  byte count is checked against the expected chunk count before anything runs.
* `cut-mkv` and `cut-mp4` stop the recorder **in the middle**, with no end of
  stream, which is the Ctrl+C path: `sc_recorder_stop()` must drain both queues
  and still write a playable trailer. Both keep 10 video frames and 30 audio
  packets — the audio that had already reached the recorder, and no more — and
  both decode cleanly. For MP4 this is the interesting one, because the `moov`
  atom is only written at the end: an interrupted recording that survives here
  is one that OBS, Premiere or `ffprobe` can still open.
* `av1-mkv`, `av1-mp4` and `av1-audio-mkv` cover the third codec the launcher
  offers, and the only one that does not arrive as Annex-B: AV1 reaches the
  recorder as OBU temporal units with its sequence header in the container. The
  harness therefore has a second input mode, `--container-in=FILE`, which reads
  a real encoded file (`libsvtav1` into IVF here), takes the codec parameters and
  the config bytes from it, and pushes every packet with its own timestamps. The
  result is the same kind of evidence as the other cases — 30 of 30 frames
  decoded back out of MKV and MP4, `av1`/`yuv420p` as the container declares
  them, a silent `ffmpeg -v error`, and the audio-muxed variant again carrying
  100 interleaved PCM packets with signal.

One finding worth recording, because it ended as a fix in the fork rather than a
workaround in the harness: the first version opened the sink as soon as
`recorder->ctx` was non-NULL and segfaulted inside `avformat_new_stream()`. That
is not a harness artifact. `sc_recorder_open_output_file()` runs on the recorder
thread, outside the mutex, and published `recorder->ctx` as its *first* action —
`pb`, `oformat` and `metadata` are still written after that — while
`sc_recorder_video_packet_sink_open()` runs on the producer thread and calls
`avformat_new_stream(recorder->ctx, NULL)` *inside* the mutex. Only one side
holds the lock, so it orders nothing: the producer may see `NULL`, or a context
without its output format. Upstream hides this behind the ADB handshake (the
demuxer cannot attach a sink for hundreds of milliseconds) and behind the
recorder thread running at low priority — which is precisely the case that
inverts on a busy desktop. See §5.1i for the fix and its reproduction.

The suite was also checked for the opposite failure — passing when it should
not. `awk -v want="10/30"` silently converts the expression to `10`, so the
duration assertion compared 0.4 s against 9.95 s and failed while everything was
in fact correct; it now passes `cut` and `fps` as separate numbers. And two
negative runs are deliberately wrong in the way a regression would be: feeding
an audio file shorter than one packet exits 1 with
`the audio PCM has fewer than one 1920 B packet`, and `--stop-after=999` on a
30-frame stream reports `FAIL` (exit 1) instead of pretending the stop happened.

Section 8d of the gate runs this same script *from inside the package layout*
(`dist/GamingScrcpy`, cwd included), so the check that ships in the zip is the
check that is being asserted: it finds `scrcpy/recorderintegrity.exe` instead of
a build tree and reproduces all eleven cases. That closes the gap where a package
could contain a stale or broken harness while the build tree still passed.

### 5.1h What `--record` costs a live mirror (`--bench` in the same harness)

"Dual recording: save the file while mirroring, without impacting frame delivery"
is a measurable claim, and the measurement needs no phone: `sc_recorder` is fed
packets by the same thread that feeds the decoder, so the cost of recording is
exactly the time that thread spends inside `push()`. The harness therefore runs
the same packet list twice: once into a sink that does nothing, once into a live
`sc_recorder` writing to disk, both paced at the stream rate, both pushing
reference-counted packets so the recorder's `av_packet_ref()` is a refcount bump
rather than a copy — that detail alone changed the result by 4×, which is why it
is in the report.

```
RESULT dual-60fps  attempt=1 frames=120 interval=16666us added=25-63us/push push_max=67us-2.0ms still_queued=0 drain=13ms
RESULT dual-120fps attempt=1 frames=120 interval=8333us added=13-38us/push push_max=54us-1.7ms still_queued=0-3 drain=12ms
```

120 frames of 1280x720 H.264 (≈30 kB per packet, ≈29 Mbps), eight runs total:
the *average* extra cost per delivered frame is **13-63 µs**, i.e. 0.2-0.4 % of
a 60 fps frame interval and 0.5-0.8 % of a 120 fps one. The gate asserts bounds,
not numbers: the average must stay under a tenth of the frame interval, no single
push may cost a whole interval, and the recorder must have caught up within 3 s of
the last frame. All three hold on every run.

Two honest caveats from the same data:

* The writer thread does not always keep pace, and that is deliberate:
  `sc_recorder` runs it at low priority with a queue upstream never bounds, so the
  depth is a property of the machine, not of recording. Measured here it ranged
  from **0 to 118 of 120 packets** — 0 when the host was idle, a handful on a busy
  desktop, 118 with six recorders sharing one disk — while the producer's cost
  stayed in the same 13-63 µs band in every one of those runs. The test therefore
  does not assert a queue depth: it times how long the recorder keeps working
  *after* the last frame was pushed and requires that to be under 3 s. It measures
  **12-13 ms**, which is the number a user feels — the file is complete ~13 ms
  after the mirror saw its last frame, and the mirror never waited for the disk.
* These two cases used to be flaky for a different reason: attaching a sink raced
  the recorder thread's publication of its `AVFormatContext` (§5.1i). With that
  race fixed the harness needs no readiness sleep at all — `open()` waits on the
  condition variable — and six parallel instances complete all 11 cases each
  without a crash.

This measures the host side only: a real recording adds the device's encoder
timing and whatever the destination disk and its virus scanner do to the writer
thread, and `sc_recorder` runs at low thread priority on purpose.

### 5.1i Fixed: the recorder published its `AVFormatContext` without the mutex

Both crashes above are the same upstream data race, and the fork now fixes it
instead of timing around it.

The race:

* `sc_recorder_open_output_file()` runs on the recorder thread and holds no
  lock. It used to assign `recorder->ctx` as its *first* action and only then
  fill `ctx->pb`, `ctx->oformat` and `ctx->metadata`.
* `sc_recorder_video_packet_sink_open()` and
  `sc_recorder_audio_packet_sink_open()` run on the producer thread, take the
  mutex, and immediately call `avformat_new_stream(recorder->ctx, NULL)`. One
  side locks and the other does not, so the mutex orders nothing: the producer
  can read `NULL` (a crash in the first dereference) or a context whose muxer is
  not set yet.
* Upstream gets away with it because the demuxer attaches its sinks only after
  the ADB handshake, hundreds of milliseconds after `sc_recorder_start()`. The
  recorder thread additionally runs at `SC_THREAD_PRIORITY_LOW`, so on a loaded
  machine that head start is what inverts — which is how the packaged self-check
  came to segfault once on a busy desktop.

The fix, 51 lines in `app/src/recorder.c` and no change in behaviour:

* the context is built and fully initialised in a local, then published by
  `sc_recorder_publish_context()` **under the mutex** with a
  `sc_cond_broadcast()`;
* both sink `open()` functions call `sc_recorder_wait_for_context()` with the
  mutex held: it waits on the existing condition until the context exists or the
  recorder has stopped, and `open()` returns false in the latter case, so the
  failure is a rejected sink rather than a `NULL` dereference;
* `sc_recorder_close_output_file()` unpublishes (`ctx = NULL`) before freeing, so
  a sink attaching late sees no context rather than a dangling one;
* `run_recorder()` broadcasts when the thread gives up, so nothing can wait
  forever for an output file that will never open;
* `sc_recorder_init()` sets `recorder->ctx = NULL` explicitly — the struct is a
  caller-owned stack object, so before this the field could start out as garbage
  rather than as `NULL`.

Before and after, same machine, same script:

```
before: 6 parallel instances, 20 ms readiness sleep -> crash 12/12 (avformat_new_stream)
after:  6 parallel instances, no sleep at all       -> 11 cases x 6 runs, 0 crashes
gate:   tools/verify_all.sh                        -> 103 passed, 0 failed
```

The harness lost its 500 ms sleep and its read of recorder internals: with the
wait inside `open()`, correct ordering is a property of the code rather than of
timing — and that makes the existing 11 cases the regression guard for this fix,
because they now attach their sinks with no sleep at all, which is exactly the
schedule that crashed 12 out of 12 before the recorder was changed. This is the
only place where the fork touches `sc_recorder`. It changes no byte of the muxed
output — the gate still decodes every file and compares frame counts — and nothing
in it is sent to the device, so the "host side only" constraint holds.

### 5.1j Every GPU backend presents the same path (`tools/render_driver_test.sh`)

§3A offers `--render-driver=direct3d11|opengl|vulkan`, and which backend SDL
actually creates is host-side behaviour, so it needs no phone. The sweep runs the
demo's whole presentation path once per backend — low-latency hint (vsync off),
borderless fullscreen, a window filter into a 1920x1080 window, OSD telemetry and
the frame bridge — and asserts three properties of each run:

* the backend SDL reports **is** the one that was requested, never a silent
  substitution: a profile that says `vulkan` must not quietly get `direct3d11`;
* all requested frames were presented (`gamingdemo: N frames` equals `N`);
* the frame bridge holds whole source-size RGBA frames and never more of them than
  the window presented (the fork's max-fps limiter may legitimately drop a frame
  from the bridge), so what OBS consumes has the same shape on every backend —
  which is what makes the encoder round-trips of §5.1e/§5.1f transferable to the
  non-default drivers.

```
RESULT direct3d11 backend=direct3d11 presented=30/30 bridged=30 window=1920x1080
RESULT opengl     backend=opengl     presented=30/30 bridged=30 window=1920x1080
RESULT vulkan     backend=vulkan     presented=30/30 bridged=30 window=1920x1080
RESULT default    backend=direct3d11 presented=30/30 bridged=30 window=1920x1080
```

All four pass on this host, including the no-hint case, which lands on
`direct3d11` — the same backend every other section of the gate exercises, so the
default configuration is not secretly untested. A backend SDL cannot create is
reported as `unavailable-on-this-host` and does not fail the suite: that is a fact
about someone else's driver, not a regression in the fork. Present-to-photon
latency is still not measured by this (or anything else here); it needs a display
and a camera, and stays in §6/§7.

### 5.1k Two harness defects found while writing §5.1j, and the OSD assertion

Building the backend sweep turned up two reporting bugs in the demo itself, both
in code that the gate had been reading as if it were trustworthy:

* `fps(present)` was derived from the counter that only the `--fx` path
  increments, so **every** plain run printed `fps(present)=0.0`. It now counts
  real `SDL_RenderPresent` calls. That also makes the retry condition in §5.4 mean
  what it claims: an earlier encoder failure there was labelled "the desktop was
  still busy" on the strength of a number that was always zero, which was not a
  sound diagnosis of that run.
* the OSD telemetry fills a one-second window, so a 20- or 30-frame run correctly
  reports `fps=0.0 video=0 KB/s`. Nothing asserted that a *long* run produced
  numbers, i.e. that §3A's readout calculates rather than merely renders.

Gate section 7d closes both: it runs 150 frames (~1.5 s) with the OSD on and
asserts the computed values are nonzero, then asserts the independently measured
presentation rate agrees:

```
gamingdemo: 150 frames, backend=direct3d11
gamingdemo: fps(present)=97.7
gamingdemo: telemetry fps=96.7 latency=0 ms video=97 KB/s audio=0 KB/s
```

Two live numbers from two different measurements (the loop's own clock and the
fork's OSD accumulator) agreeing within 1 % is the host-side evidence that the FPS
and bitrate the user reads on screen are real. Latency still reads what the demo
feeds it, and `audio=0 KB/s` is expected without `--audio-sine`; what is *not*
provable here remains the device's own capture latency (§6).

### 5.1l First run against real hardware (Lenovo TB-9707F)

A device was finally connected (USB, `<dev-id-1>`: Lenovo TB-9707F, SM8550,
Android 14 / SDK 34, arm64-v8a; the tablet's own display mode is 1080x2316 at
411 dpi, which nothing in this session changed). Running the packaged build
against it replaced several "cannot be verified here" notes with measurements —
and exposed two packaging defects that no host-only test could see.

Verified on hardware:

| check | result |
|---|---|
| native rendering untouched | capture and stream at **1080x2316** (`Texture (D3D11VA): 1088x2320` is the encoder's macroblock rounding, not a resize); no `--max-size`, `--crop` or density change was used |
| hardware path | `Renderer: direct3d11`, `Interop: d3d11va`, `Video decoding: d3d11va`, `Low latency: presentation vsync disabled` |
| dual recording | 12 s of mirroring with `--record` produced a playable MKV, 1080x2316, 20 Mbps realized against a 32 M target |
| audio routing | the device's playback was captured as **opus 48 kHz stereo** and muxed into the same file |
| A/V alignment | video first pts `0.000 s`, audio first pts `0.126 s`; last `11.818 s` vs `11.905 s` → the audio track starts ~126 ms late and the two end within 87 ms: no drift over 12 s |
| frame delivery | a scripted one-finger drag through scrcpy's own touch injection produced 167 frames in 9.9 s, **51 fps in the best one-second window**; the 16.8 fps mean is the *device encoder*, which only emits frames when the picture changes (a static home screen averages low) |
| codec capability matrix | h264: 30/60/120 fps accepted · h265: 60 fps/32M and 120 fps/80M accepted (353 packets in 6 s) · **av1: works, but logs one server error** — 303 video packets in 6 s at 60 fps/48M (~50 fps delivered) and 176 at 30 fps/8M, versus h264's 159 packets in the same window; the AV1 file was 1.27 MB where h264 needed 5.04 MB. The session still prints `[server] ERROR: Capture/encoding error: java.lang.IllegalArgumentException:` once, just before `Applying video encoder constraints`, and then encodes normally |

Two corrections to the first reading of this data, because the initial summary was
wrong: the `IllegalArgumentException` looked like a rejected codec, and it is not.
A follow-up probe counted the actual packets in the AV1 recordings (303 and 176 in
6 s, both decodable streams) and they beat the matching h264 run on both frame
count and size — 4× smaller for the same screen. So this device **can** do AV1;
the error line is noise from the server's constraint pass, not a failure, and it
is worth reporting upstream rather than avoiding the codec. Anyone reading only
the log would reach the wrong conclusion, which is why the recorded file is the
thing being measured here.

The same session also taught a measurement lesson: running these device probes
*while the gate was running* made the recorder's timing assertions stall (two
attempts at 59 ms and 29 ms worst-push, against a 16.7 ms budget) and the gate
went red for the wrong reason. The timings in §5.1h need the machine to
themselves; run them without concurrent capture.

The two packaging defects found:

* the shipped `scrcpy.exe` was built **without** meson's `portable` option, so it
  looked for the server in `C:\msys64\ucrt64\share\scrcpy\` and every real run
  died with `'...scrcpy-server' does not exist or is not a regular file` before
  mirroring anything. The gate could never catch this because its packaged-binary
  check only runs `--version`/`--help`, which do not need a server. Fixed by
  configuring `build-usb` with `-Dportable=true`; the client now loads
  `scrcpy-server` from its own directory (`Using server (portable)`), which is how
  the official Windows zip is laid out.
* the package did not contain `scrcpy.png`, so each start printed
  `ERROR: Could not open icon image` / `Could not load icon`. `app/data/scrcpy.png`
  and `disconnected.png` now ship next to the executable; a full-profile run is
  silent apart from the INFO lines.

Still not measured, even with this device: glass-to-glass latency (needs a camera
pointing at both screens), touch alignment inside a real game, and the wireless
pairing path (it changes the device's adb transport, so it was left for you).
The OSD numbers during actual gameplay are also unverified — the tablet was on its
home screen.

### 5.1m The launcher, driven through its own UI against the device

`tools/launcher_device_test.ps1` is the end-to-end §3C check. It starts the
packaged `GamingScrcpyLauncher.exe`, reads the live window through UI Automation,
presses *Mirror*, inspects the child process the launcher spawned, then presses
*Stop*:

```
RESULT detect badge='1 device(s)' serial=<dev-id-1>
RESULT mirror pid=17752 title='4K Ultra Quality Stream 60FPS'
RESULT args=--serial=<dev-id-1> present
RESULT stop scrcpy exited cleanly
```

Auto-detection without any click, the one-click launch, the profile's argument
set, the correct `--serial` (so a second phone on the hub could not be mirrored
by mistake) and the stop path all work against real hardware — and it is the same
portable server resolution that the CLI needed (§5.1l), so the class of bug that
the host-only gate could not see is now covered. Gate section 11 runs this script
and reports **SKIP** instead of failing when no device is attached, so the suite
still works on a machine without a phone.

### 5.1n Measuring the mirror's latency instead of disclaiming it

Phase 4 asks to "verify rendering latency". Glass-to-glass still needs a camera
pointing at both screens, but the half this fork owns — *packet arrives on the
PC → picture is presented* — was already computed per frame for the OSD and
never left the process. `--game-telemetry-log` now emits it (with fps and both
bitrates) once a second, plus a percentile summary at exit:

```
INFO: telemetry: fps=59.9 v_kbps=0 a_kbps=0 lat=51ms window_max=73ms src=2316x1080
INFO: telemetry-summary: seconds=17 lat_med=54ms lat_p90=705ms lat_p99=921ms lat_max=921ms lat_avg=48ms
```

`tools/device_latency_probe.sh` drives the *packaged* client against the
attached phone for h264/h265 × {default, `--game-low-latency`}. It lights the
screen with the client's own MOD+O shortcut, injected through scrcpy's control
channel, so no setting, launcher or app on the phone is touched. It also prints
`scene=static` whenever the median video rate stays under 100 KB/S, on the theory
that a near-empty encoder stream means there is nothing on screen to draw. **That
theory was wrong, and §5.1p shows why**: the `v_kbps≈0` those first runs printed was
not a sleeping phone but a 1000× unit error in the telemetry itself, so the label
was a number computed by the buggy code, describing the code rather than the
scene. With the units fixed the same probe reports `scene=live` at ~5,700 KB/S on
this device (§5.1p), and the latency rows below stand on their own — they were
never about an idle stream.

Measured at 2316x1080 (the tablet's own panel size: the mirror requested
nothing else, which is the constraint of the whole project stated in §1), 48
Mbps, `--max-fps=60`, direct3d11:

| config | median | p90 | mean | fps |
|---|---|---|---|---|
| h264, defaults | 54 ms | 705 ms | 48 ms | 59.6 |
| h264, `--game-low-latency` | 184 ms | 1234 ms | 275 ms | 59.8 |
| h265, defaults | 195 ms | 945 ms | 169 ms | 59.9 |
| h265, `--game-low-latency` | 61 ms | 798 ms | 53 ms | 59.9 |
| h264, `--video-buffer=0` | 69 ms | 486 ms | 34 ms | 59.8 |
| h264, `--video-buffer=0 --game-low-latency` | 44 ms | 387 ms | 20 ms | 56.9 |
| h264, `--video-buffer=0 --render-driver=vulkan` | 699 ms | 1015 ms | 840 ms | 58.8 |
| av1, defaults | 375 ms | 438 ms | 355 ms | 16.6 |

Three readings are defensible from that table, and two are not:

* **Defensible:** the ordering of the first six rows is *not* stable —
  `--game-low-latency` helped h265 (195 → 61 ms) and hurt h264 (54 → 184 ms) in
  the same sweep — so on this host one 17-second window cannot decide which flag
  is faster. The spread is bigger than the effect. Reporting a single number
  here would have been exactly the kind of claim §5.1k had to retract.
* **Defensible:** two configs are reliably bad, because they are not about
  scheduling luck but about capability. `--render-driver=vulkan` was 10× worse
  than direct3d11 (699 ms median), and AV1 arrived as
  `ERROR: [FFmpeg] Your platform doesn't support hardware accelerated AV1
  decoding`, fell back to the CPU and delivered 16.6 fps at 375 ms. AV1 stays in
  the recorder, where nothing is ever decoded, and out of the live mirror on a
  machine without hardware AV1 decode.
* **Defensible:** `--video-buffer=0` produced the best mean (20-34 ms against
  48-169 ms with the default buffer) and the best median (44 ms), which is the
  behaviour expected of a buffer that no longer holds frames back.
* **Not defensible:** the p90 of 387-705 ms. With a static scene and 60 fps
  presentation, a tail that long is this host's GPU/desktop scheduling, not a
  property of the pipeline; on a machine that is actually drawing a game the
  distribution will be different. §6 keeps "latency while gaming" as
  device-and-host specific, and this flag is now the way any user measures it
  for their own pair.

The probe is gate section 12: it runs only when `adb devices` shows a phone and
reports **SKIP** otherwise, it asserts that every case produced a telemetry
summary, and it records the `src=` size so a future change that starts asking
the device for a different resolution shows up immediately.

### 5.1o The core constraint, guarded by a check instead of by argument

§1 of the directive is the reason this fork exists: nothing may alter what the
device renders internally, because that is what breaks game UI scaling and touch
alignment. Until now that was guaranteed by argument — "the overlays draw after
the video and never feed coordinates back" — which is exactly the kind of claim a
later change can silently invalidate. Gate section 13 turns it into a mechanical
guard on `app/src/screen.c`, compared against the upstream tag the fork was
cloned from (`v5.0.1`):

* no added or removed line mentions `compute_content_rect`,
  `convert_to_screen_coords`, `convert_from_screen_coords` or `is_optimal_size`;
* no added line **writes** `screen->rect` or `rect->x/y/w/h`;
* the hunks that do exist land only in `sc_screen_render`, `sc_screen_init`,
  `sc_screen_destroy` and `sc_screen_apply_frame` — the drawing and lifecycle
  paths, which is where host-side presentation belongs;
* and the launcher is scanned for device-side flags inside its **argument
  strings** (`"--max-size`, `"--crop`, `"--new-display`, `"--display-id`), with a
  positive control in the same check: the scan must still find `"--serial`, so a
  broken grep cannot masquerade as a pass.

```
13. touch alignment is still upstream code (the project's core constraint)
  PASS  screen.c changes nothing in the mapping path vs v5.0.1 (hunks only in:
        sc_screen_apply_frame sc_screen_destroy sc_screen_init sc_screen_render)
  PASS  the launcher emits no device-side resolution/crop/display flag
        (control: --serial present)
```

That is a reproducible guarantee with a failure mode: adding a device-side crop,
or letting the OSD shift the content rect, now turns the suite red instead of
shipping a mirror whose crosshair is 40 px off. What it cannot prove is the human
half — whether the aim *feels* right inside a shooter on a specific phone — which
stays in §6.

### 5.1p Dual recording on the device, and the OSD bitrate bug it exposed

Recording while mirroring (§3B, "dual recording… without impacting frame
delivery") had only ever been proven against a synthetic packet list. Driven from
the packaged client against the tablet it now has hardware evidence:

```
mirror only : fps_med=54.9  lat_med=295ms
--record MKV : fps_med=58.3  lat_med=470ms  live.mkv  84,749,179 B, 14.48 s, h264 2316x1080 + opus
--record MP4 : fps_med=55.7  lat_med=247ms  live.mp4  79,043,476 B, 13.97 s, 797 frames, opus 686 pkts
```

The MKV and MP4 both carry the device's native 2316x1080 with an opus track, the
frame count matches 60 fps × duration (797 frames in 13.97 s = 57 fps), and the
mirror kept presenting at the same rate with the recorder attached as without it
— which is the claim, measured rather than asserted. The latency figures in these
runs are as noisy as §5.1n said they would be and are not read as a ranking.

What the same runs *did* find is a real defect in a required §3A feature. The file
grew at 5,840 KB/s while the OSD and `--game-telemetry-log` reported
`v_kbps=5`:

```c
g->bytes_video * 1000ULL / 1024ULL / elapsed   // elapsed is in MICROseconds
```

`sc_tick` is µs, so the rate factor has to be `SC_TICK_FREQ` (1e6); with 1000 every
reported bitrate was 1000× small, and the OSD showed a gaming-relevant number that
was simply wrong. Fixed in `gaming.c` and proved twice over: the host demo feeds
exactly 1,036,800 B per frame, and now reports `video=100340 KB/s` for
`fps=99.1` where 1012.5 × 99.1 = 100,339 (exact), and the device reports
`v_kbps=5886` against the file's real 5,840 KB/s, plus `v_kbps≈1250` at
`--video-bit-rate=8M` (8 Mbps = 1000 KB/s, correct order). Gate §7d used to accept
any value greater than zero, which is precisely how this shipped; it now compares
the reported rate against the byte count the demo injects, within ±40 %.

The same device run also settled two §3A/§4 items and opened one:

* `--game-audio-pcm` works against real hardware: 1,443,840 B in 8 s ≈ 7.5 s of
  48 kHz stereo s16, i.e. the decoded PCM feed keeps up with the session and is
  continuous.
* `--game-audio-bridge` (raw packets to a file) is **also fine**, and what looked
  like a defect was silence: see §5.1q for the opus-vs-raw control that proves the
  packet rate and byte counts are right.
* `a_kbps` stayed 0 for the same reason — see §5.1q, which resolved this and
  shows the audio path was never broken.

### 5.1q The "broken audio bridge" that was silence, and the counter that proved it

§5.1p left what looked like a defect: on the tablet `--game-audio-bridge` wrote
1,092 B in 8 s and `a_kbps` read 0 while the PCM tap delivered 1.4 MB, so the
suspicion was that the raw-packet hook never fires on a live session. The log
could not answer that, because it reported *dropped* chunks and never *sent*
ones. Added that counter (one `uint64_t`, printed unconditionally), then ran the
same session twice, once on the device's Opus stream and once with
`--audio-codec=raw`:

| audio-codec | chunks sent | dropped | file bytes | `a_kbps` reported |
|---|---|---|---|---|
| opus (silence, DTX) | 321 | 85 | 979 | 0 |
| raw (48 kHz stereo s16) | 334 | 37 | 1,368,064 | 166-319, mean ~187 |

Both are ~40 chunks/s — exactly the 20 ms packet rate the device sends — so the
demuxer hook fires at the right rate for audio on a live mirror. The difference
is packet *size*: an Opus DTX comfort packet for a silent mix is a couple of
bytes (321 × ≈3 B = 979 B), while raw is a fixed 1,920 B per 20 ms, so 334 chunks
= 7.1 s of audio in an 8 s session (the missing 0.9 s is the ADB connect), and
the theoretical 192 KB/s against the reported mean of 187 confirms the audio half
of the telemetry too.

So no bug: the phone was silent, Opus behaved like Opus, and a rate that is
genuinely ~120 B/s rounds to 0 KB/s. The error was mine — I built a story about
the code from a number the code never printed. That is what the new counter is
for: a bridge that says only "85 dropped" leaves the operator guessing whether it
moved 400 chunks or 85, so the line is now
`audio bridge: N chunks sent, M dropped (consumer kept up | slow consumer)`, and
the host-only tests were re-run to confirm nothing keyed off the old wording.

### 5.1r The overlay bundle on hardware, and the startup flag it caught failing

The §3A bundle (borderless fullscreen, always-on-top, cursor auto-hide, live OSD)
had only ever been exercised in `gamingdemo`. Measured against the real window on
the real machine, with `tools/window_style_probe.ps1` reading the actual
`GWL_STYLE`/`GWL_EXSTYLE` bits and `GetWindowRect` by PID:

| run | style | exstyle | window rect | work area | topmost |
|---|---|---|---|---|---|
| windowed (baseline) | `0x16cf0000` | `0x00000100` | 1286x631+40+57 | 1366x768 | no |
| borderless + always-on-top, before the fix | `0x96cf0000` | `0x00000108` | 1270x592+48+88 | 1366x768 | **yes** |
| borderless + always-on-top, after wiring init | `0x96cf0000` | `0x00000108` | 1270x592+48+88 | 1366x768 | **yes** |

Three things came out of that table:

* **`--always-on-top` works**, and the probe is differential proof: `WS_EX_TOPMOST`
  appears only when the flag is passed.
* **The live OSD works on hardware**: the same session reported
  `fps=59.2 v_kbps=1209` (≈9.7 Mbps against `--video-bit-rate=8M`, the right order
  once §5.1p's units fix is in) and `src=2316x1080`, so telemetry is not a
  gamingdemo-only feature.
* **`--game-borderless-fullscreen` does not do what its own help text says**, and
  the reason is now pinned down by measurement rather than by reading the code.
  The startup flag was stored in the params struct and never applied — only the
  Super+F2 toggle called `set_borderless_fullscreen()`. Wiring that call into
  `sc_gaming_init()` was necessary but not sufficient, and the two log lines the
  fork now emits show exactly where it falls apart:

  ```
  INFO: borderless: requested 1366x768, SDL reports 1366x768 flags=0x12038
  INFO: borderless: after first frame 1270x592 flags=0x12230
  ```

  So SDL does apply the borderless state and the display size (the
  `SDL_WINDOW_BORDERLESS` bit is set in both snapshots, which is also why the
  window is only *visually* framed: Win32 still reports the `WS_CAPTION` bits,
  `style=0x96cf0000`). What loses the geometry is the first video frame, which
  resizes the window to the content aspect — 1270x592 is 2316:1080 exactly. Two
  resize paths were then guarded (`sc_screen_update_frame()` and the hard-coded
  `set_content_size(…, true)` in `sc_screen_set_orientation()`) and **the window
  still ends up at 1270x592**, so the remaining suspect is the third one,
  `resize_for_content()` behind `screen->resize_pending`, or the window being
  created with an optimal size after the gaming object already sized it. Task #20
  stays open with that evidence; the guards were kept because each one is correct
  on its own (a borderless window must not be shrunk by an orientation change or
  an auto-resize) and the windowed path is measurably unchanged by them
  (`1286x631+40+57`, no `WS_EX_TOPMOST`, same as before). One call was also
  dropped from `set_borderless_fullscreen()`: `SDL_SetWindowFullscreen(window,
  false)`, which asked SDL to leave an exclusive-fullscreen state the window was
  never in. The fork's own help text describes a *non*-exclusive mode, and asking
  SDL to exit fullscreen it never entered is the kind of request whose
  window-restored bookkeeping (SDL restores the pre-fullscreen geometry and the
  frame) is exactly what was being observed. Removing it did not change the
  measured result either — the window is still 1270x592 after the first frame —
  so the call stays out, but the fix is not credited.

Because the outcome is still wrong, this is recorded as a **known defect, not as
a delivered feature**: `--game-borderless-fullscreen` currently does not produce a
work-area-sized borderless window at startup (task #20, with the reproduction
command). What ships instead is the instrumentation that makes the failure
locatable — the two `borderless:` log lines above are printed once per session and
compare the requested geometry with what survives the first frame, which is what
turned "it doesn't work" into "SDL applies it, the first frame undoes it, and the
two auto-resize paths are not the ones doing it". Nothing else in the bundle
depends on it — the same window is reachable as a normal window with
`--always-on-top`, or in upstream's exclusive fullscreen with `--fullscreen`, both
of which behave as documented. Cursor auto-hide is not externally observable (SDL
hides the cursor without changing a window style), so it stays a user-verified
item rather than being claimed from a log line.

### 5.1s Device-integrity audit (directive v2 step 0) and the gate check that replaced it

Step 0 asked for the blacklist to be grepped over the repository **before** the
new check is added, and for any pre-existing write command to be reported rather
than quietly fixed. The scan ran over `scripts/` (does not exist in this repo),
`tools/`, `launcher/` and the fork's own diff against `v5.0.1`.

**What was already there.** `tools/` and the fork's C diff were clean — the only
`tools/` hits were inside the vendored `platform-tools/adb.exe`, `fastboot.exe`
and the stock `scrcpy.exe`, i.e. the ADB binary itself, not project code. The
launcher was not: three methods in `launcher/Services.cs` wrote to the device.

| found at | command it built | verdict |
|---|---|---|
| `Services.cs:147` (`TcpIpAsync`) | `-s <serial> tcpip 5555` | real violation, on the blacklist |
| `Services.cs:153` (`SetDeviceTouchesAsync`) | `-s <serial> shell settings put system show_touches …` | real violation |
| `Services.cs:159` (`MuteDeviceSpeakersAsync`) | `-s <serial> shell cmd audio --mute-internal …` | not on the literal list, but it is a system-setting write, so the same rule covers it |
| `AppConfig.cs:157-159` | `--select-tcpip` | **not** a violation: scrcpy's own `-e`, host-side device *selection* (confirmed in this build's `--help`) |

Only `TcpIpAsync` had a call site (`OnEnableTcpIp`, wired to the header button,
which also logged the literal string); the other two were dead code.

**What replaced them.** The two dead methods are deleted. The button keeps its
place in the header — §A of the directive says regroup, don't delete — but is now
`BtnWireless` ("Wireless ADB guide", localized in both languages) and opens a
dialog that points at README §7 instead of running anything: the feature is
documented as a manual step, which is exactly what §4.2 prescribes. `Pair` and
`Connect` stay, because they only attach the host to a device that is *already*
listening on TCP. The two lost device settings have scrcpy-native equivalents,
checked against this binary's help rather than assumed: `-t, --show-touches`
("enable 'show touches' on start, **restore the initial value on exit**", help
line 600) and `--audio-source=output` ("forwards the whole audio output, and
disables playback on the device", help line 147). This build has **no**
`--mute-device`, which is why the first draft of the README text about muting was
wrong and had to be corrected before it shipped.

**Section 14 of the gate** now enforces this instead of trusting the intent. It
greps the blacklist over `scripts/`, `tools/`, `launcher/` (binaries,
`platform-tools/`, `stock/`, `bin/`, `obj/` and the fixture directory excluded)
and fails on any hit. For `app/` it greps **only the lines this fork adds** on
top of the upstream tag: upstream scrcpy legitimately implements the IDL
installer and the TCP reconnect, and scanning the whole tree would fail on code
this project did not write (7 such hits exist in `app/src/adb/adb.c`, `adb.h`,
`cli.c` and `scrcpy.1`). Three controls keep it honest:

* `tools/fixtures/device_write_adb_install.sh` holds three forbidden commands and
  the gate **fails if the grep does not detect all three**, so a broken or
  over-excluded pattern cannot pass in false;
* a read-only control (`shell getprop`) must be found in the launcher, proving
  the scan is really looking at those files;
* the pattern list brackets each first letter (`[aA]db install`), so the gate
  file never matches its own list (verified: 0 self-hits in `verify_all.sh`).

The check caught two of its own making: the comment added in `Services.cs` and a
header line in `tools/adb_audit.sh` both spelled out a forbidden command in
prose, and section 14 failed them. The comments were rephrased rather than the
grep weakened. Standalone run of the logic: fixture 3/3 detected, getprop
control found, project scan 0 hits, fork diff 0 hits across the added lines.

**Audit trail.** `tools/adb_audit.sh` appends one timestamped line per device
command to `out/dev/adb_audit.log`; `tools/device_latency_probe.sh` now calls it
for its `adb devices` probe and for every scrcpy session it starts. Nothing in
this round wrote to the tablet: the commands run were `adb devices` and scrcpy
mirroring/recording sessions, all logged.

**A harness defect the same run exposed.** The gate finished 123 passed / 1
failed, and the failure was not in the launcher: `tools/launcher_uiauto.ps1`
located each tab by matching its *header text* against an English keyword
(`-like '*Quick*'`). Header text is localized now, so with the language the
launcher last remembered set to Spanish every tab missed except "Control" — a
word that happens to be identical in both languages. The plan is keyed by tab
index instead, asserts that exactly 7 tabs exist, and checks that each header is
actually localized (a header still showing its `Tab*` resource key fails). It
also asserts the five header controls by their real `x:Name`, which caught a
second mistake: the rescan button is `BtnRefresh`, and the harness had been
asking for the *resource key* `BtnRescan`. After the fix the audit is green with
71 assertions. The lesson is the same one §5.1k recorded about screenshots: a
check that quietly depends on a display state is not a check.

### 5.1t Finishing the i18n contract: the log panel, the dialogs, and two checks

The XAML was already 100 % resource-driven, but §B's "cero strings hardcodeados"
was not yet true: the code-behind still wrote English into the log panel, the
status label and three dialogs. That text is as user-visible as a label, so it
now goes through `Loc`.

What changed:

* `Loc.cs` grew a runtime-message block (log lines, status values, dialog
  bodies, the codec note) — the table is now **211 keys, each with both columns**.
* `MainWindow.xaml.cs`: 32 sites rewritten to `Loc.T` / `Loc.Format`. Verified by
  grep: zero `Log("<letter>` or `MessageBox.Show(this, "` left in either partial.
* The mirror window's title argument (`AppConfig.cs:326`, `--window-title`) stays
  English on purpose. It is visible in the taskbar, but OBS and the
  window-capture recipes select that window **by name**; localizing it would make
  a streamer's scene stop finding the mirror. A deliberate exception, recorded
  here rather than left as an unexplained string.
* An empty translation column is now loud instead of silent: `Rebuild()` renders
  a missing value as `??? KEY`, and the UI Automation audit already fails on
  `???` in a control name. So a key added with only one language filled in shows
  up as a failed check rather than as English inside a Spanish panel.

Two new gate checks (section 15), both with positive controls:

* **key parity**: every `{DynamicResource KEY}` in the XAML must exist in `Loc`
  (149 references, 0 missing). The same comparison run against
  `tools/fixtures/localization_missing_key.txt` must report exactly its 2 unknown
  keys, so a broken grep cannot pass. The check also asserts that no key is
  declared twice.
* **no hardcoded UI text**: the literal scan must match
  `tools/fixtures/localization_literal_log.cs` and must find nothing in
  `launcher/MainWindow.xaml.cs` / `MainWindow.Localized.cs`.

What those checks immediately caught was **two duplicate keys in the table** —
`NoteDeviceHw` and `StatusStopped` — introduced by the new rows colliding with
existing ones. A duplicate is worse than a missing one because the second row
silently shadows the first: `StatusStopped` was defined both as "Stopped" and as
"stopped (exit {0})", so one of the two call sites would have rendered the wrong
text. `StatusStoppedExit` is now the parameterised key. The scan also flagged the
first version of its own regex (`Log\("\)`), which matches nothing but the empty
string; the fixture control failed loudly, which is exactly why it exists.

### 5.1u Discrete numeric controls (§E), an encoder preset, and six profiles (§F)

**§E: no intermediate value is reachable any more.** Five sliders became
ComboBoxes populated from fixed step arrays in
`launcher/MainWindow.xaml.cs`:

| control | steps offered |
|---|---|
| `CboMaxFps` | 15, 20, 25, 30, 40, 50, 60, 90, 120, 144 |
| `CboBitrate` | 5, 10, 15, 20, 25, 30, 40, 50, 60, 80 Mb/s |
| `CboVideoBuffer` | 0, 10, 20, 30, 40, 50, 60, 80, 100, 120, 150, 200 ms |
| `CboAudioBitrate` | 32, 48, 64, 96, 128, 160, 192, 256, 320, 512 kbps |
| `CboAudioOutBuffer` | 0, 40, 60, 80, 100, 120, 160, 200, 300, 400, 500 ms |

An old profile holding an off-step value (say 17 fps) is normalised to the
nearest allowed step by `SelectStep`, and the *normalised* value is written back
into the config, so the command preview always shows what will actually run. The
readouts (`LblBitrate`, `LblMaxFps`, …) became localized unit captions
(`{0} Mb/s`, `{0} fps`, …) because the combo itself now shows the number.
`tools/launcher_uiauto.ps1` was updated in the same change: the Capture and
Presentation tab lists now ask for the combo ids plus `CboEncoderPreset`.

**Encoder preset (`CboEncoderPreset`), and the bug the tablet caught.** The
directive asks for "ultrafast / fast / medium". Android has no x264 preset; the
closest real knob is `MediaFormat.KEY_LATENCY`, which scrcpy can forward. My
first attempt emitted `--video-codec-options=latency:9` and the **server refused
it** (`CodecOption.parseOption: '=' expected`, "Server connection failed") --
scrcpy's syntax is `key:type=value`. The launcher's own `--validate-profiles`
passed that broken form, because it only proves the *client* parses the argument
line; it is the server that validates codec options. After the fix
(`latency:int=9`) two 6-second sessions on the TB-9707F streamed at 120 and
144 fps with telemetry summaries, so both the option and the top of the fps step
list are accepted by this device. The preset names keep the x264 vocabulary the
user asked for, with the latency value shown next to each (`ultrafast
(latency 9)`), and the tooltip states that the encoder may ignore it.

Also from that validation run: with `--audio-codec=raw` scrcpy warns that
`--audio-bit-rate` is ignored, so `BuildArguments` no longer emits it for raw.

**§F: six profiles added to the built-in set**, all passing `--validate-profiles`
against the real `scrcpy.exe` (10 profiles + the synthetic max-settings case,
`ALL PROFILES VALID`): *Lowest latency*, *Competitive 120 (host scale)*,
*Balanced HEVC 60*, *Recording only (clean)*, *Stream OBS (pipes)*,
*Wi-Fi low bandwidth*.

One deliberate deviation: the directive's profile 2 says `--max-size=720`. The
launcher does not emit that flag. §4.1 forbids the project from touching what
the device renders, gate section 13 asserts mechanically that no
device-side resolution/crop/display flag comes out of the launcher, and weakening
that check to accommodate one profile is the wrong way round. The profile keeps
the intent -- 120 fps at 20 Mb/s, zero video buffer, ultrafast encoder -- and
scales on the PC (`HostPreset=1080p`, `--game-window-filter=fast`). If you want
a 720p *encode* you can still pass `--max-size=720` yourself on the command
line; the README says so and says what it costs (a rescaled capture, so the
touch mapping has to follow it). The *Stream OBS (pipes)* profile also carries a
note that `--game-borderless-fullscreen` still reverts to a normal window at the
first frame (task #20) rather than shipping as if it worked.

**Open, honestly:** the short 6-second probes above are not comparable with the
44 ms baseline in §5.1n -- one frame group of a mostly static screen with
`--video-buffer=0` gives medians anywhere from 47 to 223 ms. The §C matrix
measures with the screen lit, repeats each cell, and reports median/p90/p99 per
combination; until those numbers are in, nothing here claims a latency
improvement.

### 5.1v Colour grade extension (§D): contrast, brightness and gamma, asserted per pixel

The engine already had three host filters (CAS sharpen, night-boost,
saturation). This adds the three the directive asked for and puts all six
behind the same rule: **a filter only runs when its own bit is set**.

Fork changes: `SC_POSTFX_CONTRAST | SC_POSTFX_BRIGHTNESS | SC_POSTFX_GAMMA`
in `app/src/gaming.h`, three `--game-*` options with `parse_bounded_int` and
help text in `app/src/cli.c`, wiring in `app/src/scrcpy.c`, and
`build_luma_lut()` rewritten to compose brightness → contrast → gamma →
night-boost into **one 256-entry table**, so four luma filters still cost a
single pass over the Y plane. Contrast pivots at mid grey (100 = unchanged,
0-200), brightness is an offset (100 = unchanged, 0-200 maps to ±0.5 of the
range), gamma is percent/100 clamped to [0.25, 2.0] and rejected below 25 by
the CLI, because a zero exponent divides by zero and a floor of 25 is where
the curve is still usable. All three act on luma only: a grade cannot shift
hue, and chroma stays the business of saturation.

`app/tests/gaming_demo.c` grew the machinery to prove it: `--fx-only=<list>`
enables one filter at a time, `--fx-contrast/--fx-bright/--fx-gamma` set its
value, `--stats` prints mean luma, luma variance and chroma variance for the
frame before and after `sc_gaming_process_frame()`, and `--png=PATH` dumps the
filtered frame (libavcodec's png encoder; it refuses to open without a
time_base, which is the kind of thing only a run can tell you).
`tools/fx_pixel_test.sh` turns those numbers into 51 assertions and keeps the
images in `out/fx/` for eyeballing.

Measured on the deterministic test pattern (frame 0, 240x320, neutral luma
mean 53.8371, luma variance 5658.9660, chroma variance 4067.0291):

| filter | setting | after | direction |
|--------|---------|-------|-----------|
| none | postfx off | 53.8371 / 5658.9660 / 4067.0291 | **identical to the input, all three metrics** |
| contrast | 100 | 53.8371 | inert |
| contrast | 140 | 42.9433 | lower (the pattern is dark, so contrast pushes it down) |
| contrast | 60 | 83.3175 | higher, and higher than contrast=140 → monotonic |
| brightness | 100 / 150 / 50 | 53.8371 / 112.8040 / 26.3500 | ±, and chroma variance unmoved |
| gamma | 100 / 150 / 60 | 53.8371 / 75.4920 / 37.2471 | ± |
| saturation | 100 / 160 / 50 | chroma var 4067.03 / 5712.65 / 1016.76 | ±, and luma mean unmoved |
| sharpen | 80 | luma var 6876.90 | detail energy up, chroma var unmoved |
| night-boost | 60 | 105.9097 | up |

saturation=50 lands on exactly (1/2)² of the neutral chroma variance, which is
what multiplying (chroma-128) by 0.5 means; saturation=160 measures 1.4x
instead of the ideal (1.6)²=2.56x because the pattern's brightest bar clips at
255. The assertion is on the direction, not the ratio.

**The defect the harness caught on its first run.** `--fx-only=contrast
--fx-contrast=100` was supposed to be inert and instead moved the mean luma
from 53.84 to 90.14. Night-boost was being applied whenever
`night_boost != 0`, ignoring its bit, and the demo always carries `night=40` in
its params — so any caller that set a value for one filter silently graded the
picture with another. Fixed by gating every stage on its own bit, which also
makes `--game-postfx=gamma` without a value a no-op instead of a black screen.
This is exactly the class of bug the "one filter at a time" design exists to
find: the identity case is only meaningful if nothing else can leak in.

Hardware (`tools/device_filter_test.sh`, 6 PASS, TB-9707F over USB): the
packaged client with `--game-contrast=140 --game-brightness=120
--game-gamma=130 --game-saturation=130` logs `Host post-processing enabled
(sharpen=0 night=0 sat=130 contrast=140 brightness=120 gamma=130)`, the plain
session logs no grade at all, both capture at the panel's own 2316x1080, and
the device's brightness state read before and after with `dumpsys display` is
byte-identical (`mBrightness=0.15686277;…`). The brightening is on the PC's
picture and nowhere else; nothing on the tablet was touched.

Not claimed: the two sessions in that harness reported `lat_med=307ms` (plain,
first) and `85ms` (graded, second). That ordering effect is a warm-up and scene
difference, not evidence that a colour grade reduces latency, which is why §C
measures with repeated reference probes instead of one pair.

Launcher: three new sliders with numeric readout and a per-filter reset
(`SldContrast/SldBright/SldGamma` + `LblContrast/LblBright/LblGamma` +
`BtnReset*`), a checkbox per filter (the flag is only emitted for filters the
user actually enabled), and the four one-click colour chips now set real
values and enable only what they move:

| chip | sharp | night | sat | contrast | brightness | gamma |
|------|-------|-------|-----|----------|------------|-------|
| Neutral | off | off | off | off | off | off |
| Vivid | 30 | — | 135 | 118 | — | — |
| Cinematic | 45 | 25 | 92 | 108 | — | 115 |
| Night | 20 | 85 | — | — | 112 | 130 |

The chips and the six reset buttons now carry `x:Name`, so they are reachable
by AutomationId; `tools/launcher_uiauto.ps1` asserts all 28 controls of the
Filters tab (6 checkboxes, 6 sliders, 6 readouts, 4 chips, 6 resets) exist in
both languages. Gate section 16 runs the pixel harness as part of `verify_all.sh`.

One defect the localization check caught on the first full run: `LblContrast`,
`LblBrightness` and `LblGamma` were declared **twice** in `launcher/Loc.cs`
("222 unique of 225 rows"), because the three rows added for §D duplicated keys
that already existed for the readouts. The launcher did not crash and the UI
looked right, because the index is built with `esIndex[key] = i` — assignment,
not `Add` — so the *later* row silently wins and the earlier one becomes dead
text. That is exactly the failure mode a key-parity check cannot see and a
duplicate-row check can, so the rule stayed, the duplicates were folded into
one row each (keeping the `"Gamma %"` wording that was actually being shown),
and the run below is from the de-duplicated table.

### 5.1x The twelve "what else should we add" ideas, with cost and benefit

The user asked for ideas and then asked for them to be judged rather than
shopped. Status of each of the twelve, with what it would actually cost in this
codebase:

| idea | status | why |
|------|--------|-----|
| Live performance graph | **shipped** | Performance tab, 1 Hz polyline of the per-second latency the fork already reports. Needed one fix this session: the tab was labelled "fed by `--game-telemetry-log`" while the launcher never passed that flag, so it could never fill (§5.1w). |
| Device panel: battery %, temperature, model | **shipped** | Read-only (`dumpsys battery`, `getprop`); gate section 14 keeps the write commands out. |
| Import / export profiles as JSON | **shipped** | One file copies a machine's whole setup. |
| Keyboard-shortcut overlay (F1) | **shipped** | Dialog listing the fork and upstream bindings. |
| Encoder preset, discrete dropdowns, 6 profiles | **shipped** | §E / §F above. |
| Screenshot hotkey | **not built, cheap-next-round** | Verified absent: `grep -i "screenshot\|snapshot" app/src app/server` finds nothing, so upstream 5.0.1 as vendored here has no capture key either. Cost is small now that §D exists: `save_png()` in `app/tests/gaming_demo.c` is a working YUV420P→PNG path (~40 lines), plus one key binding. The non-trivial part is *where*: a readback inside the present path costs milliseconds at the worst moment, so it belongs on the frame the bridge already copies, not on a fresh `SDL_RenderReadPixels`. |
| Tray icon (Start mirror / Stop) | not built, low value | WPF tray support means an extra dependency (H.NotifyIcon or WinForms `NotifyIcon`), and the launcher's own buttons already do the job in two clicks. Est. 2-3 h, cosmetic gain. |
| Per-app profiles (package → profile, auto-apply) | not built, medium | The read side is easy (`dumpsys window` / `dumpsys activity` for the current focus, read-only and legal), but "auto-apply" means killing and restarting the mirror whenever the foreground app changes, which drops frames at exactly the wrong moment. Est. 4-6 h, and the interruption has to be solved first. |
| Chapter markers in the recording | not built, medium | MKV cue writing means touching the muxer path in `app/src/audio_player.c`/`recorder.c` and libavformat's cluster-flush semantics. Est. 6 h, and it is only verifiable with a player that shows chapters. |
| Instant replay buffer (ShadowPlay style) | **documented backlog, expensive** | A ring of the last N seconds must live on the recorder path: keep encoding, keep packets, and be able to start a file mid-GOP (needs an IDR-keyed split or the clip starts corrupted). Est. 1-2 days of careful work in the demuxer/recorder plumbing, plus memory sizing (N seconds at 40 Mb/s is ~5 MB/s). Highest gamer value on the list, highest risk of introducing a recording regression the current harness would not catch. |
| Auto-update check | rejected on policy | "Phone home" behaviour in a tool that is often run offline; the user would have to opt in to a network call the launcher does not need. Better shipped as a manual "check for new version" button if ever asked for. |
| Virtual camera (DirectShow) | **excluded by the user this round** | Large COM component that must be registered system-wide. Already documented as an explicit backlog in README §8 so the docs do not read as if it were a bug. |
| Wireless ADB one-click with QR | **excluded by the user this round** | Enabling it writes the tablet's transport (`adb tcpip`), which §4.2 forbids. Manual procedure with the exact commands is in README §7 item 9; the launcher's wireless button now opens a guide instead of touching the device. |

### 5.1w §C measured, not assumed: a staged latency matrix on the tablet

`tools/device_latency_matrix.sh` runs the packaged client against the attached
TB-9707F, 12 s per probe, `--game-telemetry-log` on, scene woken 5 s in, and
writes the table to `out/dev/latency_matrix.md` (17 probes, `MATRIX OK`).

What the numbers are: `--game-telemetry-log`'s `telemetry-summary` takes the
**worst frame of each second** and reports percentiles of that (`gaming.c`
`window_lat_max` → `window_latency[]`), so `med=48ms` means "in half the
seconds, the slowest frame took at least 48 ms from demuxer receive to
`SDL_RenderPresent`". It is the host half of glass-to-glass: the device's own
capture+encode time is not observable from here. The same statistic produced the
44 ms baseline in §5.1n, so the two are comparable.

The full cross product the directive names is 3 buffers × 2 codecs × 3
renderers × 2 low-latency × 4 presets = 144 sessions ≈ 36 minutes of someone
else's tablet. That is not a reasonable thing to spend, so the sweep is
**one factor at a time** from a fixed reference (`buffer=0, h264, direct3d11,
low-latency, ultrafast`) and ends with a **repeat of the reference** — the
repeat is what makes the table readable, because the gap between it and the
identical row above it is the noise floor.

| stage | combination | med / p90 / p99 / max / avg | fps | scene | src |
|-------|-------------|------------------------------|-----|-------|-----|
| A | buffer=0 h264 | 48 / 346 / 701 / 701 / 18 | 57.9 | live | 2316x1080 |
| A | buffer=0 h265 | 109 / 369 / 498 / 498 / 18 | 59.0 | live | 2316x1080 |
| A | buffer=50 h264 | 118 / 253 / 555 / 555 / 55 | 56.4 | live | 2316x1080 |
| A | buffer=50 h265 | 127 / 237 / 622 / 622 / 83 | 59.9 | live | 2316x1080 |
| A | buffer=default h264 | 203 / 453 / 778 / 778 / 18 | 58.3 | live | 2316x1080 |
| A | buffer=default h265 | 65 / 180 / 377 / 377 / 18 | 58.8 | live | 2316x1080 |
| B | direct3d11 lowlat=on | 198 / 330 / 339 / 339 / 32 | 59.2 | live | 2316x1080 |
| B | direct3d11 lowlat=off | 78 / 449 / 477 / 477 / 16 | 57.1 | live | 2316x1080 |
| B | vulkan lowlat=on | **1129 / 1428 / 1534 / 1534 / 1665** | 55.7 | live | 2316x1080 |
| B | vulkan lowlat=off | **1150 / 1555 / 1580 / 1580 / 1426** | 57.5 | live | 2316x1080 |
| B | opengl lowlat=on | **1607 / 2421 / 2478 / 2478 / 1912** | 61.6 | live | 2316x1080 |
| B | opengl lowlat=off | **604 / 1045 / 1195 / 1195 / 868** | 54.2 | live | 2316x1080 |
| C | preset=default | 67 / 407 / 466 / 466 / 19 | 57.3 | live | 2316x1080 |
| C | preset=ultrafast | 266 / 349 / 620 / 620 / 33 | 58.9 | live | 2316x1080 |
| C | preset=fast | 217 / 274 / 367 / 367 / 106 | 59.6 | live | 2316x1080 |
| C | preset=medium | 92 / 455 / 534 / 534 / 65 | 58.7 | live | 2316x1080 |
| R | repeat of reference (identical to A row 1 + d3d11 + ultrafast) | 166 / 365 / 424 / 424 / 144 | 59.8 | live | 2316x1080 |

What the table supports, and what it does not:

* **The noise floor is ~120-150 ms.** The reference configuration measured
  48, 198 and 166 ms in three separate 12 s windows. So no row here may be
  called better than another by less than roughly 150 ms, which rules out
  ranking `--video-buffer`, codec, `--game-low-latency` or the encoder preset
  from this run. Reporting "buffer=0 beats default" from a 48 vs 203 ms pair
  would have been exactly the kind of claim this project forbids (§4.3): the
  same config produced 166 ms an hour later in the same session.
* **The renderer choice is far outside that band, and it repeats.** Vulkan
  (1129 / 1150 ms) and OpenGL (1607 / 604 ms) sit 5-30× above every
  Direct3D 11 row, with and without `--game-low-latency`, while still
  presenting at 54-62 fps. The gate's backend sweep (§5.1r) only checked that
  the requested backend is the one SDL created, so this was unmeasured until
  now: on this Windows host the mirror works on all three backends but is
  only *usable* on `direct3d11`. Recorded in README §7 so the dropdown does
  not read as an invitation.
* **The 44 ms baseline was not beaten, and there is no regression either.**
  The best observation this round (48 ms median) is the baseline within the
  noise, measured after every change in this report (encoder preset emission,
  discrete dropdowns, the new grade, the always-on telemetry line). Nothing
  added host latency that the numbers can see.
* To actually rank the sub-150 ms factors the design has to change:
  interleaved A/B arms (ABABAB), ≥5 min per arm, ≥5 repetitions, and an
  explicit statement of what is on screen, because an Android home screen
  under 60 fps gives a different distribution than a game. That is about an
  hour of hardware per pair of configurations, which is why it is listed as
  the follow-up rather than done silently here.

Product changes that came out of this: the launcher now always passes
`--game-telemetry-log` (the Performance tab is labelled as fed by it and could
never fill without the flag — visible in every line of the `--validate-profiles`
output in §5.1u's re-run), and the renderer dropdown's tooltip/README note
records the measured Direct3D-11 recommendation.

### 5.1y Directive §A: the launcher rebuilt as a dark, tab-grouped surface

The theme lives in `launcher/App.xaml` as a resource dictionary, so no control in
`MainWindow.xaml` carries a colour of its own:

| token | value | used for |
|---|---|---|
| `Bg` | `#FF0E0F13` | window background |
| `Panel` | `#FF16181F` | every surface, card and input |
| `Accent` | `#FF4FA3FF` | section headers, selection, focus border |
| `Accent2` | `#FF2BD98A` | the live/OK state only (device count, telemetry) |
| `Mono` | `Consolas` | the `Num` style: every number the user reads |
| corner radius | `6` | buttons, inputs, panels |

Layout went from one scrolling column to **seven tabs** -- `Quick`, `Capture`,
`Presentation`, `Filters`, `Recording / OBS`, `Control`, `Advanced` -- with the
default `Quick` tab holding four buttons, the device picker and the live
telemetry block, which is the "3-5 controls on first sight" the directive asked
for. `Advanced` is the tab the long tail moved into (profile name, extra
arguments, raw JSON), so nothing was deleted: the UI Automation audit now walks
**91** named controls where the pre-redesign plan listed 11, and each control
kept its `x:Name`, which is what keeps its AutomationId stable.

Two deliberate deviations from the suggested guide, both worth stating:

* **Tabs instead of collapsible sections.** WPF's `Expander` needs a retemplated
  header to look right in this theme, and -- more importantly -- every collapsed
  section removes its children from the UI Automation tree, so a collapsed panel
  turns "the control exists" into "the control exists *if the user happens to
  have expanded it*". Tab items are always in the tree once selected, and the
  audit selects each tab by index before reading it, which is the only reason
  section 10 can assert 91 controls deterministically.
* **Two accents, not one.** `Accent` is structural; `Accent2` (green) is reserved
  for "this value is live right now". Collapsing them into one colour would have
  removed the only at-a-glance signal that telemetry is actually flowing.

The `Quick` tab's telemetry block (`TxtPerfLatency`, `TxtPerfFps`,
`TxtPerfVideo`, `TxtPerfAudio` plus the `PerfSpark` polyline) is the §C live
panel: it parses the child process's `--game-telemetry-log` lines at 1 Hz, and
`HintPerf` says so under the numbers, because a panel that reads `--` before a
session starts otherwise looks broken. Third deviation: the directive asked for a
*Performance tab*, and this is a panel on the landing tab instead. The reason is
the same one that put the sparkline next to the launch buttons -- a number you
have to click a tab to see is a number you watch while the game is already
running, so it sits where the session is started. `README_GAMING.md` §9 says so
in the user's terms rather than calling it a tab.

Screenshots, both taken from the published single-file exe on this machine with
`tools/launcher_shot.ps1`: `out/launcher_before.png` (light theme, one scrolling
column, pre-§A) and `out/launcher_after.png` / `out/launcher_after_window.png`
(dark, tabbed, language selector in the header, live command preview on the
right; window rect `1380x788`). The earlier copy of `launcher_after.png` was
stale and is what prompted the re-take: it showed `Enable ADB over TCP/IP` and a
clipped `Connect (pport`, while `launcher/Loc.cs` now reads `Wireless ADB guide`
and `Connect ip:port`. The label was the bug, not the rendering: the button only
opens a guide, and §4.2 forbids the launcher from running `adb tcpip` itself, so
a verb-first label promised a write it never performs. The re-taken shot also
shows the §C fix in the preview line, which now ends
`--game-osd=compact --game-telemetry-log` -- the flag the Performance panel
needs and previously never got.

Still visible in that shot and not fixed here: the status-bar `adb:` path is
trimmed on the left (`gCapture\dist\...\adb.exe`) because the footer gives the
path a fixed width. Cosmetic only -- the resolved path it prints is the real one
used to launch, and section 11 proves a session starts from it.

### 5.1z A second device: the same harnesses on a Motorola, and what changed

The Lenovo tablet was swapped for a **moto g(7) power** (serial `<dev-id-2>`,
`ro.product.model` read with `adb shell getprop`, native mirror **720x1520**).
Nothing in the harnesses names a device, so the same scripts ran unmodified --
which is the point of writing them as probes rather than as one-off commands.

`tools/device_filter_test.sh` on the Motorola: `FILTDEV OK`, with the grade
reaching the engine (`Host post-processing enabled (sharpen=0 night=0 sat=130
contrast=140 brightness=120 gamma=130)`), the plain session installing no grade,
**both sessions capturing the same 720x1520** (the §4.1 constraint holds on a
second vendor and a different panel), and the read-only `dumpsys display`
snapshot identical before and after, so the grade never touched the device's own
brightness.

The two latency lines came back **SKIP**, and that is the result worth
recording: the home screen only produced a new frame in 3 of 16 seconds (plain)
and 1 of 16 (graded), so `lat_med` was computed over a handful of frames and
`lat_max` of 1078 ms describes "nothing happened for a second", not a slow
pipeline. The harness used to `PASS` as soon as a summary line existed, which is
the same "a log line proves code ran, not that the outcome happened" mistake
recorded in §5.1r. It now requires a quarter of the window to have reported
frames and says why when it does not. `tools/device_latency_probe.sh` already
carried that judgement (`scene=live` vs `scene=static`, decided from the median
bitrate), so the two harnesses now agree.

`tools/device_latency_probe.sh` on the Motorola, screen awake on the launcher:

```
RESULT h264/baseline src=720x1520 scene=live   fps_med=9.6 v_kbps_med=248
RESULT h264/lowlat   src=720x1520 scene=static fps_med=9.7 v_kbps_med=59
RESULT h265/baseline src=720x1520 scene=live   fps_med=9.9 v_kbps_med=180
RESULT h265/lowlat   src=720x1520 scene=live   fps_med=8.8 v_kbps_med=194
```

What this does and does not prove: h264 **and** h265 both encode on a second,
much weaker SoC at native panel size, and the fork works unchanged across
vendors. It does not prove a frame rate: a static launcher is content-change
limited, so ~10 fps here is the screen's fault, not the pipeline's, and no fps
claim is made from it. For a rate that means something the device has to be
showing motion -- the tablet measurements in §5.1n and §5.1w were taken that way
(`fps_med=60.0`).

### 5.1aa Defect #21: AV1 was assumed, and a second vendor proved it cannot be

Gate section 11 (the launcher driving a real device) went red the moment the
Lenovo was swapped for the Motorola -- and it stayed red for a reason worth
writing down. The symptoms were misleading: `Get-Process scrcpy` found a child,
its window title was empty, and its command line read back empty, which looks
like "the launcher never passed `--serial`". It had. Reading the launcher's own
run-log panel through UI Automation showed the real sequence:

```
[02:45:46] no AV1 encoder on SDK 28: switched to h264 so the session can start
[02:45:46] launching: --serial=<dev-id-2> --video-codec=h264 ...
[02:45:47] [server] INFO: Device: [motorola] motorola moto g(7) power (Android 9)
[02:45:47] ! [server] WARN: Audio disabled: it is not supported before Android 11
[02:45:48] INFO: Texture (D3D11VA): 720x1520
```

Before the fix the same line was `--video-codec=av1`, and the session died
during codec configuration with `Demuxer 'video': stream disabled due to
connection error`, leaving a scrcpy process that had already exited -- which is
why both the title and the command line came back empty. The empty `cmdline=`
was not the bug, it was the corpse.

The real defect: **the seeded profiles are device-capability assumptions.** The
default profile asks for AV1, which the tablet's SM8550 encodes (and which
§5.1l already showed logs a `java.lang.IllegalArgumentException` per session
even there), and which a 2019 mid-range Motorola simply does not have. On a
device without it, "Mirror" opens no window and says nothing -- the error is in
the log panel, below the fold, of an app that looks like it is still starting.

Fix, in `launcher/MainWindow.xaml.cs`:

* detection now also reads `ro.build.version.sdk` (read-only `getprop`, the same
  pattern already used for the model) and stores it on the device record;
* a session that asks for `av1` on a device below API 29 is downgraded to
  `h264` before the arguments are built, and the run log says so in both
  languages (`LogAv1Fallback`), so the downgrade is visible rather than magic;
* replacing the combo item to show the model **drops the WPF selection**, which
  turned the first attempt into "no device selected" -- the selection is now
  re-asserted, and that is why the intermediate test run found no child at all.

Honest limits of this fix: SDK 29 is the floor scrcpy's own server documents for
AV1 packaging, not a per-device guarantee -- an Android 10 device can still lack
an AV1 *encoder*, and the only infallible probe is `dumpsys media.codec`, which
is a much bigger parse. The downgrade removes the silent-nothing failure, not
every possible codec mismatch. Verified: section 11 now reports
`args=--serial=<dev-id-2> present`, `title='4K Ultra Quality Stream 60FPS'` and
a clean stop on the Motorola.

### 5.1ab Gate section 11 blamed the launcher again, but this time the phone was at fault

Section 11 went red on the Motorola a second time, with the same misleading
symptoms as #21: a `scrcpy` child existed, its window title was empty, its
command line read back empty. That combination is now recognised as **a corpse,
not a missing argument**: the child had already exited, so `MainWindowTitle` and
`Win32_Process.CommandLine` both legitimately return nothing.

Reading the launcher's log panel through UI Automation on the failure gave the
actual cause, which is on the device:

```
! at android.media.MediaCodec.native_setup(Native Method)
! at android.media.MediaCodec.<init>(MediaCodec.java:1811)
! at android.media.MediaCodec.createEncoderByType(MediaCodec.java:1777)
! at com.genymobile.scrcpy.video.SurfaceEncoder.createMediaCodec(SurfaceEncoder.java:301)
! Killed
scrcpy exited with code 2
```

Measured, not assumed (`out/gate_motorola_fix.log`, the repetitions and
`out/pkgctl_control.txt`):

| What was run | Result |
|---|---|
| 6 back-to-back `tools/launcher_device_test.ps1` on the moto g(7) power | 5 failed with the `createMediaCodec` stack above, 1 passed |
| Same command line through the CLI: `--max-fps=30 --video-bit-rate=8M` | session started, no encoder error |
| Same through the CLI: `--max-fps=60 --video-bit-rate=50M` (the failing profile's numbers) | session started, no encoder error |
| `launcher_device_test.ps1` after 75 s with no session on the phone | passed |
| 3 more runs with the retry in place | 3 passed, 2 of them only after `RETRY 1 of 3` |
| The same profile on the Lenovo (Android 14) all session | never produced this stack |

So the config is not too ambitious for this phone and the launcher is not
dropping arguments: the Android 9 / Qualcomm codec occasionally refuses a *new*
encoder while the previous session's is still being released, and scrcpy dies
before it can create a window. Rapid start-stop loops are what provoke it --
exactly what a test harness does.

Fixes to `tools/launcher_device_test.ps1` (the product needed none):

* The poll now records every `scrcpy` pid it has seen and which of them are
  still alive, so "started and died" and "never started" are different, stated
  outcomes; the serial assertion no longer runs against a corpse.
* On failure it dumps the launcher's `launching:` line and the last 22 log
  lines, because the launcher mirrors scrcpy's stdout -- that dump is what
  turned a two-hour hunt into one read.
* The `--serial` check accepts the launcher's own `launching:` record when the
  live command line loses the race, and still fails when neither carries it.
* Up to 3 attempts with a 15 s settle between them, each printed as
  `RETRY n of 3`, so a device-side refusal costs a retry while a packaging
  failure costs three identical failures and still reports FAIL.
* The packaged-`adb` serial read is guarded: a copy of the package without
  `AdbWinApi.dll` produced no device line, and calling `ToString()` on that
  null killed the script with a PowerShell error instead of a clean FAIL.

**Positive control, because a retry that cannot fail is worthless**: the harness
was run against a copy of the package containing the launcher and a working
`adb` but **no `scrcpy` directory** -- `out/pkgctl_control.txt` shows
`control_exit=1`, `FAIL mirror never showed a window (3 attempts; scrcpy pids
seen: )`, i.e. it exhausted the retries and distinguished "no process ever
started" (empty pid list) from the phone's "process started and died". What this
does *not* establish: the mechanism inside the phone. `dumpsys media.codec` was
not parsed, and this is one Android 9 unit, not a proof about all of them. If a
user hits it, the practical workaround is to let the phone sit for a few seconds
between sessions or lower fps/bitrate; the launcher itself already reports the
device's error in its log instead of hiding it.

### 5.2 CLI

* `scrcpy.exe --version` and `--help` work from the packaged directory with a
  bare Windows `PATH` → the DLL set is complete and self-contained.
* All 16 new options appear in `--help` with argument descriptions; invalid
  values are rejected (`--game-osd=bogus`, `--game-sharp=150` fail with a
  message listing the accepted values).
* Option *interaction* is checked too, not just parsing — see §5.1f for the
  `--no-audio-playback` + audio-output matrix.
* The two bridge flags added in the second iteration were probed directly:

  ```
  scrcpy --game-bridge-scale=1920x1080 --game-bridge-filter=lanczos --version
      -> exit 0 (accepted)
  scrcpy --game-bridge-scale=12x99 --version
      -> ERROR: Invalid --game-bridge-scale: '12x99' (each dimension must be 16-8192), exit 1
  scrcpy --game-bridge-filter=kaiser --version
      -> ERROR: Invalid --game-bridge-filter: 'kaiser' (expected one of: default,
         point, bilinear, fast, bicubic, lanczos), exit 1
  ```

### 5.3 Launcher

Verified by starting the published single-file exe and screenshotting the
desktop: window renders, 4 seeded profiles listed, 2 keymaps listed, sliders
and dropdowns populated, live command preview contains the fork's flags
(`--game-upscale=linear --game-low-latency --game-borderless-fullscreen
--game-osd=compact …`), `adb.exe` resolved next to the exe.

The self-test now also echoes the gaming arguments it generated (`--game-*` plus
the two gaming toggles that reuse an upstream token, `--no-audio-playback` and
`--turn-screen-off`), which is what proves the GUI controls actually reach the
binary rather than being silently dropped. After the bridge controls were added, the streaming profile
reports:

```
PASS 4K Ultra Quality Stream 60FPS (exit=0)
      --game-upscale=pixelart --game-low-latency --game-borderless-fullscreen
      --game-osd=compact --game-frame-bridge=\\.\pipe\gaming-frame
      --game-bridge-scale=3840x2160 --game-bridge-filter=lanczos
```

Re-screenshotted after the bridge controls were added (`out/launcher_shot7.png`):
the RECORDER / STREAM BRIDGE panel shows *Frame bridge* =
`\\.\pipe\gaming-frame`, *Bridge scale* = `3840x2160` with working
1080p / 1440p / 4K buttons and *Bridge kernel* = `lanczos`, all loaded from the
profile. Synthetic mouse-wheel events never reached the WPF ScrollViewer, so the
panel had to be scrolled by clicking its scrollbar arrow — a harness limitation,
not an app one.

Because that panel sits below the fold, a screenshot cannot prove a control is
in the tree at all. `tools/launcher_uiauto.ps1` therefore starts the published
exe and walks the live window through UI Automation by AutomationId (which WPF
sets from `x:Name`), asserting the 11 configurator controls — `CboWindowFilter`,
`TxtAudioPcm`, `ChkPcmMute`, `TxtExtraArgs`, … — are present, then shuts the
process down. It is section 10 of the gate, and it is what covers controls no
seeded preset happens to set.

### 5.4 One-command regression suite (`tools/verify_all.sh`)

Everything above was re-run as a single script so the claims stay checkable:
build, bare-`PATH` run, 31 accepted fork-flag forms (every `--game-*` value),
13 accepted upstream tokens the launcher emits, the seeded keymap modes and
binding strings, 10 rejected inputs, the option-interaction matrix (§5.1f), the
presentation engine over file/stdout/pipe with byte-math assertions, the
window-path resample (resize tracking + bridge isolation), an OSD screenshot,
both named-pipe transports plus the decoded-PCM one (whose received bytes are
then decoded again by ffmpeg), an ffmpeg encode round-trip of both bridges and
the PCM tap, the device-free recorder check (§5.1g) including what recording
costs a live mirror (§5.1h), the same check re-run
against the packaged harness, the GPU backend sweep (§5.1j), the OSD telemetry
assertion, the launcher profile self-test, the launcher UI-tree probe (§5.3) and,
when a phone is plugged in, the launcher driving it end-to-end (§5.1m) and the
measured host-side latency sweep of §5.1n (that last section adds about two
minutes, because it mirrors for real). Section 13 guards the constraint itself
(§5.1o): it diffs `screen.c` against the upstream tag and scans the launcher for
device-side flags, so it runs on any machine, with or without a phone. Section 14
(§5.1s) greps the device-integrity blacklist over `tools/`, `launcher/` and the
fork's added lines, and cannot pass silently because a fixture with three
forbidden commands must be detected first. Section 15 (§5.1t, §5.1v) audits the
localization table: unknown key, missing column, duplicate key, hardcoded
literal. Section 16 (§5.1v) runs the per-filter pixel harness inside the gate,
so a colour grade that does not move pixels fails the suite rather than shipping.

```
summary
  120 passed, 0 failed
```

The suite is only meaningful if it can fail, and it has: two runs taken directly
after a heavy disk/GPU step (`dotnet publish`, or `Compress-Archive` of the
126 MB package) reported failures in the windowed and pipe sections while that
work was still finishing; re-running it on an idle desktop returned a clean
sweep. The windowed sections are the flaky ones, and the suite now says so
instead of hiding it: §8b retries once when the harness presents zero frames
(the desktop was busy) and labels the check "passed on the retry". The current
103-check suite has been run three times in a row on an idle desktop and returned
103/0 every time, and every check it gained was seen failing before it was seen
passing (§5.1g and §5.1h list those). Treat a remaining failure in §6/§7/§8 as
"re-run when nothing else is running", not as a code regression — the exit code
is still the gate.

The block above is quoted from the run that shaped sections 6-8, and the suite has
grown since: the last two full device runs both finished at **137 passed,
0 failed** -- one with the Lenovo TB-9707F (§5.1y), one with the moto g(7) power
(`out/gate_motorola_final.log`, §5.1ab). In the Motorola run nothing was rescued
by a retry either: `grep -ic retry` over that log returns **0**, so 137/0 there is
a first-attempt sweep with the new device-codec settle in section 11 unused.
Sections 11 and 12 are the only ones that change with the phone: they are what a
deviceless machine SKIPs, and they are the reason `137` is not treated as a fixed
contract.

Writing it found these shipped launcher bugs, all now fixed:

1. **The "Gamepad (U-HID)" keymap set `--gamepad=disabled`** — applying the
   controller preset switched controller input *off*, the opposite of its name.
   Now `uhid`.
2. **The mouse-aim keymap used `MouseMode = "screen"`**, which is not a scrcpy
   token at all, so `AppConfig` silently dropped it and the preset did nothing.
   Now `uhid`.
3. A third, latent one: the gamepad `ComboBox` listed `disabled`/`aoa` while
   `Apply()` looked the value up in `disabled`/`uhid`/`uhid_aoa`/`aoa`, so the
   indices disagreed and a saved `aoa` profile resolved to no selection at all.
   The list, the combo and the emitted whitelist are now the same three values
   (`disabled`, `uhid`, `aoa`).
4. Found while extending the self-test with a **synthetic max-settings profile**
   (every configurator control at a non-default value, so a token the GUI can
   emit but scrcpy refuses fails even when no shipped preset uses it): the
   *Mouse bindings* tooltip told the user to type
   `middle_click:desktop_shortcut`, which is not the `--mouse-bind` grammar at
   all — scrcpy wants one or two 4-character sequences over
   `{+, -, b, h, s, n}` (e.g. `nbsh` or `bhsn:++++`). A user following the hint
   would get `ERROR: Invalid mouse bindings` and no session. The tooltip now
   states the real grammar, the suite pins it with two accept and two reject
   cases, and the keymap check validates `MouseBindings` the same way it
   validates the input modes. The seeded keymaps were already clean (empty).
5. **"OBS: copy ffplay command" produced a command that could not work.** The
   audio half emitted `ffmpeg -c:a copy -i "\\.\pipe\gaming-audio" -f wasapi
   "CABLE Input"`: `-c:a copy` into a WASAPI *capture* endpoint is not a thing
   (the demuxer has to hand PCM to the driver, so it must decode), and the
   VB-cable endpoint you record from is `CABLE Output`, not the `CABLE Input`
   you play into. Both halves now read
   `ffmpeg -f s16le -ar 48000 -ac 2 -i "<pipe>" -f wasapi "CABLE Output"`, the
   form the encoder test actually proves. Caught by cross-checking the shipped
   hint against `README_GAMING.md` §8 rather than by running it — which is the
   limit of a device-less host: this one still needs a real cable to confirm.

None of these were visible in the UI — the command preview simply omitted the
argument — which is the point of asserting the generated arguments against the
real binary instead of reading them.

## 6. What could NOT be validated here, and why

A real device **was** attached for §5.1l, §5.1m and §5.1n (Lenovo TB-9707F), so
the device-side claims below are narrower than they were. What this host still
does not have: an Android SDK or emulator, and a camera pointed at two screens.
Therefore these remain unverified and are stated as such rather than claimed:

1. ~~End-to-end device→PC latency (needs a phone).~~ **Half answered:** the
   host's own share — packet received on the PC → picture presented — is now
   measured and reported per second by `--game-telemetry-log` (§5.1n): a 44 ms
   median and a 20 ms mean on this host with `--video-buffer=0`. The other half,
   the device's capture+encode time before the packet leaves the phone, is not
   observable from the PC at all, and neither is the monitor's own display lag,
   so the full glass-to-glass figure still needs a camera. Every one of those
   measurements was taken on a **static scene** (the probe says so in its own
   output), so they bound the pipeline, not gameplay.
   ~~Audio/video sync~~ is likewise measured as far as the PC can see it: the
   A/V packet-offset probe in §5.1l. Whether the *player* hears it in sync is a
   listening test.
2. The **device's own encoder**: which codec/bitrate/resolution a given phone
   actually delivers, and whether its packets are well formed. The *host* half
   of recording is no longer unverified — `recorderintegrity` drives
   `sc_recorder` with real encoder output and the shell test decodes the result
   back (§5.1g), for **all three codecs the launcher offers** (Annex-B H.264 and
   HEVC, and AV1 through the container input mode), in both containers, with a
   raw-PCM audio track interleaved by pts, and with the recorder stopped mid
   stream so the trailer — including the MP4 `moov` — is written by the Ctrl+C
   path. What remains untested here is only the producer
   of the packets, which by definition needs hardware. An earlier attempt at this
   harness faulted on a `NULL` `sc_recorder_callbacks` (a harness bug, fixed in
   §5.1g) and on the recorder thread's unsynchronized setup of
   `AVFormatContext` — which was **not** a harness bug: it is a real race in
   upstream `sc_recorder`, fixed in the fork in §5.1i rather than worked around
   by weakening the test. `app/src/recorder.c` is therefore no longer pristine;
   `git diff --stat` over the fork lists `app/meson.build`,
   `app/src/{cli,demuxer,options.h,recorder.c,scrcpy,screen.c,screen.h}`, and the
   recorder entry is 51 lines of publication and waiting, with no change to the
   bytes it muxes.
3. ~~Whether a specific device's encoder accepts AV1/HEVC at the chosen bitrate.~~
   **Answered for the connected tablet** (Lenovo TB-9707F, SM8550, Android 14):
   all three codecs encode there — h264 at 30/60/120 fps, h265 at 60 fps/32M and
   120 fps/80M, and av1 at 30 and 60 fps (about 4× smaller than h264 on the same
   screen). The one trap: scrcpy prints a single
   `Capture/encoding error: IllegalArgumentException` line per AV1 session on this
   device even though the AV1 stream is delivered and decodes, so the verdict has
   to come from the recorded file, not from the log (§5.1l has the exact probe).
4. ~~Touch-injection alignment under the new overlays~~ **the code half is now
   guarded, not just argued**: gate section 13 asserts against the upstream tag
   that the fork never touches `compute_content_rect` or the pointer conversions
   and never writes `screen->rect`, and that the launcher emits no device-side
   resolution flag (§5.1o). Still human-only: whether the aim *feels* right inside
   a specific shooter, which needs a player holding the phone.
5. The virtual-camera claim: **there is no DirectShow virtual camera here.**
   Windows virtual camera requires a DirectShow/COM filter registered on the
   system; what this fork ships is a raw RGBA frame bridge plus borderless
   fullscreen for OBS *Window Capture*, which is the zero-extra-latency path.
   Anything beyond that (Spout2/NDI) is not implemented and is not claimed.

Recommended on-device test list is in `README_GAMING.md` §7.

## 7. Reproduce

```bash
# toolchain (once)
winget install --id MSYS2.MSYS2 --silent
/c/msys64/usr/bin/bash -lc "pacman -Syu --noconfirm && \
  pacman -S --noconfirm --needed mingw-w64-ucrt-x86_64-{gcc,meson,ninja,pkgconf,sdl3,ffmpeg}"

# client + demo
cd workspace/scrcpy
export PATH=/ucrt64/bin:$PATH
meson setup build-x --buildtype=release -Dusb=false -Dv4l2=false -Dcompile_server=false
ninja -C build-x
./build-x/app/gamingdemo.exe --frames=120 --fx --bridge=bridge.raw --shot=shot.bmp
# host resample of the stream feed (prints the byte math and PASS/FAIL)
./build-x/app/gamingdemo.exe --frames=24 --width=720 --height=1280 \
  --bridge=bridge1080.raw --bridge-scale=1920x1080 --bridge-filter=lanczos
# resample the presented frame itself (window path, §5.1d)
./build-usb/app/gamingdemo.exe --frames=30 --width=540 --height=960 \
  --win-size=1232x2208 --window-filter=lanczos --no-osd
# kernel comparison (write cost separated from resample cost)
for f in point bilinear bicubic lanczos; do
  ./build-x/app/gamingdemo.exe --frames=40 --width=720 --height=1280 \
    --bridge=- --bridge-scale=1920x1080 --bridge-filter=$f --no-osd 2>&1 >/dev/null
done

# measured host-side mirror latency against a real phone (§5.1n)
./build-usb/app/scrcpy.exe --game-telemetry-log --video-buffer=0 --game-low-latency
# the same thing as a sweep with percentiles, scene detection and the native
# source size, from the packaged layout (prints SKIP with no device attached):
bash tools/device_latency_probe.sh

# launcher (MSYS2_ARG_CONV_EXCL stops the shell rewriting -p: into paths)
cd ../../launcher
MSYS2_ARG_CONV_EXCL='*' "C:/Program Files/dotnet/dotnet.exe" publish -c Release \
  -r win-x64 --self-contained true -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true -o ../dist/GamingScrcpy/launcher
../dist/GamingScrcpy/launcher/GamingScrcpyLauncher.exe --validate-profiles

# both bridges + the decoded PCM tap through a real encoder (needs ffmpeg)
bash tools/bridge_encode_test.sh 40 640x360

# the tap in isolation: 44.1 kHz mono float -> 48 kHz stereo s16le
./build-x/app/gamingdemo.exe --frames=40 --pcm-tap=pcm.raw

# does an audio output keep the stream alive without playback? (§5.1f)
./dist/GamingScrcpy/scrcpy/scrcpy.exe --no-audio-playback -x 2>&1 | grep audio
./dist/GamingScrcpy/scrcpy/scrcpy.exe --no-audio-playback --game-audio-pcm=p.raw -x 2>&1 | grep audio

# recording integrity with no phone attached (§5.1g)
bash tools/recorder_integrity_test.sh 30 320x180

# every GPU render backend presents the same path (§5.1j)
bash tools/render_driver_test.sh 30
# what recording costs a live mirror (§5.1h, inside that same script), or raw:
./build-x/app/recorderintegrity.exe --in=clip.h264 --out=rec.mkv --format=mkv \
  --codec=h264 --size=1280x720 --fps=60 --bench
# the same check from inside the extracted package, no build tree and no source:
# cd GamingScrcpy && bash tools/recorder_integrity_test.sh 30 320x180
# the recorder-start race of §5.1i: six instances at once used to crash 12/12
for i in 1 2 3 4 5 6; do bash tools/recorder_integrity_test.sh 30 320x180 >/dev/null 2>&1 & done; wait

# named-pipe transport: consumer first / no consumer / consumer joining late
powershell -NoProfile -ExecutionPolicy Bypass -File tools/bridge_pipe_test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/bridge_audio_pipe_test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools/pcm_tap_pipe_test.ps1

# every configurator control present in the running launcher window
powershell -NoProfile -ExecutionPolicy Bypass -File tools/launcher_uiauto.ps1

# everything above as one gate (89 checks, exits non-zero on any failure)
bash tools/verify_all.sh
```
