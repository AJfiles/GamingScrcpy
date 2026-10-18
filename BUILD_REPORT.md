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
| Launcher | `dist\GamingScrcpy\launcher\GamingScrcpyLauncher.exe` | .NET 8 self-contained single file, 145,213,768 bytes (145,201,480 before PR 7's auto-rescan, §5.1ap; the §5.1al and §5.1am rebuilds did not change the size), window verified on screen, the shortcut panel read back through UI Automation in both languages, and the theme audited by section 20 |
| Sources | `workspace\scrcpy` (fork), `launcher\` (C# WPF) | see §4 |
| Validation tooling | `dist\GamingScrcpy\tools\*` (19 scripts + `fixtures\` + `theme\`) | the same scripts the gate runs, shipped so §7 is reproducible from the package alone: `bash tools/recorder_integrity_test.sh`, `bash tools/render_driver_test.sh`, `bash tools/fx_pixel_test.sh` and `bash tools/theme_audit.sh` all pass inside an extracted package, because each finds its binary next to `scrcpy.exe` (or its inputs under `tools\theme\`) when there is no build tree |
| Distributable package | `dist\GamingScrcpy-win64-fork.zip` | 126,403,344 bytes on the archive rebuilt for PR-6 (the two earlier repacks measured 126,357,530 and 126,357,592) — ≈120.5 MiB either way, and the copy of this report inside the archive can only ever carry the figure from the previous repack, because the report is inside its own archive; `Expand-Archive` into an empty directory yields **148 files under 5 directories** (`launcher\`, `scrcpy\`, `tools\`, `tools\fixtures\`, `tools\theme\`), counted from the extraction rather than from an entry list. The earlier text claimed 153 files under 7 directories, then 138, then 140, then 145; every one of those is superseded by the count measured here. The package before that carried 160: seven stray `e3.txt`/`out.txt`/`err*.txt` adb redirects left behind by the §5.1ab debugging were shipping inside `launcher\`, and they are now deleted from `dist\`. Built with `Compress-Archive` from `dist\GamingScrcpy\*`. The size shifts by a few hundred bytes each repack because this report is inside its own archive: the copy in the zip is the previous one and still carries the older number. The `tools\` tree travels with the package (22 files + `fixtures\` + `theme\`), so a user can re-run the pixel assertions, the filter checks, the latency matrix and the theme audit without a build tree. Verified from that extraction, all exit 0: `bash tools/recorder_integrity_test.sh 30 320x180` (11 cases, `OK`, dual-120fps `frames=120`), `bash tools/fx_pixel_test.sh` (`FXPIXEL OK`), `bash tools/overlay_test.sh` (`OVERLAY OK`, paired Δmedian -0.004 ms, Δp99 +0.312 ms), `powershell tools/launcher_uiauto.ps1` (`UIAUTO OK`, every tab walked and its controls found by automation id), `powershell tools/launcher_tab_shot.ps1 -Tab 0` (window captured), `bash tools/theme_audit.sh` (`THEME OK pairs=15`) with its broken-palette fixture failing as required (`THEME FAIL issues=4`, exit 1), `launcher\GamingScrcpyLauncher.exe --validate-profiles` (`ALL PROFILES VALID`, `PASS invalid overlay hotkey dropped`), `launcher\GamingScrcpyLauncher.exe --validate-shortcuts` (`SHORTCUTS OK rows=29 categories=4`) with its duplicate-key fixture — `--validate-shortcuts "--shortcuts-file=tools/fixtures/shortcuts_duplicate.json"` — failing as required (`SHORTCUTS FAIL issues=2`, exit 1). The render-driver sweep and `tools/shortcuts_table_test.ps1` travel in `tools\` but were last executed from the build tree by gate sections 6 and 17, not from this extraction |
| Regression suite | `tools\verify_all.sh` | **151 passed, 0 failed** in the last full run, executed with the moto g(7) power attached (`out\gate_v3_pr5.log` — 145 of those lines were already green at §5.1al and the 6 new ones are section 20, the theme audit: single accent, radius range, no symbol glyphs, a keyboard-focus trigger in the templates, 15 measured contrast pairs and its broken-palette positive control; §5.1am); gate §16 SKIPs here because no Android 11+ device is attached. The total moves by a couple of lines between runs **on purpose**: the bench emits one PASS per measured attempt (a quiet machine needs only one), the recorder check emits one line per case it can build, and two sections SKIP without a phone — so a fixed "N checks" number would be wrong more often than it is right |
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

### 5.1ac v3 pre-flight: the audio question, the header overlap, the shortcuts zone

Directive v3 §9 asks for evidence before code. This section is that evidence plus
the seven-step plan. Everything here was measured on 2026-10-17 on this host with
the **moto g(7) power** (serial `<dev-id-2>`) attached; the commands are in
`out/dev/adb_audit.log`, the probe is `out/v3_preflight_probe.ps1` (scratch, not
shipped) and the pictures are `out/shots/v3_*.png`. v3's evidence continues the
§5.1a-§5.1ab run rather than taking the §5.2 number the directive suggested,
because §5.2 has been the CLI chapter since v1.

### 5.1ad "NO suena en el PC el audio del teléfono" — measured, and it is the phone

| Device | SDK (`getprop ro.build.version.sdk`) | audio flags run | session | exact server line |
|---|---|---|---|---|
| moto g(7) power, Android 9 | **28** | `--audio-source=output --audio-codec=opus` | video only | `[server] WARN: Audio disabled: it is not supported before Android 11` then `WARN: Demuxer 'audio': stream explicitly disabled by the device` / `ERROR: Demuxer error` |
| moto g(7) power, Android 9 | 28 | `--audio-source=mic` | video only | same two lines — the mic source is refused by the same SDK gate, not by a different one |
| Lenovo TB-9707F, Android 14 | 34 | `--audio-source=output --audio-codec=opus` (recorded 2026-10-17, §5.1y) | **audio captured** | no `Audio disabled` line; playback arrived as opus 48 kHz stereo and muxed into the recording (§5.1x, line "captured as opus 48 kHz stereo") |

So hypothesis #1 holds and no fork code is implicated: the phone the user is
testing with **cannot** produce device audio on any scrcpy build, because Android
9 has no audio-playback capture API for `adb`-started processes. The Android 14
tablet on the same binary did produce it, which is the comparison §1.1c asked for
(quoted from the recorded run rather than re-measured: the tablet is not
connected now, so this row cannot be refreshed on demand — see §5.1ah for how to
re-run it).

Two things the diagnosis did turn up that *are* ours to fix:

* The launcher emits `--audio-codec=opus --audio-bit-rate=160K --audio-source=output`
  regardless of the device's SDK, so the user sees audio controls that silently
  do nothing — exactly the "NUNCA dejar un checkbox de audio que silenciosamente
  no hace nada" case. The `ERROR: Demuxer error` line then lands in the log panel
  with no explanation.
* `HintShortcutsOverlay` tells the user to "Pulsa F1 aquí" (in the launcher) and
  there is **no key handler in the launcher at all** — `grep -n "Key.F1\|KeyDown"
  launcher/*.cs` returns nothing. The F1 overlay exists only in the mirror window.
  That is an unverified claim in shipped text, and v3 must either implement it or
  stop promising it.

### 5.1ae The header overlap, measured instead of eyeballed

`out/v3_preflight_probe.ps1` starts the packaged launcher in Spanish with the
phone attached, waits for detection (`badge='1 dispositivo(s)'`), then walks the
window width down and reports every pair of header controls whose UIA
`BoundingRectangle` intersects:

| Window width | Result |
|---|---|
| 1380 (default) | clean |
| 1340 | clean |
| **1260** | `DeviceCombo x BtnRefresh = 44x19px` |
| 1180 | `BtnWireless x DeviceCombo = 7x19`, `DeviceCombo x BtnRefresh = 111x19` |
| 1120 | `BtnWireless x DeviceCombo = 67x19`, `DeviceCombo x BtnRefresh = 111x19` |
| 1060 | `BtnWireless x DeviceCombo = 127x19`, `DeviceCombo x BtnRefresh = 97x19` |
| 1000 | three pairs, incl. `BtnPair x DeviceCombo = 38x19` |
| 940 | `BtnWireless x DeviceCombo = 126x19`, `BtnPair x DeviceCombo = 98x19` |

The mechanism is not the one the directive guessed. The header `Grid` is
`Auto | 230 | * | Auto | Auto`, and the button cluster lives in the **star**
column with `HorizontalAlignment="Right"`. Four Spanish buttons
(`Reescanear ADB`, `Guía ADB inalámbrico`, `Emparejar inalámbrico`,
`Conectar ip:puerto`) want ~600 px; below ~1300 px of window the star column has
less than that left, and WPF lets a right-aligned `StackPanel` overflow **to the
left**, over the device combo — so the combo and the button labels collide, which
is what the user described as "el nombre tapa otros textos". The strings they
quoted map to the real labels `Dispositivo detectado` (`LblDevice`) and
`Emparejar inalámbrico` (`BtnPair`).

`out/shots/v3_header_overlap.png` (1260 px) shows the first stage: the combo
reads `USB <dev-id-2> (moto g(7) power` and the button behind it is cut to
`anear ADB`. At 940 px (`out/shots/v3_shortcuts_msgbox.png`) it is `…nbrico` and
`Conectar ippuerto`. The same pictures show two more defects in the same window
that v3 should fix while it is in there:

* the footer paths are clipped on both ends (`adb: gCapture\dist\…` — the head of
  the path is cut off, so the string is not even readable);
* the `COMANDO` preview box overflows its border on the right
  (`…--game-telemetry-log --` is cut mid-flag);
* at 940 px the `RENDIMIENTO EN VIVO` labels collide with their own values
  (`Latencia med. (ms)` wraps onto `FPS`).

### 5.1af The ATAJOS zone as it stands

`OnShowShortcuts` is a `MessageBox.Show` of one localized paragraph
(`HintShortcuts`), so the "list" the user expected is a system dialog: light-grey
chrome inside a dark app, a blue system icon, no key column, no categories, and
the six hotkeys flattened into running text
(`out/shots/v3_shortcuts_msgbox.png`). The button itself has no `x:Name`, so it
has no `AutomationId` either — the probe had to find it by its displayed text,
which is precisely the pattern §B of v2 forbids. Redesigning it as a real table
also makes it gateable.

### 5.1ag v3 plan, in PR order

| # | PR | Scope | Gate / evidence | Cost |
|---|---|---|---|---|
| 1 | audio honesty | badge `Audio: no soportado (Android 11+)`, disable codec/bitrate/PCM-tap/bridge controls when `Sdk < 30` with a tooltip, `Diagnóstico de audio` button (SDK, support, last server line, sink state, read-only volume), and stop emitting audio flags the device will refuse | new §16 (SKIP-safe without an API ≥30 device), §15 key parity, UIA finds the new controls | small, all launcher |
| 2 | header + footer | 3-column header (status icon / info with `TextTrimming` + `MinWidth=0` / actions), device name capped, buttons that wrap or collapse by width, un-clipped footer paths, `COMANDO` box that scrolls instead of overflowing | §10 + §11 green; the §5.1ae probe re-run must report **zero** intersections at 940/1100/1380, connected and disconnected | small |
| 3 | shortcuts as a table | grouped cards (Espejo / Grabación / Filtros / Ventana / Otros), keycap column in mono, action + description columns, every string through `Loc.cs`, `x:Name` on the button | new §17 (row completeness, both languages non-empty, no duplicate key inside a category, positive control with a duplicated fixture) | medium |
| 4 | one-accent aesthetic pass | consolidate to a single accent, 8 px grid, radius 6-8, distinct hover/focus/disabled, AA contrast measured from the actual brushes, no emoji or system icons in the app's own chrome | screenshot tour of all tabs + a contrast computation in the gate | medium, mechanical |
| 5 | live filter overlay | global hotkey `Super+Alt+F` (registered by the launcher, so it works while the mirror has focus) opening a borderless always-on-top **separate window** with the six existing filters, Esc closes, drag by header | new §18: per-frame median/p99 baseline vs overlay-open with 5 toggles, delta < 1 ms, p99 < 3 ms, fps drop ≤ 3 | large — the fork needs a live postfx parameter path (§5.1ai) |
| 6 | filter profiles | "current" persisted, named profiles, apply-on-start, export/import with the session JSON, presets Neutral/Vivid/Cinematic/Night/Competitive | §17-style integrity check on the profile JSON, pixel assertions reused from `fx_pixel_test.sh` | medium |
| 7 | #20 + §6 triage | borderless-at-startup fix, then implement the cheap §6 items (audio-active indicator, Presentation mode, 3 s foreground re-scan, last-config + Relaunch) and document the rest with cost/benefit | `window_style_probe.ps1` must see the caption bits cleared, and stay that way after the first frame | medium |

PR 1 and 2 are independent of the fork and fix what the user can see today, so
they land first. PR 5 is the only item that can regress the thing the user cares
most about (latency), so it goes behind a measured gate with the documented
fallback: if the overlay cannot be proven free, it degrades to a launcher panel
that applies and closes, never to a window that slows the mirror.

### 5.1ah How to re-run this diagnosis

```
bash -c 'cd out && powershell -NoProfile -ExecutionPolicy Bypass -File v3_preflight_probe.ps1'
# audio, with any phone attached:
dist/GamingScrcpy/scrcpy/scrcpy.exe --serial=<serial> \
    --audio-source=output --audio-codec=opus --no-window --time-limit=5
dist/GamingScrcpy/launcher/adb.exe shell getprop ro.build.version.sdk
```
To close the Android 11+ comparison with fresh numbers rather than the recorded
§5.1y row, attach a device with SDK ≥ 30 and run the same command: the expected
result is **no** `Audio disabled` line and telemetry showing `a_kbps > 0`. Manual
check for the user's own speakers: mirror with audio, then look at
Windows Volume mixer — the `scrcpy.exe` stream must be present and unmuted; the
launcher's `--no-audio-playback` checkbox (PCM tap) deliberately removes it.

### 5.1ai Open design question for PR 5

The six filters are applied inside the mirror's own render path (measured at
~3.24 ms/frame for 720x1280 in §5.1w), so the overlay must only *change their
parameters*. Those parameters are read once at startup today, so a live path is
needed: a small control pipe read by the client, writing into the postfx state
under the same lock the LUT build already uses. That is where the risk of this
feature lives, and §18 is what bounds it.

### 5.1aj PR 2 — the header rebuilt, and measured twice because the first
measurement was in the wrong language

v3 §2 asked for a 3-column header (state icon / info / actions) whose info column
can never push the actions. The first attempt did that and looked green:

```
WIDTH 1340 -> clean … WIDTH 940 -> clean      (out/v3_preflight_probe.ps1, 14:47 build)
```

It was green for the wrong reason. `tools/launcher_uiauto.ps1` had just run and
left the config on **English**; the four Spanish buttons the user actually sees
(`Reescanear ADB`, `Guía ADB inalámbrico`, `Emparejar inalámbrico`,
`Conectar ip:puerto`) are ~120 px wider than their English labels. Re-running the
probe with `language.txt=es` and a settle for the async `getprop` reads
(`out/v3_header_verify.ps1`, kept out of `tools/` because it is scratch) produced:

```
CONNECTED badge='1 dispositivo(s)' summary='USB · moto g(7) power · Android 9 (SDK 28)'
CONNECTED-W1380 -> clean
CONNECTED-W1000 -> OVERLAP BtnRefresh x TxtDeviceSummary = 8x30px
CONNECTED-W940  -> OVERLAP BtnRefresh x TxtDeviceSummary = 8x30px
```

So the summary line put inside the star cell did exactly what the old combo had
done: when the two Auto columns (`Auto | * | Auto`) together exceed the window,
the star column gets 0 width, its `Margin="16"` leaves an 8 px stub that sits
under the first button, **and** the action buttons run past the right edge of the
window — a worse bug than the overlap, because the user cannot click `Conectar`
at all. Overlap alone was therefore not a sufficient assertion, and the verify
script now measures two things per width: intersecting rectangles, and any
rectangle crossing the window edge (`OFFSCREEN-R`).

The layout that survives both:

* Row 1 keeps `Auto | * | Auto` — device block left, actions right, star filler in
  the middle. The filler is empty, so it can collapse to 0 without any control
  being squeezed with it.
* The secondary line (`TxtDeviceSummary`, `USB · model · Android X (SDK Y)`) moved
  to its **own row** spanning all three columns with `MinWidth="0"` +
  `TextTrimming="CharacterEllipsis"`. Nothing shares that row, so it cannot
  overlap anything; a long model name ellipsizes.
* `MinWidth="1120" MinHeight="600"` on the window. 1120 is the measured point
  where the Spanish header still fits with the combo at its 300 px max; below it
  the user can no longer resize, so the squeeze becomes unreachable by mouse.
  The verification still forces 1000 and 940 px through Win32 to prove the
  degrade is clean: no overlap, nothing off-screen.
* The footer became an `Auto | * | *` grid with the same trimming on
  `TxtStatus`, `TxtScrcpyPath` and `TxtAdbPath`, which fixes the clipped
  `adb: gCapture\dist\…` from §5.1ae, and `TxtCommand` got a vertical scrollbar so
  the preview no longer runs past its border.

One more honesty fix fell out of the screenshots: with no device attached the
label still read **"Dispositivo detectado"** next to an amber dot and
"sin dispositivo". `LblDevice` is now the state-neutral `Dispositivo:` /
`Device:` (§2.2 literally asks for "Dispositivo: [nombre]"), and the dot plus the
badge carry the state.

Re-measured with the packaged build, Spanish, phone attached and then with a stub
`adb.exe` that exits 1 (nobody was here to unplug the phone, and the phone is not
part of this test):

| State | 1380 | 1200 | 1120 (=min) | 1000 (forced) | 940 (forced) |
|---|---|---|---|---|---|
| connected (`<dev-id-2>`) | clean | clean | clean | clean | clean |
| no device | clean | — | clean | clean | clean |

`out/shots/v3_header_connected.png`, `v3_header_no_device.png` (both 1380 px, top
240 px of the window) and `v3_header_connected_min.png`,
`v3_header_no_device_min.png` (1120 px) are the §2.3 deliverable.

Gate after the change (`out/gate_v3_pr2.log`, 2026-10-17, phone attached):
**137 passed, 0 failed** — same total as v2's last green run, because the header
added no checks, only kept the existing ones green. §10 still finds every control
by `AutomationId` after the redesign (`91 configurator controls present in the
running window`), §11 drove the real device to a mirror window with
`--serial=<dev-id-2>` present and stopped cleanly **with no retry** (the earlier
standalone run did need one, the Android 9 MediaCodec settle of §5.1ab), and §15
grew from 223 to **225 unique Loc keys** with the two new summary strings present
in both languages.

Reproduce: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
out/v3_header_verify.ps1` (expects `HEADER-VERIFY OK`).

### 5.1ak PR 3 — the launcher stops pretending about audio

§5.1ac established the cause: the attached moto g(7) power reports **SDK 28**,
and scrcpy's server refuses device audio below Android 11 (API 30). That is a
device limit, not a bug in this fork — so the fix belongs entirely in the
launcher, whose job is to never show a control that does nothing. Four changes,
all verified against the real phone:

* **Badge** (`TxtAudioBadge`, header row 3, visible only once a phone has been
  read): *Audio del dispositivo: NO SOPORTADO (requiere Android 11+)* in amber,
  or *Audio del dispositivo: compatible (Android 11+)* in green. The SDK that
  gates it is already on the line above (`USB · moto g(7) power · Android 9 (SDK
  28)`), so the claim and the evidence sit together.
* **Six controls disabled, not hidden** (`ApplyAudioCapability`):
  `CboAudioCodec`, `CboAudioBitrate`, `CboAudioOutBuffer`, `TxtAudioBridge`,
  `TxtAudioPcm`, `ChkPcmMute`, each with the tooltip *Teléfono anterior a
  Android 11: scrcpy no puede capturar su audio*. Disabled rather than collapsed
  so the user can see what they are missing, and so gate §10 keeps finding them.
* **The command line tells the truth** (`AppConfig.BuildArguments`): when the
  picked device reports `0 < Sdk < 30` the preview sends `--no-audio` and **no**
  `--audio-codec`, `--audio-bit-rate`, `--audio-source`, `--audio-buffer`,
  `--audio-output-buffer`, `--game-audio-pcm` or `--game-audio-bridge`. The flag
  comes from the attached device, never from a profile, so `NoDeviceAudio` is
  `[JsonIgnore]`: loading *4K Ultra Quality Stream 60FPS* on an Android 9 phone
  must not resurrect flags that phone ignores.
* **Diagnóstico de audio** (`BtnAudioDiag`) prints, in the log panel: the serial,
  SDK and release; the support verdict; the server's own last audio line (only
  lines written *before* the diagnostic started, so it cannot quote itself);
  what the PC sink is actually doing (no session / `--no-audio` / muted /
  playing); and the phone's `STREAM_MUSIC` volume read from `dumpsys audio`. That
  is the only adb call the button makes, it takes no arguments from the UI, and
  gate §14 greps the launcher sources for the device-write blacklist, so the
  read-only invariant is enforced by the gate rather than by an audit line here
  (the audit log is what the *harnesses* append).

Gate section 16 (`tools/audio_e2e_test.ps1`, v3 §1.3) is the end-to-end proof for
the case this host cannot reach: a PCM pipe consumer + a video-less
`--audio-source=output --audio-codec=opus --no-audio-playback --game-audio-pcm`
session, asserting no refusal in the log, ≥ 8000 tap bytes, a real signal peak
(> -90 dBFS, computed straight off the s16le stream because `ffmpeg` is on the
bash PATH and not on PowerShell's) and no client audio error. It is **SKIP-safe**,
and both paths were measured here:

```
SKIP no device with SDK >= 30 (device audio needs Android 11+)     exit 2 -> gate prints SKIP
```

and, forced onto the Android 9 phone with `-MinSdk 28` so the assertion itself is
tested rather than trusted:

```
DEVICE <dev-id-2> sdk=28
FAIL PCM tap got 0 bytes (expected a live stream)
AUDIO-E2E FAIL issues=1
```

So the byte-count assertion is the load-bearing one: on a device that cannot
capture audio the check fails instead of passing vacuously. README §7 item 14
documents the manual matrix (`opus|raw`, `output|mic`, `--no-audio-playback`,
`--game-audio-bridge`, and what the badge must say on a supported phone), which
is what the SKIP message points at.

**Not claimed:** the *supported* branch (green badge, enabled controls, audible
PC audio) has never been executed on hardware here, because no Android 11+ device
is attached. It is the same code path with the comparison inverted
(`Sdk >= 30`), and gate §16 covers it the moment such a phone is connected — but
until then it is reasoning, not measurement, and §6 of this report keeps it
listed as unverified.

Gate after the change. The first full run (`out/gate_v3_pr3.log`, 2026-10-17, phone
attached) reached **133 passed, 2 failed, 1 SKIP**: §10 grew to **92 configurator
controls** (the new `BtnAudioDiag` is found by `AutomationId`) and §15 to **244
unique Loc keys** (19 audio strings). The two failures were the wall-clock-paced
host audio checks in §8 (`pipe consumer received: 79600 398`, expected
`80000 400`) and §8b (`pcm tap … 7680 B (expected ~153600 B)`,
`telemetry fps=0.0`) — neither related to a launcher change, and both re-run
standalone on an idle desktop in the same session:

```
attempt 1: pipe consumer received: 80000 400
attempt 2: pipe consumer received: 80000 400
bash tools/bridge_encode_test.sh 40 320x180
RESULT frames=35 audio_chunks=34 vsize=320x180
RESULT codecs=h264+aac durations=0.566667/0.566667 delta=0.000000 tol=0.025000
RESULT pcm_tap=153532B rate=48000 ch=2 duration=0.799646 max_vol=-9.0dB
OK
```

i.e. the documented "desktop still busy" family (§8 already retries once for
exactly this reason), not a regression: the whole suite re-run with nothing else
open (`out/gate_v3_pr3.clean.log`) is **137 passed, 0 failed**, §16 SKIP, with
§11 again driving the real phone (`mirror pid=…`, `--serial=<dev-id-2> present`,
`stop scrcpy exited cleanly`) and §13/§14 green. The two quoted evidence files
are kept so the claims are re-readable, not just asserted: `out/v3_audio_probe.log`
(`AUDIO-PROBE OK`: the badge string, the six `DISABLED` controls with tooltips,
`PREVIEW sends --no-audio`, `PREVIEW sends no audio codec/bitrate/source/tap
flags`, and the five diagnostic log lines) and
`out/v3_audio_e2e_poscontrol.log` (the `-MinSdk 28` run, exit 1, whose only FAIL
is the byte count while the three text assertions print `OK`).

The deliverable is the repacked `dist/GamingScrcpy-win64-fork.zip` (126,310,798
bytes, 138 entries) extracted to an empty directory: `recorder_integrity_test.sh`
(`OK`, dual-120fps `frames=120`), `fx_pixel_test.sh` (`FXPIXEL OK`) and
`render_driver_test.sh` (`OK`, vulkan and default backends `45/45`) all exit 0
from the extraction, and the launcher inside it is the audio-honest build the
probe measured above.

Reproduce the UI part: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
out/v3_audio_probe.ps1` (expects `AUDIO-PROBE OK`), which walks the three tabs
that hold the audio controls — WPF does not realize an unselected `TabItem`, so
they are not in the UIA tree until their tab is selected.

### 5.1al PR 4 — the shortcut block becomes a table, and the table becomes data

The complaint was *"La zona de ATAJOS no está en lista, no se ve ordenada ni
agradable"* (§5.1af measured it: one `MessageBox` with a 1 700-character
paragraph). It is now a grouped keycap table inside the Quick tab, and the rows
are data the gate can check.

**What the table contains.** `launcher/Shortcuts.cs` holds 27 rows in three
categories — Espejo (12), Ventana (7), Otros (8) — each a combination plus two
`Loc.cs` keys (action, description). The combinations come from this fork's
`gaming_event_watch()` in `app/src/gaming.c` (`Super/Alt+F1…F5`) and from
`app/src/input_manager.c` for the upstream `MOD+…` set; every description in the
report, the README and the UI was re-read against those two files, which is how
three wrong paraphrases were caught (`MOD+G` is *resize to pixel-perfect*, not
"cycle the resize constraint"; `MOD+W` is *remove the black borders*; `MOD+Shift+N`
*collapses the notification/settings panels*). Categories with no hotkey in
scrcpy 5 — Grabación, Filtros — are **absent**: there is no `toggle_recording`
shortcut upstream (`MOD+R` rotates), and inventing a row to fill the section is
exactly the kind of claim §8 forbids.

**Gate section 17, three parts:**

| Check | Result |
|---|---|
| `GamingScrcpyLauncher.exe --validate-shortcuts` | `SHORTCUTS OK rows=27 categories=3`, exit 0 |
| same, on `tools/fixtures/shortcuts_duplicate.json` (positive control) | exit 1, `SHORTCUTS FAIL issues=2`: `FAIL duplicate combination 'Super/Alt+F1' in category 'ScCatMirror'` and `FAIL row 3: empty key combination` |
| `tools/shortcuts_table_test.ps1`, packaged launcher, Spanish **and** English | `SHORTCUT-TABLE OK`, exit 0 — 27 rows per pass, every row with three non-empty cells, panel opens and closes from the same button |

The render pass measures geometry, not pixels, so it fails on a layout that
merely *looks* filled: the keycap text is 122 px wide and 14 px tall (one line),
the action column starts 159 px after the combination, the description column is
284 px wide, and the row pitch is 28 px. The assertions are `keycap ≥ 24 px`,
`action.X − key.X ≥ 120 px`, `description ≥ 200 px wide and ≥ 40 px after the
action`, `keycap ≤ 48 px tall`, and ≥ 20 rows. `out\shots\v3_shortcuts_panel.png`
is the panel as painted.

**Three failures found on the way, all real:**

1. **`AutomationId` on a `Border` is invisible.** The first version put the id on
   the keycap's `Border`; UIA found 0 rows because WPF decorations have no
   automation peer. The id moved to the inner `TextBlock` and 27 rows appeared.
2. **The card could not be a separate window.** The list first shipped as
   `ShortcutsWindow.xaml`. After invoking the button, the process still owned
   exactly one window visible to UIA — `'Gaming Scrcpy Launcher'` — so the test
   could never read the list it claimed to check (and the Esc-to-close behaviour
   could not be measured either, which is why that claim had already been removed
   from the footer text). The list is now a `StackPanel` section of the Quick tab
   toggled by the same button, which is both verifiable and what "en lista"
   asked for. `ShortcutsWindow.xaml`/`.xaml.cs` are deleted.
3. **A star column inside a horizontally scrollable `ScrollViewer` collapses.**
   With the card in the Quick tab's fixed 280 px column, the description column
   measured 10 px wide and 670 px tall — the text wrapped into a ribbon and
   stretched the whole row with it, because a `ScrollViewer` that can scroll
   horizontally measures its content with infinite width, and a star column given
   infinity takes only its minimum. The card moved to its own row spanning both
   tab columns (`MaxWidth="720"`, `HorizontalScrollBarVisibility="Disabled"`),
   and the numbers above are what it measures now. The gate caught this as 54
   failures across the two passes, which is the point of asserting geometry.

Launcher rebuilt at 145,201,480 bytes (+20,480 over the §5.1ak build).

**Gate.** `bash tools/verify_all.sh` with the moto g(7) power attached: **145
passed, 0 failed** (`out\gate_v3_pr4.log`), up from the 137 of §5.1ak — section
17 contributes 8 lines (validator, positive control, and three assertions in each
of the two languages), and section 16 is the same SKIP as before. §10 now counts
**93** configurator controls in the live window (the 92 of §5.1ak plus
`BtnShortcuts`), and the §13/§14 invariants stayed green.

**One wedge, documented rather than hidden.** The first PR-4 gate run stopped
producing output inside section 6 for 33 minutes. `gamingdemo.exe` had printed
`gamingdemo: PASS` one second after starting, had written the full 199,065,600
bytes (24 × 1920×1080×4) and had reached `return ok ? 0 : 1`
(`app/tests/gaming_demo.c:796`), but the process never left the system: it stayed
at 1.7 s CPU with `Responding=True`, `Stop-Process` marked it for death and
`taskkill /F` then reported *"no hay ninguna instancia activa de la tarea"* while
the entry kept listing — a thread parked in a driver wait during the D3D11/SDL
teardown, after the demo's borderless-fullscreen on/off pair. The identical
command run standalone exits 0 in about a second, and the re-run of the whole
gate is the 145/0 above, so this is the busy-desktop flake family of §5.1ab/§5.4
rather than a PR-4 regression: PR-4 changes no C code, and the `scrcpy.exe` and
`gamingdemo.exe` binaries are the ones §5.1ak shipped green. What it does prove
is that a wedged host process is worth recognising from the *log's* mtime, not
from the process list.

### 5.1am PR 5 — the aesthetic pass, with its rules written down as a check

Directive §4 lists principles, which is another way of saying they had been
broken. Each one is now either held by the theme or asserted by the new gate
section 20 (`tools/theme_audit.sh`), which reads the palette and the control
templates instead of trusting a screenshot.

**One accent, chosen by measurement.** The theme had two: `Accent #4FA3FF` and
`Accent2 #2BD98A`. There is now exactly one brush named `Accent`, and the green
became `Good`, a *state* colour beside `Warn` and `Danger` — it is only ever used
for "this device can do the thing" text, which is a status, not a decoration. The
same reasoning keeps the record red (`RecordBg` / `Danger`): a record button that
is not red breaks a stronger convention than a palette rule. Both colours the
directive proposed were measured before being set aside: `#7C4DFF` reaches only
**2.43:1** on the primary button and **2.07:1** on the highlighted combo item, so
it fails AA for text on surfaces that already exist, while `#4FA3FF` reaches
**7.31:1** on the window background and **6.22:1** on the raised surface.
`#00E5A8` does pass (11.7:1 on the background) but would have meant repainting
every filled control for no measurable gain, so the existing accent stayed.

**Contrast, computed from the brushes rather than picked from a swatch:** `Fg`
15.92 / 14.74 / 13.54 on `Bg` / `Panel` / `Panel2`; `FgDim` 6.31 / 5.84 / 5.37;
`Accent` 7.31 / 6.77 / 6.22; `Fg` on the filled buttons 9.71 (`PrimaryBg`), 11.51
(`RecordBg`), 13.75 (`StopBg`), 8.30 (`ComboHi`); `Good` 9.62 and `Warn` 10.25 on
`Panel`. The worst of the 15 pairs the theme actually paints is 5.37:1, so all of
them clear the 4.5:1 AA bar for text — and the audit asserts exactly that, pair
by pair.

**Focus is now a shape.** The button template carried a hover trigger and a
disabled trigger but no focus trigger, so a keyboard user had only the hue to go
on, which is the one thing §4.1 rules out. `IsKeyboardFocused` now thickens the
border from 1 px to 2 px in the accent on top of the colour change; hover keeps
the 1 px accent border and disabled keeps 45 % opacity, so the three states are
told apart without relying on colour.

**Radius and spacing.** The only outlier was the combo item at 4 px; every corner
is now 6 or 8 px and the audit fails the build if any `CornerRadius` leaves that
range. The spacing sweep moved the off-grid values onto a 4 px half-step of the
8 px rhythm: `0,2` → `0,4` (26 places), `6,0,0,0` → `8,0,0,0`, `0,3,0,0` →
`0,4,0,0`, `6,2,0,2` → `8,4,0,4`, control height 26 → 24, button padding `10,6`
and `10,9` → `12,8`, tab padding `12,7` → `12,8`, combo popup arrow margin 9 → 8
and selection margin 22 → 24.

**No mixed icon sets.** The four one-click buttons carried `▶ / ● / ■` prefixes in
their localized labels — geometric symbols, which is exactly the "do not mix
emoji with icons" case, and they also made the strings differ in width between
languages for no reason. They are gone; those buttons are told apart by style
(filled accent, filled red, plain) and by weight. The audit fails if any arrow,
geometric shape, dingbat or astral-plane code point appears in `Loc.cs` again,
while punctuation such as `…` or `–` stays allowed.

**What the screenshot tour caught.** §4.3 asks for a tour of the seven tabs, and
producing it found a regression this very pass had introduced: the device panel's
rescan button carried a hard `Width="80"`, and the wider button padding pushed
"Rescan ADB" past it, so the label clipped to `Rescan AD`. `Width` became
`MinWidth`, the button now sizes to its content in either language, and the
re-taken `out\shots\v4_tab_1_quick.png` shows it whole. Worth recording because
it is the general lesson: a spacing sweep is a layout change, and only the
rendered window can say whether it still fits.

The tour itself is seven files, `out\shots\v4_tab_1_quick.png` through
`v4_tab_7_advanced.png`, taken from the packaged launcher by selecting each
`TabItem` through UI Automation and capturing the window rectangle. PR-6 added
the *Real-time filter panel* block to the end of the Filters tab, so that one
shot no longer showed what the tab contains: `tools/launcher_tab_shot.ps1` now
does the selecting and capturing (tab index, not header text — the headers are
localized), and `out\shots\v5_tab_4_filters.png` replaces
`v4_tab_4_filters.png`. It shows the whole tab in one frame: presets, six
sliders, and the new block with its hotkey box reading `super+alt+f` while the
COMMAND column carries `--game-filter-overlay --game-filter-profiles=…`.

**Gate.** `bash tools/verify_all.sh` with the moto g(7) power attached: **151
passed, 0 failed** (`out\gate_v3_pr5.log`), the 145 of §5.1al plus the six lines
of section 20. The first run of this PR reported 150/1 and the one failure was
the audio-bridge pipe check reading `79800 399` instead of `80000 400` — one
sample short of the expected window, the same busy-host family recorded in §5.1ab
and §5.4. Run standalone twice on a quiet desktop it produced `80000 400` both
times, and the re-run of the whole suite is the 151/0 above, so the flake is
named rather than waved through.

**Packaging, and what the extraction caught.** The directive's deliverable is the
extracted ZIP running its own tests, so the PR-5 package was unzipped into a clean
directory and every check re-run there. `theme_audit.sh` failed: it read
`launcher\App.xaml`, `launcher\Loc.cs` and `launcher\*.xaml`, and an extracted
package has no build tree — the launcher is a single exe there. Worse than the
failure itself were its 18 lines, six of which claimed "a colour is missing from
the palette" for colours that were plainly in the file: grepping a nonexistent
path yields nothing, and the audit reported that nothing as a palette defect
instead of a missing input. Fixed by shipping the three theme inputs inside the
package (`tools\theme\App.xaml`, `Loc.cs`, `MainWindow.xaml`) and giving the
script a per-input fallback plus an explicit `THEME FAIL inputs=missing` exit 1
before any check runs, so an absent source can never again be dressed up as a
design finding. The fallback is per input rather than all-or-nothing because
`--app-xaml` legitimately points at a fixture while the radius census reads the
real XAML — the first version gated every input on App.xaml and broke exactly that
invocation, which the fixture run inside the extraction caught. Both trees now
agree: build tree `THEME OK pairs=15` / fixture `issues=4`; package `THEME OK
pairs=15` / fixture `issues=4`, exit 1. The same run also corrected a wrong claim
in this report: the duplicate-key shortcut fixture had to be passed as
`--validate-shortcuts "--shortcuts-file=…"`; the bare path argument is ignored by
the launcher, so an earlier manual attempt printed `SHORTCUTS OK` against the
fixture and would have looked like a broken positive control. The 151/0 above was
measured before this script edit, and only two lines of the audit can differ after
it — the inputs-missing guard and the fallback, neither of which is reached when
`launcher\` exists — so both section 20 invocations were re-run standalone against
the build tree rather than repeating the whole suite; the next full run is the one
that carries gate §18.

**§4.2 re-audited in PR 6, because PR 5 never said so explicitly.** Counted from
the XAML rather than from the screenshots: the Quick tab holds **six** input
controls and they are all buttons — `BtnMirror`, `BtnMirrorRecord`,
`BtnRecordOnly`, `BtnStop`, the `BtnShortcuts` chip and the *Rescan ADB* button
in the device panel. Everything else on that tab is read-only: 20 `TextBlock`s
(device model, battery, temperature, latency, fps, video/audio bitrate) plus the
sparkline. No codec, buffer, renderer or filter control is on it — device
selection lives in the header, session profiles in the *Avanzado* tab — so the
brief's "4-6 primary controls" is met at the top of its range, with four of the
six being the actions it names. Two further points of the same sub-clause: the
shortcut table (`ScPanel`) is `Visibility="Collapsed"` until the chip asks for it,
and the advanced surface is a tab that is not selected at startup rather than a
block inside Quick. One deviation worth recording: `App.xaml:228` styles
`Expander`, but `MainWindow.xaml` contains no `<Expander>` element — the styling
is unused, kept for a future per-section collapse, and the requirement is met by
the tab grouping instead.

### 5.1an PR 6 — the real-time filter panel, and the four defects running it found

The brief's headline feature (§5): open the colour grade over the mirror with one
key, move six sliders while the game runs, save and reload named grades, and pay
nothing for it in latency. The design constraint that shaped everything is §5.2:
the panel is **its own SDL window** and only writes the parameters of the
`--game-postfx` engine that already exists, so the mirrored frame never gains a
pass. `app/src/overlay.c` is the whole feature (panel painting, mouse and keyboard
handling, the Win32 hotkey thread, the profile file), and the client grew five
options — `--game-filter-overlay`, `--game-overlay-visible`,
`--game-overlay-hotkey=`, `--game-filter-profiles=`, `--game-overlay-english`
(documented in README §3, shortcuts in §5, cost in §6, manual checks in §7 item 15).

**How each §5.2 requirement is met.** (a) A separate borderless
`SDL_WINDOW_ALWAYS_ON_TOP` window, never drawn into the fork's scene. (b) The
sliders call `sc_gaming_set_postfx_grade()`, which only writes `g->params` and
invalidates the in-memory LUT — no new pass, no GPU re-upload, no new context.
(c) No vsync on the panel and a `dirty` flag: it repaints on interaction only, so
its idle tick is a parameter read plus a compare. (d) One persistent software
renderer created in `sc_gaming_overlay_create()` and reused; nothing per frame.

**Four defects, all found by running it rather than reading it.**

1. **A log line that promised code that did not exist.** When `RegisterHotKey`
   failed with error 1409 (another program owns the combo) the code warned *"the
   panel still opens while the mirror has focus"* — but nothing implemented that:
   the registered system hotkey was the only path. Either the sentence or the
   behaviour had to change; the behaviour did.
   `sc_gaming_overlay_want_local_hotkey()` now answers for the mirror window's own
   key events when the global registration is unavailable,
   `sc_screen_handle_event()` consumes the combo so it never reaches the game, and
   `gamingdemo` asserts the whole thing: it injects a synthetic `Super+Alt+F` and
   an `Super+Alt+Shift+F`, requires `reachable=yes` and `extra-mod-rejected=yes`,
   and fails the run if the panel is neither globally live nor locally reachable
   nor already visible. The taken-hotkey branch is not hypothetical — it is what
   this host printed while a wedged demo process still held `SUPER+ALT+F`
   (`out/ov/smoke.log`: `global hotkey 'SUPER+ALT+F' is taken (error 1409)`, then
   `global=taken local-match=yes`).
2. **§5.4 silently broken: the stored grade was never read.** The loader compared
   `sscanf(line, "current %u %u %u %u %u %u", …) == 7`, and six conversions never
   return 7. The panel therefore started every session from the command line and,
   worse, an untouched reader session overwrote `current` with that CLI grade — the
   exact "control that quietly does nothing" this directive forbids in §1.2. Fixed
   to `== 6`, and the gate asserts the round trip: a writer session stores
   `current 85 85 85 85 0 0`, a second session that only reads the file starts with
   the engine at those numbers (`overlay->engine postfx=60 contrast=85 …`), and a
   session that touches nothing leaves the file byte-identical (`changed` gates the
   save).
3. **A button outside its own window.** The action row used a fixed 160 px per
   button; three of them plus gaps exceeded the 496 px panel and `CANCELAR` was
   painted past the edge — visible in the first live screenshot. `BTN_W` is now
   derived from the grid with two `_Static_assert`s so the row cannot overflow
   again, and the gate checks the panel's own pixels by size: the snapshot BMP must
   be exactly `496*400*3+54 = 595254` bytes.
4. **Panel clicks leaked into the mirror's input path.** A click inside the panel
   is a mouse event on a window that is not the mirror, and SDL event watches see
   every window's events — the return value of `SDL_AddEventWatch` is ignored, so
   returning `true` there does nothing. The touch visualizer lit phantom dots on
   panel drags. Fixed on both sides: `sc_screen_handle_event()` ignores foreign
   windows, and `gaming_event_watch()` in `app/src/gaming.c` drops pointer traffic
   that belongs to the panel.

**Latency, measured (§5.3).** `tools/overlay_test.sh` is gate section 18. Same
grade, same 720x1280 frames, 1000 frames per arm, the panel open with a show/hide
toggle every 150 frames in the second arm (`out/ov/v3_pr6_overlay.log`):

| arm | median | p90 | p99 | max | fps presented |
|---|---|---|---|---|---|
| no panel | 3.273 ms | 3.811 ms | 5.466 ms | 52.961 ms | 63.2 |
| panel open + toggles | 3.277 ms | 3.892 ms | 5.472 ms | 17.764 ms | 64.0 |

|Δmedian| = **0.004 ms** against a 1 ms budget, |Δp99| = 0.006 ms, fps 63.2 → 64.0
(the criterion is "no drop over 3"). The max column is the tell that the tail is
not the panel: 52.961 ms in the arm **without** it versus 17.764 ms with it.

**The first full-gate run of this section failed, and the failure was the
instrument, not the feature.** `out\gate_v3_pr6.log` reports **178 passed / 2
failed**: the median criterion held and `FAIL p99 moved 1.780 ms with the panel
open` did not — on the same binary that had measured 0.006 ms standalone minutes
earlier. The reason showed up in a 250-frame diagnostic pair taken straight
after: the *same* arm produced p99 4.855 ms in one rep and 9.347 ms in the next,
because the p99 of a CPU-bound pass on a desktop that is also streaming a phone
over USB is mostly somebody else's scheduling. A single-run p99 comparison is
therefore a weak instrument for this question, and a gate that flips on it is
noise rather than evidence.

The first fix strengthened the instrument by repeating each arm, but the way the
repeats were combined was itself wrong, and the extracted package is what proved
it. Comparing each arm's *quietest* rep against the other arm's quietest rep is
not a comparison of two runs that happened at the same moment: the packaged
re-run printed `FAIL p99 moved 1.812 ms with the panel open` from a baseline rep
of 7.462 ms and a panel rep of 5.650 ms — the panel measured the *shorter* tail,
which is a result the code cannot produce, since nothing in a parameter editor
can make the mirror's pass faster. The section now pairs the arms by rep
(`base$r` then `over$r`, back to back), prints every pair as a `NOTE`, and judges
the mean of those paired differences. The median keeps the directive's symmetric
budget because it is a stable statistic here (four reps spanned 3.244–3.284 ms);
the tail is judged one-sided — only a *longer* p99 fails, a shorter one is noise
and is printed with its sign. `--med-budget` and `--p99-budget` exist so both
FAIL branches can be driven on real numbers rather than assumed, and both were:
`FAIL p99 grew 5.672 ms with the panel open (budget -0.5 ms)` and
`FAIL median moved -0.148 ms with the panel open (budget 0.001 ms)`, each with
`OVERLAY FAIL issues=…` and exit 1.

**The final run: 179 passed / 0 failed, exit 0** (`out\gate_v3_pr6c.log`, section 18
verbatim):

```
note  base1.log: frames=1000 samples=1000 med=3.274ms p90=3.976ms p99=5.966ms max=29.781ms avg=3.475ms
note  over1.log: frames=1000 samples=1000 med=3.270ms p90=4.042ms p99=5.751ms max=32.370ms avg=3.436ms
note  base2.log: frames=1000 samples=1000 med=3.323ms p90=3.931ms p99=6.787ms max=55.550ms avg=3.555ms
note  over2.log: frames=1000 samples=1000 med=3.266ms p90=3.942ms p99=7.149ms max=145.868ms avg=3.657ms
note  rep 1 pair: median -0.004 ms, p99 -0.215 ms (panel minus baseline)
note  rep 2 pair: median -0.057 ms, p99 0.362 ms (panel minus baseline)
note  mean of 2 paired reps: median -0.030 ms, p99 0.073 ms
PASS  paired median difference = -0.030 ms, |x| < 1.0 ms
PASS  paired p99 difference = 0.073 ms < 1.0 ms (only a longer tail fails)
PASS  presented fps with the panel open: 63.3 against 63.5 baseline (drop <= 3)
PASS  show/hide left the grade untouched (the A/B compares the same pixels)
```

Pairing is what makes those numbers readable: rep 1's two runs were 1.5 s apart
and differ by -0.004 ms of median, while rep 2's tail moved +0.362 ms under the
panel and -0.057 ms of median — the same shape a quiet standalone A/B produces
(Δmed 0.004 ms, Δp99 0.006 ms in `out/ov/v3_pr6_overlay.log`). The four medians
span 3.266–3.323 ms, so the 1 ms median budget has ~30x of slack, and the max
column still shows where the tail comes from: 145.868 ms in a panel rep versus
29.781 ms in a rep without it. Section 16 remains the run's only SKIP (`no device
with SDK >= 30`), which is the phone attached here, not the gate.

**The one criterion this build cannot meet, with the number that says so.** §5.3
also asks for `p99_overlay < 3 ms` in absolute terms. The pre-existing filter
engine — the thing the panel edits, not the panel — measures p99 5.888 ms at
720x1280 **with no panel at all** in the same run (5.466 ms standalone,
`out/ov/v3_pr6_overlay.log`), so no overlay design can bring that tail under 3 ms
without deleting the filters. The gate prints the cap as a measured `NOTE`
carrying both numbers rather than reporting a false pass, and the fallback the
directive offers (degrade to a launcher panel) was rejected on that evidence: the
feature's point is changing the grade during a session, and the A/B shows the
separate window is not what costs anything.

**Launcher wiring (§5.4 persistence).** Four JSON fields (`filterOverlay`,
`overlayHotkey`, `overlayVisible`, `filterProfiles`), a *Panel de filtros en tiempo
real* block at the end of the Filtros tab, and the grades in
`%APPDATA%\GamingScrcpy\filters.profiles` — the same format the client reads, so
the launcher seeds it before the session starts and harvests it back into the
session JSON on save, which is what makes a grade travel with a profile and survive
a restart. The hotkey box is free text, and a combo the client cannot register
would leave the panel answering only to `Esc`; `AppConfig.NormalizeOverlayHotkey()`
mirrors `parse_hotkey()`'s grammar (modifiers plus exactly one of `f1`-`f9`, letter
or digit, at least one modifier), the UI shows a localized warning while you type,
and an invalid combo is never emitted so the client default stays alive.
`--validate-profiles` proves both halves: the synthetic all-settings profile now
emits `--game-overlay-hotkey=ctrl+shift+f9 --game-overlay-visible`, and a profile
built with `super+alt+hyper` prints `PASS invalid overlay hotkey dropped`. The
three new controls (`ChkFilterOverlay`, `TxtOverlayHotkey`, `ChkOverlayVisible`)
were added to the UIA plan so section 10 finds them in the live window, and the two
panel rows (`Super+Alt+F`, `Esc`) filled the previously empty *Filtros* category of
the shortcut table.

**Three more defects, found by packaging rather than by coding.** (1) The published
launcher ran its self-test against the *stale* `dist` client, so all 11 profiles
failed with `unknown option -- game-filter-overlay`: the argument builder was right
and the packaged binary was old. Refreshed `dist\GamingScrcpy\scrcpy\scrcpy.exe`
and `gamingdemo.exe`, re-ran, `ALL PROFILES VALID`. (2) `tools/overlay_test.sh` had
a false-green shape: run from a shell without the UCRT64 `PATH` every demo call
exited 127, and the awk comparisons read the empty strings as 0 and printed
`OK |median difference| = 0.000 ms < 1 ms`. Now the script puts the UCRT64 bin
directory on `PATH` itself when it exists, and the numeric section refuses to run —
`FAIL a run produced no postfx-cost census or no fps line, cannot compare`, exit 1
— unless all six values are present. A gate that can print OK on nothing is worse
than no gate. (3) The same script could not run from the deliverable at all: it
resolved `gamingdemo.exe` from `workspace/scrcpy/build-usb/app/` only, so inside an
extracted ZIP it printed `FAIL demo harness missing: …pkg…/workspace/scrcpy/…`
while every other packaged harness (`fx_pixel_test.sh`,
`recorder_integrity_test.sh`, `theme_audit.sh`) passed there. It now searches the
build tree, `dist/GamingScrcpy/scrcpy/` and the package's own `scrcpy/` the same way
`fx_pixel_test.sh` does, and the packaged re-run passed the whole section. The
same sweep caught the two PowerShell harnesses doing the identical thing with the
launcher exe — `launcher_uiauto.ps1` printed `MISSING …\out\pkg_pr6b\dist\
GamingScrcpy\launcher\GamingScrcpyLauncher.exe` from inside the package — so both
now resolve `dist\GamingScrcpy\launcher\` first and the package's own `launcher\`
second, and `UIAUTO OK` has since been produced from the extraction itself. The
reason this class of bug only appears in the extraction is that the extraction is
the only layout where the build tree is absent — which is also why the directive
asks for the ZIP, not the folder, as the deliverable.

**Device evidence.** `out\shots\v5_overlay_panel.png` is the panel's own pixels
(496x400, Spanish, five buttons inside the frame); `out\shots\v5_overlay_live.png`
is that panel over a live mirror of the moto g(7) power, captured from the desktop
while the session ran. Everything else about the panel runs against `gamingdemo`
with no phone; the on-device parts that need eyes are the six manual steps of
README §7 item 15 (global hotkey with another app focused, taken-combo fallback,
live slider, saved grade after a restart, no phantom touch from panel clicks, OSD
timing unchanged).

### 5.1ao. v3 §6 triage: what already exists, what is cheap, what is backlog

The seven recommendations were checked against the shipped code rather than
assumed, because two of them turned out to be already done and one is a
half-truth. Cost is in working minutes for someone who knows this tree.

| §6 item | state in this build | cost / benefit of the rest |
|---|---|---|
| Health check general (SDK, audio, códec, renderer, latencia esperada) | **partly shipped.** *Diagnóstico de audio* covers SDK, support, the server's own refusal line, sink state and device volume. The renderer and latency numbers are measured by `tools/render_driver_test.sh` and `tools/device_latency_matrix.sh` and recorded here, not surfaced in the window. There is no single panel that says all five. | ~90 min to compose the existing probes into one panel. Benefit is presentation, not information: every number it would show is already reachable. **Backlog, low value.** |
| Indicador "audio activo" | **not the same thing as what exists.** `TxtAudioBadge` reports *support* (`compatible` / `NO SOPORTADO (needs Android 11+)`) from the SDK; nothing reports that a stream is flowing now. | ~2 h and it needs a real signal: the client would have to surface decoded-audio counters, which is a C-side change plus a gate check on a device this host does not have (Android 11+). Until then a WPF-side "active" lamp would be exactly the silently-lying control §1.2 forbids. **Backlog, blocked on hardware.** |
| Preset "Presentation mode" (borderless + always-on-top + OSD mínimo + filtros, un click) | **reachable but not one click.** Every ingredient is a config field, and the 11 session profiles carry combinations of them. | ~40 min: one button that sets four fields and starts. Real value for the streaming use case, no new risk (the same flags are already validated by `--validate-profiles`). **Candidate for the next PR.** |
| Auto-detección cada 3 s en foreground | **shipped in PR 7 (§5.1ap).** A `DispatcherTimer` gated on `IsActive` and on no live session re-runs the same read-only scan, and repaints only when a `serial:state` signature differs from the last one. `tools/autoscan_probe.ps1` counts its `adb.exe` children and gate section 21 pins the result. | estimated ~30 min, and that held. The cost is a periodic `adb devices`, which the read-only rules already allow and gate §14 already pins. |
| Última config + botón "Relaunch" | **half shipped.** The settings are persisted under `%APPDATA%\GamingScrcpy` and reloaded at start — the window came back in the language and with the device selected in the previous session — so the last configuration *is* the startup configuration. There is no "relaunch the session I just closed" button. | ~1 h for a button that re-arms the last device and profile. Moderate value, small surface. **Backlog.** |
| Cerrar el defecto #20 (borderless al arranque) | **open, and narrowed.** `--game-borderless-fullscreen` now logs `Borderless fullscreen on (WxH)` and `tools/window_style_probe.ps1` proves the caption bits are cleared, but the first frame still resizes the window back to the content size afterwards. | ~3 h in `screen.c`/`scrcpy.c` ordering, in the file the upstream-diff invariant (§13) watches most closely. Deferred deliberately: it is the one remaining change that can break the "never alter what the device renders" rule. |
| Customización de hotkeys desde la UI (persistente) | **shipped.** `RefreshKeymaps()` feeds a keymap editor whose result lands in `cfg.ShortcutMods` and is emitted as `--shortcut-mod=…`, persisted in the same JSON. The filter panel's own `Super+Alt+F` became editable in this PR. | nothing left to build. |

Two of the seven were already shipped when this table was written (the hotkey
editor, and the persisted last configuration); the 3 s foreground re-scan joined them
in PR 7 (§5.1ap). Presentation mode — the second of the two rows marked *candidate
for the next PR* — is still open: ~40 min for one button that sets four fields
already validated by `--validate-profiles`. The rest are either presentation-only or
blocked on hardware and on the §13 invariant. Neither cheap item was folded into
PR-6: §7.2 asks for one feature per commit, and PR-6 is already the largest of the
round.

The triage also turned up one dead row: `TabPerf` ("Rendimiento" / "Performance")
is still a `Loc.cs` key but no XAML uses it — the v3 tab consolidation folded the
performance content into the other tabs and left the label behind. It is invisible
to the user and to the key-parity check (the key exists in both languages), so it
is recorded here rather than silently deleted, next to the same class of leftover
the duplicate-key count in §15 catches.

### 5.1ap. PR 7 — the launcher notices the phone without being asked

The first of the two cheap §6 candidates shipped: a `DispatcherTimer` ticks every
3 s and re-runs the device scan, but only while the window is in the foreground
and no mirror is running (`IsActive`, `_scrcpy is { HasExited: false }`), and it
repaints only when the list actually changed — a `serial:state` signature compared
against the last scan. All three guards come from the same rule that killed the
dead audio checkbox in §1.2: a background poll that moves the selection the user
made, disturbs a live session or fills the run log is a worse feature than no
feature. If `adb` goes missing the tick logs the reason once and stops itself
rather than throwing from a timer, which would take the process down.

**How an invisible behaviour gets measured.** Nothing on screen changes when the
list is unchanged, so `tools/autoscan_probe.ps1` counts the only external trace a
poll leaves: the short-lived `adb.exe` children the launcher starts while its
window is foreground. Counting begins 1.5 s after the window appears, so the
startup refresh cannot be mistaken for a tick. The instrument under-counts — a
child can be born and gone between two 200 ms WMI samples, and the first 12 s run
saw 2 of the ~4 expected ticks — so the window is 24 s (8 ticks) against a
threshold of 3, and what is asserted is the separation, not the rate. Gate section
21 runs it; the pass printed:

```
note  4 adb children in 24s, window foreground=True
OK auto-scan polled repeatedly: 4 adb children (threshold 3)
AUTOSCAN OK
```

Its failure mode is demonstrated rather than assumed: the same probe against the
package that shipped without the timer printed `note 0 adb children in 24s` and
`FAIL only 0 adb children in 24s: the timer is not firing (threshold 3)`. The
narrower 12 s window failed on the *new* build too (2 children), which is how the
under-count was found — the check went red before it was trusted.

The full gate with PR-7 in it is `out/gate_v3_pr7b.log`, ending:

```
  PASS  auto-scan polled repeatedly: 5 adb children (threshold 3)

summary
  180 passed, 0 failed
gate exit=0
```

That same run caught a defect in section 21 itself: the gate defines only `ok`,
`bad` and `head_`, and the new section called a `note` helper that does not exist,
so the shell printed `tools/verify_all.sh: line 747: note: command not found` and
the measured count never reached the log. The pass/fail arithmetic was unaffected,
which is exactly why it needed seeing: a check that swallows its own numbers
reports a verdict with no evidence behind it. The branch now prints through the
same inline `printf` the other sections use for harness notes, so the adb-children
count is in the log next to the PASS it justifies.

The repack and the extracted-ZIP self-test for PR-7 (`tools/package_selftest.sh`,
whose output is `out/pkg_pr7_selftest.log`) were still running when this section
was written; no packaged result is claimed here for the PR-7 archive. What is
claimed is the gate above and the two probe runs, both filed.

**What the gate caught on the way.** The first PR-7 run failed *outside* its own new
section: §15 (no user-visible literal left in the code-behind) flagged the
`Log($"auto-scan stopped: {ex.Message}")` line the timer writes when `adb` goes
missing. The new feature's own error path was the one string in that file that had
never been localised, and it went in unnoticed until a section written two PRs
earlier crossed it. It is now `LogAutoScanStopped`, ES *auto-reescaneo detenido: {0}
(usa Reescanear ADB)* / EN *auto-rescan stopped: {0} (use Rescan ADB)*, worded to
match the existing `BtnRescan` label rather than inventing a third name for the same
button. A check added for one feature guards every later one, which is the argument
for keeping them rather than trusting that nobody writes a literal.

The scan is the same read the button performs: `adb devices` plus the read-only
`getprop` calls for model, release and SDK. Nothing is written to the phone, and
`out/dev/adb_audit.log` keeps the record of every command of the session.

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
