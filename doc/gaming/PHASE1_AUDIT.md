# PHASE 1 — Environment Audit & Stock Compilation

Date: 2026-10-16 (host local) · Host: Windows 10 22H2 (10.0.19045) x64 · Working dir: the repository root (this project was first built under `Desktop/GamingCapture`, which is not part of the published layout)

## 1. Premise correction (important)

The task brief stated the following were **verified in PATH**: `git`, `python` 3.12, `meson`, `ninja`, `dotnet` 8.0, `adb`.
That statement is **not true on this machine**. The actual audit (Git Bash `command -v` + PowerShell `Get-Command`, both re-checked against the filesystem) was:

| Tool | Claimed | Actual at session start | Evidence |
|---|---|---|---|
| `git` | yes | **present** | `C:\Program Files\Git\mingw64\bin\git.exe` (2.55.0) |
| `python` | 3.12 | **not usable** | only the Microsoft Store *stub alias* `…\WindowsApps\python.exe`, which prints "no se encontró Python" and exits |
| `meson` | yes | **absent** | not in PATH, not in `C:\` root, no `C:\msys64` |
| `ninja` | yes | **absent** | same |
| `dotnet` | 8.0 | **installed but not in Git Bash PATH** | `C:\Program Files\dotnet\dotnet.exe` → SDK `8.0.426` (usable by absolute path) |
| `adb` | yes | **absent** | no platform-tools anywhere on `C:\` |
| C compiler (MSVC/MinGW/Clang) | — | **absent** | no `cl`, `gcc`, `clang`; no Visual Studio / Build Tools install |
| `pkg-config` | — | **absent** | required by Meson to find SDL/FFmpeg |
| `java` | — | present | JDK 19.0.2 (`C:\Program Files\Java\jdk-19`) |
| `winget` | — | present | enables bootstrapping |
| SDL2 / FFmpeg dev libs | — | absent | nothing on the host |

Outbound network: `api.github.com` **200**, `dl.google.com` **200** (so downloads are possible).

Consequence: Phase 1 had to *create* the toolchain rather than use it. Nothing about the "basic toolchain is ready" premise held except `git`.

## 2. Toolchain bootstrap performed

1. `winget install --id MSYS2.MSYS2` → `C:\msys64` (build 20260611), then `pacman -Syu` twice.
2. `pacman -S --needed mingw-w64-ucrt-x86_64-{gcc,meson,ninja,pkgconf,sdl3,ffmpeg}`
   → GCC (UCRT64), Meson 1.12.1, Ninja, pkgconf, **SDL3 ≥ 3.2**, FFmpeg dev (libavcodec/avformat/avutil/swresample/swscale) with `.pc` files.
3. `adb`: `platform-tools-latest-windows.zip` from `dl.google.com` → `tools\platform-tools\adb.exe`.
4. Reference runtime: official `scrcpy-win64-v5.0.1.zip` → `tools\stock\` (DLL set + stock `scrcpy-server`).

Compiler actually used: **MinGW-w64 (UCRT64) GCC** — MSVC/Visual Studio is not installed on this host, and Meson's `--auto-features=enabled` wrap path was not needed because the UCRT64 pkg-config files resolve SDL3/FFmpeg directly.

## 3. Source retrieval & architecture findings

`git clone https://github.com/Genymobile/scrcpy.git ./workspace/scrcpy` → HEAD `a60891a`, tag **v5.0.1**.

Findings that change assumptions in the brief:

- **The client uses SDL3, not SDL2** (`app/src/screen.c` includes `<SDL3/SDL.h>`; the official release ships `SDL3.dll`). Renderer creation is the SDL3 single-argument form `SDL_CreateRenderer(window, NULL)` ([screen.c:616](workspace/scrcpy/app/src/screen.c#L616)); the backend is selected by the `SDL_HINT_RENDER_DRIVER` hint set in `sdl_hints.c` and driven by `--rendering-driver` (so `direct3d11`, `opengl`, `vulkan` are chosen that way, not by renderer flags).
- **There is no OpenGL shader pipeline for presentation.** The frame is drawn with `SDL_RenderTexture` / `SDL_RenderTextureRotated` inside `sc_screen_render()` ([screen.c:259-344](workspace/scrcpy/app/src/screen.c#L259-L344)). Upscale quality is therefore controlled by the texture scale mode + mipmaps, not by a filter kernel you can swap. Any pixel-shader-style work has to happen on the host `AVFrame` (CPU) or in an SDLGPU path that does not exist upstream.
- **No text OSD exists.** `--show-fps` only logs to the console (`fps_counter.c`); `icon.c` is a PNG loader for the disconnected-state icon. A gaming telemetry overlay must be implemented from scratch (SDL3 has no bundled text API).
- **`--mute-device` does not exist in v5.0.1**; device-speaker muting during audio forwarding is reached through `--audio-source=playback` / `--no-audio-playback`. Host audio routing to external sinks must be built.
- `struct scrcpy_options` ([options.h:265-376](workspace/scrcpy/app/src/options.h#L265-L376)) already exposes everything the brief asks the recorder to control: `video_codec` (h264/h265/av1), `video_bit_rate`, `max_fps`, `record_format` (mp4/mkv), `audio_codec`, `video_buffer`, `audio_buffer`, `render_fit`, `mipmaps`, `render_driver`, `hwdec_mode`. Recording runs as a parallel packet sink next to the display, so "dual recording mode" (file + live mirror) is native, and device packets are **muxed without re-encoding** (zero extra host latency).
- The CLI is a `struct sc_option options[]` table + `getopt_long` switch ([cli.c:22-127](workspace/scrcpy/app/src/cli.c#L22-L127)); help text is generated from that table, so new flags are added in three places (enum id, table entry, parse case).
- The Meson **project root is the repository root**, not `app/` (`app/meson.build` is pulled in by the top-level `meson.build`). Running `meson setup` inside `app/` fails with "Not the project root".

## 4. Stock build result

Command actually used (from the repo root, inside the UCRT64 environment):

```
meson setup build-x --buildtype=release -Dusb=false -Dv4l2=false -Dtests=false
ninja -C build-x
```

Iterations and blockers found (these are real results, not guesses):

1. `meson setup` from `app/` → `ERROR: Not the project root` → must run from the repo root.
2. From the root, `-Dusb=disabled` → `ERROR: Option "usb" value disabled is not boolean` → `usb` is a boolean option, not a feature option → use `-Dusb=false`.
3. First real blocker: `Dependency "libusb-1.0" not found (tried pkg-config)` — the USB/HID feature needs `mingw-w64-ucrt-x86_64-libusb`. Since this fork is about display/audio/recording (not OTG HID keyboards), the feature is switched off with `-Dusb=false` rather than dragging in another dependency.
4. V4L2 is Linux-only (`-Dv4l2=false`); the test suite is disabled for the release tree (`-Dtests=false`).

Stock compilation outcome and the produced `scrcpy.exe`: recorded in `BUILD_REPORT.md` (section "Stock baseline"). No source file was modified while the stock build ran — the new `app/src/gaming.{c,h}` module was present on disk but not yet listed in `app/meson.build`, so it was excluded from the stock compile.

## 5. Test-device situation (affects what can be validated)

`adb devices -l` → **empty list**: no Android device or emulator is attached to this host, and no Android SDK/emulator is installed. Therefore:

- Live end-to-end mirroring (device encode → ADB → decode → present) **cannot be measured on this machine**, and no device-side latency figure can be claimed.
- The server (`scrcpy-server`) is an Android Gradle application (`compileSdk 36`), so rebuilding it would require downloading the full Android SDK. All features in this fork are host-side (C client) by design, so the version-matched v5.0.1 server binary is used unmodified — which keeps device/touch mapping untouched, exactly as the brief requires.
- To still validate the presentation engine for real, the fork ships a synthetic-frame demo harness (`gamingdemo`, built by the same Meson tree) that drives the *same* code paths (upscale filter, post-filters, OSD overlay, touch visualizer, frame bridge) with generated frames on the host GPU, plus headless checks of the CLI parser.

## 6. Decisions carried into Phase 2

- Keep every gaming feature **host-side only**: never `--max-size`/`--new-display`/crop the device framebuffer for upscaling; scale in presentation, not in capture.
- Post-processing must be opt-in (default off) because it is CPU work on the frame path, and its cost is measured and published rather than promised.
- Bridges (video/audio) use a **drop-oldest queue on a worker thread** so a slow OBS/FFmpeg consumer can never stall mirroring.
- Shortcut keys are installed via `SDL_AddEventWatch` inside the new module, so no upstream input-dispatch code has to be rewritten.
