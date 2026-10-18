using System.IO;
using System.Text.Json.Serialization;

namespace GamingScrcpyLauncher;

/// Host-side gaming / streaming configuration.
/// Field names are the JSON keys of the profiles under
/// %APPDATA%\GamingScrcpy\profiles.
public sealed class AppConfig
{
    // ---- identity and display strings ----
    // "name" is the identity: it keys the file under
    // %APPDATA%\GamingScrcpy\profiles and becomes the mirror window title, so
    // it never changes when the UI is translated. The two Es fields are what the
    // user reads; a profile written before they existed falls back to "name"
    // and "notes", which is why every builtin carries both languages.
    [JsonPropertyName("name")] public string Name { get; set; } = "Default";
    [JsonPropertyName("nameEs")] public string NameEs { get; set; } = "";
    [JsonPropertyName("notes")] public string Notes { get; set; } = "";
    [JsonPropertyName("notesEs")] public string NotesEs { get; set; } = "";

    public static bool Spanish =>
        string.Equals(Loc.Instance.Language, "es", StringComparison.OrdinalIgnoreCase);

    public string DisplayName =>
        Spanish && !string.IsNullOrWhiteSpace(NameEs) ? NameEs : Name;

    public string DisplayNotes =>
        Spanish && !string.IsNullOrWhiteSpace(NotesEs) ? NotesEs : Notes;

    // The two readouts the profile table shows, in the same tokens the command
    // line uses.
    public string CodecLabel => MapCodec(VideoCodec);

    // The cap this profile puts on the picture, as the table's resolution cell
    // shows it: the host window size, or the frame bridge's size when no window
    // cap is set. Empty means nothing is capped and the device's own picture is
    // presented. Nothing here is ever a change to the device.
    public string HostCapLabel =>
        CapOf(HostPreset) ?? CapOf(HostWidth, HostHeight) ?? BridgeCapLabel ?? "";

    private string? BridgeCapLabel
    {
        get
        {
            if (string.IsNullOrWhiteSpace(FrameBridge)
                || NormalizeBridgeScale(BridgeScale) is not { } scale)
            {
                return null;
            }
            var parts = scale.Split('x');
            return CapOf(int.Parse(parts[0]), int.Parse(parts[1]));
        }
    }

    private static string? CapOf(string preset) =>
        Presets.TryGetValue(preset, out var p) && p.w > 0 ? CapOf(p.w, p.h) : null;

    private static string? CapOf(int w, int h) => (w, h) switch
    {
        (3840, 2160) => "4K",
        (2560, 1440) => "1440p",
        (1920, 1080) => "1080p",
        (1280, 720) => "720p",
        (0, 0) => null,
        ( > 0, > 0) => $"{w}x{h}",
        _ => null,
    };

    // The profile table's latency column. It is the profile's own video buffer
    // plus the host floor this fork was measured at (14-20 ms presented on the
    // S23 Ultra, BUILD_REPORT 5.1as), so it reads as the estimate it is: the
    // number to compare against the OSD's measured one, not a measurement.
    public int ExpectedLatencyMs => VideoBufferMs + EncoderPreset switch
    {
        "ultrafast" => 15,
        "fast" => 20,
        "medium" => 30,
        _ => 40,
    };

    // ---- device / transport ----
    [JsonPropertyName("serial")] public string Serial { get; set; } = "";
    [JsonPropertyName("transport")] public string Transport { get; set; } = "auto";

    // ---- capture (device side; the framebuffer is never resized) ----
    [JsonPropertyName("videoCodec")] public string VideoCodec { get; set; } = "h264";
    [JsonPropertyName("bitrateMbps")] public int BitrateMbps { get; set; } = 16;
    [JsonPropertyName("maxFps")] public int MaxFps { get; set; } = 60;
    [JsonPropertyName("videoEncoder")] public string VideoEncoder { get; set; } = "";
    [JsonPropertyName("hwdec")] public string Hwdec { get; set; } = "auto";
    [JsonPropertyName("audioCodec")] public string AudioCodec { get; set; } = "opus";
    [JsonPropertyName("audioBitrateKbps")] public int AudioBitrateKbps { get; set; } = 128;
    [JsonPropertyName("audioSource")] public string AudioSource { get; set; } = "output";
    // Comes from the attached device, never from a profile: below Android 11 the
    // server refuses device audio, so the launcher must not pretend the audio
    // flags it sends do anything.
    [JsonIgnore] public bool NoDeviceAudio { get; set; }

    /// <summary>
    /// Encoder speed/quality bias, translated into the MediaFormat latency key.
    /// Android has no x264-style preset; this is the knob the device encoder
    /// actually exposes, and it may still ignore it.
    /// </summary>
    [JsonPropertyName("encoderPreset")] public string EncoderPreset { get; set; } = "default";

    // ---- buffers ----
    [JsonPropertyName("videoBufferMs")] public int VideoBufferMs { get; set; }
    [JsonPropertyName("audioBufferMs")] public int AudioBufferMs { get; set; } = 120;
    [JsonPropertyName("audioOutputBufferMs")] public int AudioOutputBufferMs { get; set; } = 160;

    // ---- host presentation (this is where the gaming quality lives) ----
    [JsonPropertyName("renderDriver")] public string RenderDriver { get; set; } = "direct3d11";
    [JsonPropertyName("upscale")] public string Upscale { get; set; } = "best";
    [JsonPropertyName("windowFilter")] public string WindowFilter { get; set; } = "off";
    [JsonPropertyName("renderFit")] public string RenderFit { get; set; } = "letterbox";
    [JsonPropertyName("mipmaps")] public bool Mipmaps { get; set; } = true;
    [JsonPropertyName("lowLatency")] public bool LowLatency { get; set; } = true;
    [JsonPropertyName("borderlessFullscreen")] public bool BorderlessFullscreen { get; set; }
    [JsonPropertyName("alwaysOnTop")] public bool AlwaysOnTop { get; set; }
    [JsonPropertyName("osd")] public string Osd { get; set; } = "compact";
    [JsonPropertyName("cursorAutohideMs")] public int CursorAutohideMs { get; set; }
    [JsonPropertyName("hostPreset")] public string HostPreset { get; set; } = "fit";
    // properties, not fields: System.Text.Json only writes properties, so an
    // explicit host window size used to vanish on the way to the profile file and
    // come back as "no cap" (measured: a saved 1280x720 preset reloaded as 0x0)
    [JsonPropertyName("hostWidth")] public int HostWidth { get; set; }
    [JsonPropertyName("hostHeight")] public int HostHeight { get; set; }

    // ---- post-processing (opt-in: it costs host CPU on the frame path) ----
    [JsonPropertyName("fxSharp")] public bool FxSharp { get; set; }
    [JsonPropertyName("fxNight")] public bool FxNight { get; set; }
    [JsonPropertyName("fxSat")] public bool FxSat { get; set; }
    [JsonPropertyName("fxContrast")] public bool FxContrast { get; set; }
    [JsonPropertyName("fxBrightness")] public bool FxBright { get; set; }
    [JsonPropertyName("fxGamma")] public bool FxGamma { get; set; }
    [JsonPropertyName("sharpness")] public int Sharpness { get; set; } = 35;
    [JsonPropertyName("nightBoost")] public int NightBoost { get; set; }
    [JsonPropertyName("saturation")] public int Saturation { get; set; } = 100;
    [JsonPropertyName("contrast")] public int Contrast { get; set; } = 100;
    [JsonPropertyName("brightness")] public int Brightness { get; set; } = 100;
    [JsonPropertyName("gamma")] public int Gamma { get; set; } = 100;

    // ---- real-time filter panel (directive v3 §5) ----
    // The panel is a window of the client's own, so the launcher only decides
    // whether it exists, which key opens it, and where its profiles live.
    // On by default: opening it costs nothing on the frame path (measured in
    // tools/overlay_test.sh), and the user asked for the shortcut to be there.
    [JsonPropertyName("filterOverlay")] public bool FilterOverlay { get; set; } = true;
    [JsonPropertyName("overlayHotkey")] public string OverlayHotkey { get; set; } = "super+alt+f";
    [JsonPropertyName("overlayVisible")] public bool OverlayVisible { get; set; }
    // The named profiles travel with the session: these are the exact lines of
    // the client's profile file, so saving a session carries them and loading
    // one restores them (v3 §5.4).
    [JsonPropertyName("filterProfiles")] public List<string> FilterProfiles { get; set; } = new();

    // The Performance tab has nothing to draw without this, and the fork prints
    // one line per second, so it is on by default. A profile can still turn it
    // off (the JSON key wins over the initializer when it is present).
    [JsonPropertyName("telemetryLog")] public bool TelemetryLog { get; set; } = true;

    // ---- control ----
    [JsonPropertyName("touchVisualizer")] public bool TouchVisualizer { get; set; }
    [JsonPropertyName("keyboardMode")] public string KeyboardMode { get; set; } = "auto";
    [JsonPropertyName("mouseMode")] public string MouseMode { get; set; } = "auto";
    [JsonPropertyName("gamepadMode")] public string GamepadMode { get; set; } = "disabled";
    [JsonPropertyName("mouseBindings")] public string MouseBindings { get; set; } = "";
    [JsonPropertyName("shortcutMods")] public string ShortcutMods { get; set; } = "lsuper,lctrl";

    // ---- recorder / streaming ----
    [JsonPropertyName("record")] public bool Record { get; set; }
    [JsonPropertyName("recordPath")] public string RecordPath { get; set; } = "";
    [JsonPropertyName("container")] public string Container { get; set; } = "mkv";
    [JsonPropertyName("frameBridge")] public string FrameBridge { get; set; } = "";
    [JsonPropertyName("bridgeScale")] public string BridgeScale { get; set; } = "";
    [JsonPropertyName("bridgeFilter")] public string BridgeFilter { get; set; } = "lanczos";
    [JsonPropertyName("audioBridge")] public string AudioBridge { get; set; } = "";
    // Decoded audio copied as s16le / 48 kHz / stereo, i.e. the format a virtual
    // cable or `ffmpeg -f s16le` can actually play.
    [JsonPropertyName("audioPcm")] public string AudioPcm { get; set; } = "";
    // Send the game audio to the PCM tap only: scrcpy keeps decoding it but
    // stays silent on the PC, so OBS hears the cable and you do not hear it twice.
    [JsonPropertyName("pcmMutePlayback")] public bool PcmMutePlayback { get; set; }
    [JsonPropertyName("turnScreenOff")] public bool TurnScreenOff { get; set; }

    // ---- escape hatch ----
    [JsonPropertyName("extraArgs")] public string ExtraArgs { get; set; } = "";

    public AppConfig Clone()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(this);
        return System.Text.Json.JsonSerializer.Deserialize<AppConfig>(json) ?? new AppConfig();
    }

    // older or hand-edited profiles may carry a value this scrcpy rejects
    private static string NormalizeUpscale(string value) => value switch
    {
        "nearest" or "linear" or "pixelart" or "default" => value,
        _ => "linear",
    };

    // resampling the presented frame is sharper than GPU stretching but runs on
    // the render path, so an unknown value falls back to the cheap behaviour
    private static string NormalizeWindowFilter(string value) => value switch
    {
        "point" or "bilinear" or "fast" or "bicubic" or "lanczos" or "off" => value,
        _ => "off",
    };

    // overlay.c only registers a combo it can turn into a Windows hotkey:
    // modifiers joined by '+' plus exactly one key (f1-f9, a letter or a
    // digit). Anything else silently leaves the panel reachable only by Esc
    // inside the mirror, so an invalid combo is dropped here and the default
    // stays live instead of shipping a panel nobody can open.
    public static string? NormalizeOverlayHotkey(string? raw)
    {
        const string combined = "super+alt+f";
        var text = (raw ?? "").Trim();
        if (text.Length == 0)
        {
            return combined;
        }
        var tokens = text.ToLowerInvariant().Split('+');
        bool mods = false;
        bool key = false;
        foreach (var token in tokens)
        {
            bool isMod = token is "ctrl" or "control" or "alt" or "shift"
                         or "super" or "win" or "meta";
            bool isKey = token.Length == 1
                             ? token[0] is >= 'a' and <= 'z' or >= '0' and <= '9'
                             : token.Length == 2 && token[0] == 'f'
                               && token[1] is >= '1' and <= '9';
            if (isMod)
            {
                mods = true;
            }
            else if (isKey && !key)
            {
                key = true;
            }
            else
            {
                return null;
            }
        }
        return mods && key ? string.Join("+", tokens) : null;
    }

    public static string? NormalizeBridgeScale(string value)
    {
        var parts = value.Trim().ToLowerInvariant().Split('x');
        if (parts.Length != 2
            || !int.TryParse(parts[0], out var w)
            || !int.TryParse(parts[1], out var h)
            || w is < 16 or > 8192
            || h is < 16 or > 8192)
        {
            return null;
        }
        return $"{w}x{h}";
    }

    // The codec as the picker lists it. Profiles and command line spell H.265
    // "h265" while the UI item says "hevc": reading the stored value straight
    // into the combo fell back to h264, which would have rewritten the codec of
    // every h265 preset on the next save.
    public string CodecChoice => MapCodec(VideoCodec) == "h265" ? "hevc" : MapCodec(VideoCodec);

    private static string MapCodec(string codec) => codec switch    {
        "hevc" or "h265" or "HEVC" => "h265",
        "av1" => "av1",
        _ => "h264",
    };

    private static string? MapHwdec(string mode) => mode switch    {
        "never" or "disabled" or "software" => "disabled",
        "always" or "d3d11va" => "d3d11va",
        "vaapi" => "vaapi",
        "videotoolbox" => "videotoolbox",
        _ => null, // auto: leave it to scrcpy
    };

    // MediaFormat.KEY_LATENCY is a 0..9 bias, not an x264 preset: the device
    // encoder decides what to do with it.
    private static int EncoderLatency(string preset) => preset switch
    {
        "ultrafast" => 9,
        "fast" => 7,
        "medium" => 5,
        _ => 0,
    };

    private static readonly Dictionary<string, (int w, int h)> Presets = new()
    {
        ["fit"] = (0, 0),
        ["1080p"] = (1920, 1080),
        ["1440p"] = (2560, 1440),
        ["4k"] = (3840, 2160),
        ["9:16-1080"] = (1080, 1920),
        ["9:16-1440"] = (1440, 2560),
    };

    /// Build the scrcpy argument list. Arguments are returned separately so the
    /// process is started without any shell quoting guesswork.
    public List<string> BuildArguments(string? overrideSerial = null)
    {
        var noDeviceAudio = NoDeviceAudio;
        var a = new List<string>();

        var serial = string.IsNullOrWhiteSpace(overrideSerial) ? Serial : overrideSerial;
        if (!string.IsNullOrWhiteSpace(serial))
        {
            a.Add($"--serial={serial}");
        }
        if (Transport == "usb")
        {
            a.Add("--select-usb");
        }
        else if (Transport == "tcpip")
        {
            a.Add("--select-tcpip");
        }

        // ---- capture ----
        // every value below is normalised to a token this scrcpy build accepts
        a.Add($"--video-codec={MapCodec(VideoCodec)}");
        a.Add($"--video-bit-rate={BitrateMbps}M");
        if (MaxFps > 0)
        {
            a.Add($"--max-fps={MaxFps}");
        }
        if (!string.IsNullOrWhiteSpace(VideoEncoder))
        {
            a.Add($"--video-encoder={VideoEncoder}");
        }
        if (EncoderPreset is "ultrafast" or "fast" or "medium")
        {
            // MediaFormat.KEY_LATENCY: higher = "spend less time per frame"
            // MediaFormat.KEY_LATENCY, spelled with scrcpy's key:type=value
            // syntax (a plain key:value is rejected by the server)
            a.Add($"--video-codec-options=latency:int={EncoderLatency(EncoderPreset)}");
        }
        var hwdec = MapHwdec(Hwdec);
        if (hwdec != null)
        {
            a.Add($"--hwdec={hwdec}");
        }
        if (noDeviceAudio)
        {
            a.Add("--no-audio");
        }
        else
        {
            a.Add($"--audio-codec={AudioCodec}");
            // raw PCM has no bitrate: scrcpy warns that the value is ignored
            if (AudioCodec != "raw")
            {
                a.Add($"--audio-bit-rate={AudioBitrateKbps}K");
            }
            if (!string.IsNullOrWhiteSpace(AudioSource) && AudioSource != "auto")
            {
                a.Add($"--audio-source={AudioSource}");
            }
        }
        // No --max-size / --crop / --new-display anywhere on purpose: the device
        // keeps its native framebuffer, so game UI and touch mapping stay exact.

        // ---- buffers ----
        a.Add($"--video-buffer={VideoBufferMs}");
        if (!noDeviceAudio)
        {
            a.Add($"--audio-buffer={AudioBufferMs}");
            a.Add($"--audio-output-buffer={AudioOutputBufferMs}");
        }

        // ---- host presentation ----
        if (RenderDriver != "default")
        {
            a.Add($"--render-driver={RenderDriver}");
        }
        a.Add($"--game-upscale={NormalizeUpscale(Upscale)}");
        var windowFilter = NormalizeWindowFilter(WindowFilter);
        if (windowFilter != "off")
        {
            a.Add($"--game-window-filter={windowFilter}");
        }
        if (RenderFit is "letterbox" or "stretched" or "unscaled")
        {
            a.Add($"--render-fit={RenderFit}");
        }
        if (!Mipmaps)
        {
            a.Add("--no-mipmaps");
        }
        if (LowLatency)
        {
            a.Add("--game-low-latency");
        }
        if (BorderlessFullscreen)
        {
            a.Add("--game-borderless-fullscreen");
        }
        if (AlwaysOnTop)
        {
            a.Add("--always-on-top");
        }
        if (Osd != "none")
        {
            a.Add($"--game-osd={Osd}");
        }
        if (CursorAutohideMs > 0)
        {
            a.Add($"--game-cursor-autohide={CursorAutohideMs}");
        }
        if (Presets.TryGetValue(HostPreset, out var preset) && preset.w > 0)
        {
            a.Add($"--window-width={preset.w}");
            a.Add($"--window-height={preset.h}");
        }
        else if (HostWidth > 0 && HostHeight > 0)
        {
            a.Add($"--window-width={HostWidth}");
            a.Add($"--window-height={HostHeight}");
        }

        // ---- post-processing ----
        var fx = new List<string>();
        if (FxSharp) fx.Add("sharp");
        if (FxNight) fx.Add("night");
        if (FxSat) fx.Add("sat");
        if (FxContrast) fx.Add("contrast");
        if (FxBright) fx.Add("brightness");
        if (FxGamma) fx.Add("gamma");
        if (fx.Count > 0)
        {
            a.Add($"--game-postfx={string.Join(",", fx)}");
            if (FxSharp) a.Add($"--game-sharp={Sharpness}");
            if (FxNight) a.Add($"--game-night-boost={NightBoost}");
            if (FxSat) a.Add($"--game-saturation={Saturation}");
            if (FxContrast) a.Add($"--game-contrast={Contrast}");
            if (FxBright) a.Add($"--game-brightness={Brightness}");
            // the fork floors gamma at 25: below that the curve is a black
            // screen, and a slider dragged to its end must not produce one
            if (FxGamma) a.Add($"--game-gamma={Math.Max(25, Gamma)}");
        }
        if (FilterOverlay)
        {
            ProfileStore.SeedFilterProfiles(this);
            a.Add("--game-filter-overlay");
            var hk = NormalizeOverlayHotkey(OverlayHotkey);
            if (hk != null && hk != "super+alt+f")
            {
                a.Add($"--game-overlay-hotkey={hk}");
            }
            if (OverlayVisible)
            {
                a.Add("--game-overlay-visible");
            }
            a.Add($"--game-filter-profiles={ProfileStore.FilterProfilesPath}");
            if (!string.Equals(Loc.Instance.Language, "es", StringComparison.OrdinalIgnoreCase))
            {
                a.Add("--game-overlay-english");
            }
        }
        if (TouchVisualizer)
        {
            a.Add("--game-touch-visualizer");
        }
        if (TelemetryLog)
        {
            a.Add("--game-telemetry-log");
        }

        // ---- control ----
        // scrcpy 5 accepts disabled|sdk|uhid|aoa for keyboard/mouse and has no
        // "auto" token, so "auto" means "do not pass the option at all"
        if (KeyboardMode is "sdk" or "uhid" or "aoa" or "disabled")
        {
            a.Add($"--keyboard={KeyboardMode}");
        }
        if (MouseMode is "sdk" or "uhid" or "aoa" or "disabled")
        {
            a.Add($"--mouse={MouseMode}");
        }
        if (GamepadMode is "uhid" or "aoa" or "disabled")
        {
            a.Add($"--gamepad={GamepadMode}");
        }
        if (!string.IsNullOrWhiteSpace(MouseBindings))
        {
            a.Add($"--mouse-bind={MouseBindings}");
        }
        if (!string.IsNullOrWhiteSpace(ShortcutMods))
        {
            a.Add($"--shortcut-mod={ShortcutMods}");
        }

        // ---- recorder / streaming ----
        if (Record)
        {
            var path = string.IsNullOrWhiteSpace(RecordPath)
                ? Path.Combine(ProfileStore.RecordingsDir,
                               $"rec-{DateTime.Now:yyyyMMdd-HHmmss}.{Container}")
                : RecordPath;
            a.Add($"--record={path}");
            a.Add($"--record-format={Container}");
        }
        if (!string.IsNullOrWhiteSpace(FrameBridge))
        {
            a.Add($"--game-frame-bridge={FrameBridge}");
            var scale = NormalizeBridgeScale(BridgeScale);
            if (scale != null)
            {
                a.Add($"--game-bridge-scale={scale}");
                var filter = BridgeFilter is "point" or "bilinear" or "fast"
                                  or "bicubic" or "lanczos"
                    ? BridgeFilter
                    : "default";
                a.Add($"--game-bridge-filter={filter}");
            }
        }
        // The two audio taps copy decoded device audio. With no device audio
        // there is nothing to copy, so they stay off rather than opening pipes
        // that never receive a packet.
        if (!noDeviceAudio && !string.IsNullOrWhiteSpace(AudioBridge))
        {
            a.Add($"--game-audio-bridge={AudioBridge}");
        }
        if (!noDeviceAudio && !string.IsNullOrWhiteSpace(AudioPcm))
        {
            a.Add($"--game-audio-pcm={AudioPcm}");
            if (PcmMutePlayback)
            {
                a.Add("--no-audio-playback");
            }
        }
        if (TurnScreenOff)
        {
            a.Add("--turn-screen-off");
        }

        a.Add("--window-title");
        // the title is the name the user picked, in the language they read: OBS
        // targets the mirror by this string, so it has to be the one the profile
        // selector shows. The stored identity (Name) is unchanged.
        a.Add(string.IsNullOrWhiteSpace(DisplayName) ? "Gaming Scrcpy" : DisplayName);

        foreach (var extra in SplitExtraArgs(ExtraArgs))
        {
            a.Add(extra);
        }
        return a;
    }

    public string Preview(string scrcpyExe, string? overrideSerial = null)
    {
        var args = BuildArguments(overrideSerial);
        var quoted = args.Select(x => x.Contains(' ') ? $"\"{x}\"" : x);
        return $"\"{scrcpyExe}\" {string.Join(" ", quoted)}";
    }

    public static IEnumerable<string> SplitExtraArgs(string extra)
    {
        // Accept quoted values: --foo="a b" --bar
        var parts = new List<string>();
        var cur = new System.Text.StringBuilder();
        char? quote = null;
        foreach (var ch in extra)
        {
            if (quote != null)
            {
                if (ch == quote)
                {
                    quote = null;
                }
                else
                {
                    cur.Append(ch);
                }
            }
            else if (ch is '"' or '\'')
            {
                quote = ch;
            }
            else if (char.IsWhiteSpace(ch))
            {
                if (cur.Length > 0)
                {
                    parts.Add(cur.ToString());
                    cur.Clear();
                }
            }
            else
            {
                cur.Append(ch);
            }
        }
        if (cur.Length > 0)
        {
            parts.Add(cur.ToString());
        }
        return parts;
    }
}
