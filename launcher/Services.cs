using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace GamingScrcpyLauncher;

// Sdk is ro.build.version.sdk (0 = not read yet). The launcher needs it because
// two of the things a profile can ask for simply do not exist on older
// Androids: an AV1 encoder, and any audio at all before API 30.
public sealed record AndroidDevice(string Serial, string Model, string State, bool IsWireless,
                                   int Sdk = 0, string Release = "")
{
    public string Display =>
        $"{(IsWireless ? "WiFi " : "USB  ")}{Serial}" +
        (string.IsNullOrWhiteSpace(Model) ? "" : $"  ({Model})");
}

// Thin wrapper over adb. adb is resolved next to the executable first, then on
// PATH, so the published package can ship its own copy of platform-tools.
public static class Adb
{
    public static string ResolvePath()
    {
        var local = Path.Combine(AppContext.BaseDirectory, "adb.exe");
        if (File.Exists(local))
        {
            return local;
        }
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim(), "adb.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch (ArgumentException)
            {
                // malformed PATH entry
            }
        }
        return "adb";
    }

    public static async Task<(int code, string output)> RunAsync(string args,
                                                                 int timeoutMs = 20000)
    {
        var psi = new ProcessStartInfo
        {
            FileName = ResolvePath(),
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        using var p = Process.Start(psi)!;
        var so = p.StandardOutput.ReadToEndAsync();
        var se = p.StandardError.ReadToEndAsync();
        using var cts = new CancellationTokenSource(timeoutMs);
        try
        {
            await p.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            try { p.Kill(entireProcessTree: true); } catch { /* already gone */ }
            return (-1, $"adb {args} timed out");
        }
        return (p.ExitCode, $"{await so}\n{await se}".Trim());
    }

    public static async Task<List<AndroidDevice>> ListDevicesAsync()
    {
        var list = new List<AndroidDevice>();
        var (code, output) = await RunAsync("devices -l");
        if (code != 0)
        {
            return list;
        }
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("List of devices")
                                  || line.Contains("* daemon"))
            {
                continue;
            }
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2)
            {
                continue;
            }
            var serial = parts[0];
            var state = parts[1];
            var model = "";
            foreach (var kv in parts.Skip(2))
            {
                if (kv.StartsWith("device:"))
                {
                    model = kv[7..];
                }
                else if (kv.StartsWith("product:"))
                {
                    model = kv[8..];
                }
            }
            // wireless ADB devices are addressed as ip:port (or the mns name)
            var wireless = serial.Contains(':') || serial.Contains("-local.");
            list.Add(new AndroidDevice(serial, model, state, wireless));
        }

        // Android 13+ advertises devices over mDNS even before connecting
        var (_, mdns) = await RunAsync("mdns services", 6000);
        foreach (var raw in mdns.Split('\n'))
        {
            var line = raw.Trim();
            if (!line.Contains("_adb-tls-connect._tcp"))
            {
                continue;
            }
            var parts = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 3)
            {
                var addr = parts[^1];
                if (!list.Any(d => d.Serial == addr))
                {
                    list.Add(new AndroidDevice(addr, "mdns", "offline", true));
                }
            }
        }
        return list;
    }

    public static async Task<string> GetDevicePropAsync(string serial, string prop)
    {
        var (code, output) = await RunAsync($"-s {serial} shell getprop {prop}");
        return code == 0 ? output.Trim() : "";
    }

    // connect/pair only talk to a device that is already listening on TCP; they
    // change host-side transport, never the device. Switching the device into
    // TCP mode would be a transport write, and §4.2 forbids this launcher from
    // writing to the device -- see README_GAMING.md §7 for the manual procedure.
    public static Task<(int code, string output)> ConnectAsync(string hostPort) =>
        RunAsync($"connect {hostPort}", 15000);

    public static Task<(int code, string output)> PairAsync(string hostPort, string code6) =>
        RunAsync($"pair {hostPort} {code6}", 30000);
}

public static class ProfileStore
{
    public static string Root =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                     "GamingScrcpy");

    public static string ProfilesDir => Path.Combine(Root, "profiles");
    public static string KeymapsDir => Path.Combine(Root, "keymaps");
    public static string RecordingsDir => Path.Combine(Root, "recordings");
    // the file the client's filter panel reads and writes (v3 §5.4)
    public static string FilterProfilesPath => Path.Combine(Root, "filters.profiles");

    // The panel keeps its profiles in one file; a session profile carries the
    // same lines inside its JSON. Seeding happens before every launch so a
    // loaded session restores the grades the user saved with it, and only
    // overwrites the file when the session actually has some.
    public static void SeedFilterProfiles(AppConfig cfg)
    {
        if (cfg.FilterProfiles.Count == 0)
        {
            return;
        }
        var want = string.Join('\n', cfg.FilterProfiles) + '\n';
        if (File.Exists(FilterProfilesPath)
                && File.ReadAllText(FilterProfilesPath) == want)
        {
            return;
        }
        File.WriteAllText(FilterProfilesPath, want);
    }

    public static List<string> HarvestFilterProfiles() =>
        File.Exists(FilterProfilesPath)
            ? File.ReadAllLines(FilterProfilesPath)
                 .Where(l => !string.IsNullOrWhiteSpace(l) && !l.StartsWith('#'))
                 .Select(l => l.Trim())
                 .ToList()
            : new List<string>();

    static ProfileStore()
    {
        Directory.CreateDirectory(ProfilesDir);
        Directory.CreateDirectory(KeymapsDir);
        Directory.CreateDirectory(RecordingsDir);
    }

    public static IEnumerable<string> ListProfiles() =>
        Directory.EnumerateFiles(ProfilesDir, "*.json").Order().Select(Path.GetFileName)!;

    public static IEnumerable<string> ListKeymaps() =>
        Directory.EnumerateFiles(KeymapsDir, "*.json").Order().Select(Path.GetFileName)!;

    public static AppConfig? LoadProfile(string file)
    {
        var path = Path.Combine(ProfilesDir, file);
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            return JsonSerializer.Deserialize<AppConfig>(
                File.ReadAllText(path),
                new JsonSerializerOptions { ReadCommentHandling = JsonCommentHandling.Skip,
                                            AllowTrailingCommas = true });
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static void SaveProfile(AppConfig cfg)
    {
        var safe = string.Join("-", cfg.Name.Split(Path.GetInvalidFileNameChars()));
        var path = Path.Combine(ProfilesDir, safe + ".json");
        File.WriteAllText(path, JsonSerializer.Serialize(cfg,
            new JsonSerializerOptions { WriteIndented = true }));
    }

    public static Keymap? LoadKeymap(string file)
    {
        var path = Path.Combine(KeymapsDir, file);
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            return JsonSerializer.Deserialize<Keymap>(File.ReadAllText(path),
                new JsonSerializerOptions { AllowTrailingCommas = true });
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static void SeedDefaults()
    {
        if (!Directory.EnumerateFiles(ProfilesDir, "*.json").Any())
        {
            foreach (var p in BuiltinProfiles())
            {
                SaveProfile(p);
            }
        }
        if (!Directory.EnumerateFiles(KeymapsDir, "*.json").Any())
        {
            foreach (var k in BuiltinKeymaps())
            {
                var safe = string.Join("-", k.Name.Split(Path.GetInvalidFileNameChars()));
                File.WriteAllText(Path.Combine(KeymapsDir, safe + ".json"),
                    JsonSerializer.Serialize(k, new JsonSerializerOptions
                    { WriteIndented = true }));
            }
        }
    }

    public static IEnumerable<AppConfig> BuiltinProfiles()
    {
        // ---- the six profiles added by directive v2 §F ----
        // Every one of them is checked against the real scrcpy.exe by
        // --validate-profiles, and the ones that can be measured on the attached
        // tablet are (BUILD_REPORT.md). None of them sets --max-size, --crop or
        // a display id: the device keeps rendering at its own resolution.
        yield return new AppConfig
        {
            Name = "Lowest latency",
            Notes = "Native device resolution, no video buffer at all, "
                  + "encoder asked for its lowest-latency setting. Watch the OSD "
                  + "for the measured recv->present figure.",
            VideoCodec = "h264",
            BitrateMbps = 20,
            MaxFps = 60,
            VideoBufferMs = 0,
            EncoderPreset = "ultrafast",
            AudioOutputBufferMs = 40,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            LowLatency = true,
            Osd = "full",
        };
        yield return new AppConfig
        {
            Name = "Competitive 120 (host scale)",
            Notes = "120 fps at a modest bitrate; the picture is shrunk on the PC "
                  + "by the window itself, never on the device, so touch alignment "
                  + "stays exact. Use --game-bridge-scale if OBS needs a 720p feed.",
            VideoCodec = "h264",
            BitrateMbps = 20,
            MaxFps = 120,
            VideoBufferMs = 0,
            EncoderPreset = "ultrafast",
            AudioOutputBufferMs = 40,
            RenderDriver = "direct3d11",
            Upscale = "nearest",
            WindowFilter = "fast",
            HostPreset = "1080p",
            LowLatency = true,
            Osd = "full",
        };
        yield return new AppConfig
        {
            Name = "Balanced HEVC 60",
            Notes = "Native capture, HEVC at 40 Mb/s: the middle ground for "
                  + "mirroring and recording at the same time.",
            VideoCodec = "hevc",
            BitrateMbps = 40,
            MaxFps = 60,
            VideoBufferMs = 0,
            EncoderPreset = "fast",
            AudioCodec = "opus",
            AudioBitrateKbps = 128,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            LowLatency = true,
            Osd = "compact",
        };
        yield return new AppConfig
        {
            Name = "Recording only (clean)",
            Notes = "No OSD, no overlay, no post-processing: the recording is the "
                  + "picture. High bitrate into Matroska.",
            VideoCodec = "h265",
            BitrateMbps = 60,
            MaxFps = 60,
            Container = "mkv",
            AudioCodec = "opus",
            AudioBitrateKbps = 192,
            Osd = "none",
            TouchVisualizer = false,
            FxSharp = false,
            FxNight = false,
            FxSat = false,
            Upscale = "linear",
        };
        yield return new AppConfig
        {
            Name = "Stream OBS (pipes)",
            Notes = "Frame + audio + decoded PCM on named pipes so OBS takes raw "
                  + "frames instead of a window capture, and the PC speakers stay "
                  + "free. NOTE: --game-borderless-fullscreen currently reverts to "
                  + "a normal window on the first frame (known issue in README).",
            VideoCodec = "h264",
            BitrateMbps = 30,
            MaxFps = 60,
            VideoBufferMs = 0,
            EncoderPreset = "ultrafast",
            RenderDriver = "direct3d11",
            Upscale = "linear",
            LowLatency = true,
            AlwaysOnTop = true,
            Osd = "none",
            FrameBridge = @"\\.\pipe\gaming-frame",
            BridgeFilter = "lanczos",
            AudioBridge = @"\\.\pipe\gaming-audio",
            AudioPcm = @"\\.\pipe\gaming-pcm",
            PcmMutePlayback = true,
            AudioCodec = "raw",
        };
        yield return new AppConfig
        {
            Name = "Wi-Fi low bandwidth",
            Notes = "For a wireless link: HEVC, low bitrate, 30 fps. Select the "
                  + "ip:port device in the header first (README section 7 explains "
                  + "how to put the device on Wi-Fi by hand).",
            VideoCodec = "hevc",
            BitrateMbps = 8,
            MaxFps = 30,
            VideoBufferMs = 50,
            AudioCodec = "opus",
            AudioBitrateKbps = 64,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            Osd = "compact",
        };
        yield return new AppConfig
        {
            Name = "Competitive COD Mobile 120FPS",
            Notes = "High frame rate, tight bitrate, low-latency presentation, "
                  + "sharpening on for enemy silhouettes.",
            VideoCodec = "h264",
            BitrateMbps = 12,
            MaxFps = 120,
            VideoBufferMs = 0,
            AudioOutputBufferMs = 60,
            RenderDriver = "direct3d11",
            Upscale = "pixelart",
            LowLatency = true,
            BorderlessFullscreen = true,
            Osd = "full",
            CursorAutohideMs = 1500,
            FxSharp = true,
            Sharpness = 45,
            MouseMode = "uhid",
            TouchVisualizer = false,
        };
        yield return new AppConfig
        {
            Name = "4K Ultra Quality Stream 60FPS",
            Notes = "OBS window capture target: borderless fullscreen, always on "
                  + "top, highest quality upscale, no post-processing latency.",
            VideoCodec = "av1",
            BitrateMbps = 48,
            MaxFps = 60,
            AudioCodec = "opus",
            AudioBitrateKbps = 160,
            RenderDriver = "direct3d11",
            Upscale = "pixelart",
            Mipmaps = true,
            Osd = "compact",
            BorderlessFullscreen = true,
            AlwaysOnTop = true,
            // a Lanczos-resampled 4K feed on the bridge thread, so OBS can take
            // the raw frames instead of a window capture
            FrameBridge = @"\\.\pipe\gaming-frame",
            BridgeScale = "3840x2160",
            BridgeFilter = "lanczos",

            Record = false,
        };
        yield return new AppConfig
        {
            Name = "Recording Only",
            Notes = "Dual mode: mirror live while the device stream is muxed "
                  + "losslessly to disk without re-encoding.",
            VideoCodec = "h265",
            BitrateMbps = 80,
            MaxFps = 60,
            Record = true,
            Container = "mkv",
            Osd = "full",
            FxSharp = true, FxSat = true,
            Sharpness = 30,
            Saturation = 115,
        };
        yield return new AppConfig
        {
            Name = "Night/Dark Game Boost",
            Notes = "Competitive shooters with dark maps: shadow lift plus "
                  + "moderate sharpening. Costs host CPU, watch the OSD frame time.",
            VideoCodec = "h264",
            BitrateMbps = 16,
            MaxFps = 90,
            Upscale = "linear",            FxNight = true, FxSharp = true,
            NightBoost = 45,
            Sharpness = 25,
            Osd = "full",
        };
    }

    public static IEnumerable<Keymap> BuiltinKeymaps()
    {
        yield return new Keymap
        {
            Name = "KB-M Mouse Aim (COD/PUBG)",
            KeyboardMode = "sdk",
            MouseMode = "uhid",
            ShortcutMod = "lctrl",
            Bindings = new List<KeyBinding>
            {
                new() { Key = "W", Action = "Stick forward", Note = "mouse aim = screen pointer" },
                new() { Key = "Mouse1", Action = "Fire", Note = "aim with the pointer, --mouse=uhid" },
                new() { Key = "Mouse2", Action = "Aim", Note = "right click" },
                new() { Key = "R", Action = "Reload" },
                new() { Key = "Space", Action = "Jump" },
            },
        };
        yield return new Keymap
        {
            Name = "Gamepad (U-HID)",
            KeyboardMode = "sdk",
            MouseMode = "auto",
            GamepadMode = "uhid",
            Bindings = new List<KeyBinding>
            {
                new() { Key = "LS/RJ", Action = "Move" },
                new() { Key = "RT", Action = "Fire" },
                new() { Key = "LT", Action = "Aim" },
            },
        };
    }
}

public sealed class Keymap
{
    public string Name { get; set; } = "";
    public string KeyboardMode { get; set; } = "auto";
    public string MouseMode { get; set; } = "auto";
    public string GamepadMode { get; set; } = "auto";
    public string ShortcutMod { get; set; } = "s+cc";
    public string MouseBindings { get; set; } = "";
    public List<KeyBinding> Bindings { get; set; } = new();
}

public sealed class KeyBinding
{
    public string Key { get; set; } = "";
    public string Action { get; set; } = "";
    public string Note { get; set; } = "";
}
