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

// One profile as the header selector and the Perfiles table show it: the file
// it came from (so a row can be edited, duplicated or deleted) and the seven
// cells already rendered in the reader's language.
public sealed record ProfileEntry(string File, string Display, string Fps, string Resolution,
                                  string Bitrate, string Codec, string Latency)
{
    public AppConfig? Config => ProfileStore.LoadProfile(File);
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

    // The rows both profile pickers show, already in the reader's language: a
    // language switch only has to call this again.
    public static List<ProfileEntry> ListEntries()
    {
        var rows = new List<ProfileEntry>();
        foreach (var file in ListProfiles())
        {
            if (LoadProfile(file) is not { } cfg)
            {
                continue;
            }
            rows.Add(new ProfileEntry(file, cfg.DisplayName,
                Loc.Format("UnitFps", cfg.MaxFps),
                string.IsNullOrWhiteSpace(cfg.HostCapLabel)
                    ? Loc.T("ProfResNative") : cfg.HostCapLabel,
                Loc.Format("UnitMbps", cfg.BitrateMbps),
                cfg.CodecLabel,
                Loc.Format("UnitMs", cfg.ExpectedLatencyMs)));
        }
        return rows;
    }

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

    public static string SafeFileName(string name) =>
        string.Join("-", name.Split(Path.GetInvalidFileNameChars()));

    public static void SaveProfile(AppConfig cfg)
    {
        var path = Path.Combine(ProfilesDir, SafeFileName(cfg.Name) + ".json");
        File.WriteAllText(path, JsonSerializer.Serialize(cfg,
            new JsonSerializerOptions { WriteIndented = true }));
    }

    public static string ProfilePath(string name) =>
        Path.Combine(ProfilesDir, SafeFileName(name) + ".json");

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
        // Seeding is per profile, not "only when the folder is empty": a build
        // that adds presets has to deliver them to an install that already has
        // files, while leaving the ones the user edited alone.
        foreach (var p in BuiltinProfiles())
        {
            if (!File.Exists(ProfilePath(p.Name)))
            {
                SaveProfile(p);
                continue;
            }
            var stored = LoadProfile(Path.GetFileName(ProfilePath(p.Name)));
            // An older copy carries no localized text. The builtin table supplies
            // it once, and only the two display fields: whatever the user set
            // for fps, bitrate or buffers stays exactly as it was.
            if (stored != null && string.IsNullOrWhiteSpace(stored.NameEs)
                    && !string.IsNullOrWhiteSpace(p.NameEs))
            {
                stored.NameEs = p.NameEs;
                if (string.IsNullOrWhiteSpace(stored.NotesEs))
                {
                    stored.NotesEs = p.NotesEs;
                }
                SaveProfile(stored);
            }
        }
        if (!Directory.EnumerateFiles(KeymapsDir, "*.json").Any())
        {
            foreach (var k in BuiltinKeymaps())
            {
                File.WriteAllText(Path.Combine(KeymapsDir, SafeFileName(k.Name) + ".json"),
                    JsonSerializer.Serialize(k, new JsonSerializerOptions
                    { WriteIndented = true }));
            }
        }
    }

    // "Restaurar perfiles por defecto": the builtin table wins over the stored
    // copies again, which is also how a user gets back a preset they deleted.
    public static int RestoreBuiltinProfiles()
    {
        var n = 0;
        foreach (var p in BuiltinProfiles())
        {
            SaveProfile(p);
            ++n;
        }
        return n;
    }

    // The shipped presets. Directive v4 §3: twenty of them, every one with a
    // Spanish display name and a description in both languages.
    //
    // "Name" is the identity: it keys the JSON file in
    // %APPDATA%\GamingScrcpy\profiles, so it stays exactly as it was even where
    // the label the user reads is now Spanish.
    //
    // The sizes inside the names (720p, 1080p, 1440p, 4K) are always a
    // client-side maximum -- the host window, or the bridge scale -- never a
    // device-side change: no profile here resizes, crops or picks a display on
    // the phone, which is the constraint gate section 13 of tools/verify_all.sh
    // reads out of these sources.
    public static IEnumerable<AppConfig> BuiltinProfiles()
    {
        // ---- the ten profiles shipped since directive v2 §F ----
        yield return new AppConfig
        {
            Name = "Lowest latency",
            NameEs = "Latencia mínima",
            Notes = "Mirror at 60 fps, h264 at 20 Mb/s and a 0 ms video buffer: the "
                  + "device encoder is asked for its lowest-latency setting and the PC "
                  + "adds none. The picture comes from the phone's own resolution, which "
                  + "nothing here changes. Full OSD shows the measured recv->present figure.",
            NotesEs = "Espejo a 60 fps con h264 a 20 Mb/s y búfer de vídeo de 0 ms: se pide "
                    + "al codificador del dispositivo su menor latencia y el PC no añade "
                    + "ninguna. La imagen sale de la resolución nativa del teléfono, que "
                    + "nada de esto modifica. El OSD completo deja ver la latencia medida.",
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
            NameEs = "Competitivo 120 (escala del PC)",
            Notes = "120 fps at 20 Mb/s in h264 with no video buffer. The picture is "
                  + "shrunk on the PC by the 1920x1080 window itself, never on the "
                  + "device, so touch alignment stays exact. Use the bridge scale if OBS "
                  + "needs a 720p feed.",
            NotesEs = "120 fps a 20 Mb/s en h264 y sin búfer de vídeo. La imagen se reduce "
                    + "en el PC, dentro de la ventana de 1920x1080, nunca en el "
                    + "dispositivo, así la alineación del tacto sigue siendo exacta. Usa "
                    + "la escala del puente si OBS necesita una señal a 720p.",
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
            NameEs = "Balanceado HEVC 60",
            Notes = "Native capture at 60 fps, HEVC at 40 Mb/s and no video buffer: the "
                  + "middle ground for mirroring and recording at the same time, with "
                  + "opus at 128 kb/s. The phone keeps its own resolution.",
            NotesEs = "Captura nativa a 60 fps con HEVC a 40 Mb/s y búfer de vídeo en 0 "
                    + "ms: el punto medio para ver y grabar a la vez, con opus a 128 kb/s. "
                    + "El teléfono conserva su resolución.",
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
            NameEs = "Solo grabación (limpio)",
            Notes = "60 fps, h265 at 60 Mb/s into Matroska, opus at 192 kb/s. No OSD, no "
                  + "filter panel, no post-processing: the recording is the picture, and "
                  + "the device still renders at its native size.",
            NotesEs = "60 fps con h265 a 60 Mb/s dentro de un MKV y opus a 192 kb/s. Sin "
                    + "OSD, sin panel de filtros y sin posprocesado: la grabación es la "
                    + "imagen, y el dispositivo sigue dibujando en su tamaño nativo.",
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
            NameEs = "Stream OBS (pipe)",
            Notes = "60 fps, h264 at 30 Mb/s, ultrafast encoder and no video buffer. "
                  + "Frame, audio and decoded PCM go out on named pipes so OBS takes raw "
                  + "frames instead of a window capture, and the PC speakers stay free. "
                  + "NOTE: --game-borderless-fullscreen currently reverts to a normal "
                  + "window on the first frame (known issue in README).",
            NotesEs = "60 fps con h264 a 30 Mb/s, codificador ultrafast y búfer de vídeo "
                    + "en 0 ms. El fotograma, el audio y el PCM decodificado salen por "
                    + "tuberías con nombre para que OBS tome frames crudos en vez de "
                    + "capturar la ventana, y los altavoces del PC quedan libres. OJO: la "
                    + "pantalla completa sin bordes vuelve a ventana normal con el primer "
                    + "fotograma (limitación descrita en el README).",
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
            NameEs = "Wi-Fi bajo consumo",
            Notes = "For a wireless link: 30 fps, HEVC at 8 Mb/s and a 50 ms video "
                  + "buffer, so the stream only asks for the bandwidth the link can "
                  + "carry, with opus at 64 kb/s. Select the ip:port device in the "
                  + "header first (README section 7 explains how to put the device on "
                  + "Wi-Fi by hand).",
            NotesEs = "Para un enlace sin hilos: 30 fps, HEVC a 8 Mb/s y 50 ms de búfer "
                    + "de vídeo, de forma que la señal solo pide el ancho que el enlace "
                    + "puede llevar, con opus a 64 kb/s. Elige antes el dispositivo "
                    + "ip:puerto en la cabecera (la sección 7 del README cuenta cómo "
                    + "poner el teléfono en Wi-Fi a mano).",
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
            NameEs = "Competitivo COD Mobile 120fps",
            Notes = "120 fps at 12 Mb/s in h264, no video buffer, uhid mouse, "
                  + "borderless fullscreen and a 60 ms audio output buffer. Sharpening "
                  + "at 45 helps enemy silhouettes and costs host CPU on the frame path; "
                  + "the resolution stays the device's own.",
            NotesEs = "120 fps a 12 Mb/s en h264, sin búfer de vídeo, ratón uhid, pantalla "
                    + "completa sin bordes y 60 ms de búfer de salida de audio. El realce "
                    + "a 45 ayuda a ver siluetas y cuesta CPU del PC en el camino del "
                    + "frame; la resolución sigue siendo la del dispositivo.",
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
            NameEs = "4K ultra calidad 60fps",
            Notes = "AV1 at 60 fps and 48 Mb/s with opus at 160 kb/s. The 4K here is the "
                  + "3840x2160 the frame bridge resamples to for OBS: a client-side "
                  + "maximum only. The phone keeps its native panel resolution and this "
                  + "profile never changes it. Borderless and always on top make it an "
                  + "OBS window-capture target.",
            NotesEs = "AV1 a 60 fps y 48 Mb/s con opus de 160 kb/s. El 4K de este perfil "
                    + "es el 3840x2160 al que remuestrea el puente de frames para OBS: "
                    + "solo un máximo puesto en el cliente. El teléfono conserva la "
                    + "resolución nativa de su panel y aquí no se cambia. Sin bordes y "
                    + "siempre encima para que OBS lo capture como ventana.",
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
            NameEs = "Solo grabación",
            Notes = "Dual mode at 60 fps: the mirror stays live while the device's own "
                  + "h265 stream at 80 Mb/s is muxed losslessly to Matroska without "
                  + "re-encoding. The host filters only change what the PC shows, never "
                  + "what the file holds.",
            NotesEs = "Modo doble a 60 fps: el espejo sigue en vivo mientras el h265 del "
                    + "dispositivo, a 80 Mb/s, se multiplexa en un MKV sin recodificar. "
                    + "Los filtros del PC cambian lo que ves, nunca lo que guarda el "
                    + "archivo.",
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
            NameEs = "Realce para juegos oscuros",
            Notes = "90 fps in h264 at 16 Mb/s with the shadow lift at 45 and "
                  + "sharpening at 25. It costs host CPU on the frame path, so watch the "
                  + "OSD frame time; the device still renders its own resolution.",
            NotesEs = "90 fps en h264 a 16 Mb/s con el levantado de sombras a 45 y el "
                    + "realce a 25. Cuesta CPU del PC en el camino del frame, así que "
                    + "mira el tiempo por fotograma del OSD; el dispositivo sigue "
                    + "dibujando su resolución.",
            VideoCodec = "h264",
            BitrateMbps = 16,
            MaxFps = 90,
            Upscale = "linear",
            FxNight = true, FxSharp = true,
            NightBoost = 45,
            Sharpness = 25,
            Osd = "full",
        };

        // ---- the ten latency / fluidity presets added by directive v4 §3 ----
        // Every numeric value below is one of the discrete steps the configurator
        // can produce (MainWindow.xaml.cs: FpsSteps, BitrateSteps,
        // VideoBufferSteps), and each profile is run against the real scrcpy.exe
        // by --validate-profiles and by tools/profiles_check.sh.
        yield return new AppConfig
        {
            Name = "Lowest latency USB 60",
            NameEs = "Latencia mínima (USB)",
            Notes = "USB mirror at 60 fps: h264 at 30 Mb/s, zero video buffer, the "
                  + "encoder asked for its lowest latency and the presentation running "
                  + "without vsync. Nothing is scaled or cropped: the phone sends its "
                  + "native resolution. Needs the phone on USB, not on Wi-Fi.",
            NotesEs = "Espejo por USB a 60 fps: h264 a 30 Mb/s, búfer de vídeo en 0 ms, "
                    + "el codificador pedido para su menor latencia y la presentación sin "
                    + "vsync. No se escala ni se recorta nada: el teléfono envía su "
                    + "resolución nativa. Requiere el teléfono conectado por USB, no por "
                    + "Wi-Fi.",
            VideoCodec = "h264",
            BitrateMbps = 30,
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
            Name = "Lowest latency 120",
            NameEs = "Latencia mínima 120fps",
            Notes = "120 fps at 40 Mb/s in h264, no buffer at all and the encoder at its "
                  + "fastest bias. It asks for a USB 3.0 port and a panel that really "
                  + "runs at 120 Hz. The device keeps its native resolution; the full OSD "
                  + "is where you check the frames actually arrive.",
            NotesEs = "120 fps a 40 Mb/s en h264, sin ningún búfer y con el codificador "
                    + "en su ajuste más rápido. Pide un puerto USB 3.0 y un panel que "
                    + "llegue de verdad a 120 Hz. El dispositivo conserva su resolución "
                    + "nativa; el OSD completo es donde se comprueba que los frames "
                    + "llegan.",
            VideoCodec = "h264",
            BitrateMbps = 40,
            MaxFps = 120,
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
            Name = "Maximum fluidity 120",
            NameEs = "Fluidez máxima 120fps",
            Notes = "Frames before pixels: 120 fps in h264 at 25 Mb/s with a 0 ms video "
                  + "buffer. The 1080p in this profile is the host window it opens, a "
                  + "client-side maximum; the phone's framebuffer is never resized, so "
                  + "touch stays aligned.",
            NotesEs = "Primero los frames, después los píxeles: 120 fps en h264 a 25 Mb/s "
                    + "con búfer de vídeo de 0 ms. El 1080p de este perfil es la ventana "
                    + "del PC que abre, un máximo puesto en el cliente; el búfer del "
                    + "teléfono no se remuestrea, así el tacto sigue alineado.",
            VideoCodec = "h264",
            BitrateMbps = 25,
            MaxFps = 120,
            VideoBufferMs = 0,
            EncoderPreset = "ultrafast",
            AudioOutputBufferMs = 40,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            HostPreset = "1080p",
            LowLatency = true,
            Osd = "compact",
        };
        yield return new AppConfig
        {
            Name = "Maximum fluidity 90",
            NameEs = "Fluidez máxima 90fps",
            Notes = "90 fps is what most phone encoders hold without dropping frames, so "
                  + "this is the compatible fluidity: h264 at 20 Mb/s, 0 ms video buffer, "
                  + "host window capped at 1920x1080. The device keeps its own "
                  + "resolution.",
            NotesEs = "90 fps es lo que la mayoría de codificadores de teléfono sostienen "
                    + "sin soltar frames: es la fluidez compatible. h264 a 20 Mb/s, búfer "
                    + "de vídeo en 0 ms y ventana del PC limitada a 1920x1080. El "
                    + "dispositivo conserva su resolución.",
            VideoCodec = "h264",
            BitrateMbps = 20,
            MaxFps = 90,
            VideoBufferMs = 0,
            EncoderPreset = "ultrafast",
            AudioOutputBufferMs = 60,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            HostPreset = "1080p",
            LowLatency = true,
            Osd = "compact",
        };
        yield return new AppConfig
        {
            Name = "Quality 60",
            NameEs = "60fps calidad",
            Notes = "The quality side of 60 fps: h265 at 40 Mb/s from the device's native "
                  + "resolution, a 30 ms video buffer so a busy encoder does not show as "
                  + "stutter, and the encoder biased to quality rather than speed. Opus "
                  + "at 160 kb/s.",
            NotesEs = "La cara de calidad de los 60 fps: h265 a 40 Mb/s desde la "
                    + "resolución nativa del teléfono, 30 ms de búfer de vídeo para que "
                    + "un codificador saturado no se vea como cortes y el codificador "
                    + "inclinado a la calidad en vez de a la velocidad. Audio opus a 160 "
                    + "kb/s.",
            VideoCodec = "h265",
            BitrateMbps = 40,
            MaxFps = 60,
            VideoBufferMs = 30,
            EncoderPreset = "medium",
            AudioCodec = "opus",
            AudioBitrateKbps = 160,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            LowLatency = true,
            Osd = "compact",
        };
        yield return new AppConfig
        {
            Name = "Competitive 720p 120",
            NameEs = "720p 120fps competitivo",
            Notes = "120 fps at 15 Mb/s in h264 with no buffer, sized for a Wi-Fi 6 link. "
                  + "The 720p is the host window it opens (1280x720), a client-side "
                  + "maximum only: the phone still captures its native panel, so the "
                  + "encoder has fewer bits to push and the latency budget stays intact.",
            NotesEs = "120 fps a 15 Mb/s en h264 sin búfer, pensado para un enlace Wi-Fi "
                    + "6. El 720p es la ventana del PC que abre (1280x720), solo un máximo "
                    + "del cliente: el teléfono sigue capturando su panel nativo, así el "
                    + "codificador tiene menos bits que empujar y el presupuesto de "
                    + "latencia se mantiene.",
            VideoCodec = "h264",
            BitrateMbps = 15,
            MaxFps = 120,
            VideoBufferMs = 0,
            EncoderPreset = "ultrafast",
            AudioOutputBufferMs = 40,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            HostWidth = 1280,
            HostHeight = 720,
            LowLatency = true,
            Osd = "full",
        };
        yield return new AppConfig
        {
            Name = "Balanced 1080p 60",
            NameEs = "1080p 60fps balanceado",
            Notes = "General use at 60 fps: h265 at 30 Mb/s, a 30 ms video buffer, opus "
                  + "audio and the window sized to 1920x1080 on the PC. That 1080p is a "
                  + "host-side maximum, not a change on the device, which keeps its own "
                  + "panel resolution.",
            NotesEs = "Para uso general a 60 fps: h265 a 30 Mb/s, búfer de vídeo de 30 ms, "
                    + "audio opus y ventana del PC ajustada a 1920x1080. Ese 1080p es un "
                    + "máximo del lado del PC, no un cambio en el dispositivo, que "
                    + "conserva la resolución de su panel.",
            VideoCodec = "h265",
            BitrateMbps = 30,
            MaxFps = 60,
            VideoBufferMs = 30,
            EncoderPreset = "fast",
            AudioCodec = "opus",
            AudioBitrateKbps = 128,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            HostPreset = "1080p",
            LowLatency = true,
            Osd = "compact",
        };
        yield return new AppConfig
        {
            Name = "4K maximum quality",
            NameEs = "4K máxima calidad",
            Notes = "60 fps at 80 Mb/s in h265 with a 50 ms video buffer and the window "
                  + "sized to 3840x2160 on the PC. The 4K is that client-side maximum: "
                  + "the phone is not resized and keeps its own panel resolution. Needs a "
                  + "good USB cable.",
            NotesEs = "60 fps a 80 Mb/s en h265 con 50 ms de búfer de vídeo y ventana del "
                    + "PC de 3840x2160. El 4K es ese máximo puesto en el cliente: el "
                    + "teléfono no se remuestrea y conserva la resolución de su panel. "
                    + "Pide un buen cable USB.",
            VideoCodec = "h265",
            BitrateMbps = 80,
            MaxFps = 60,
            VideoBufferMs = 50,
            EncoderPreset = "medium",
            AudioCodec = "opus",
            AudioBitrateKbps = 192,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            HostPreset = "4k",
            LowLatency = true,
            Osd = "compact",
        };
        yield return new AppConfig
        {
            Name = "4K 30fps recording",
            NameEs = "4K 30fps grabación",
            Notes = "Archival recording at 30 fps: h265 at 60 Mb/s muxed into Matroska, "
                  + "100 ms of video buffer and no OSD in the picture. The 4K label is the "
                  + "3840x2160 host window only; the device is captured at its own panel "
                  + "resolution and never resized.",
            NotesEs = "Grabación de archivo a 30 fps: h265 a 60 Mb/s dentro de un MKV, 100 "
                    + "ms de búfer de vídeo y sin OSD en la imagen. La etiqueta 4K es solo "
                    + "la ventana del PC de 3840x2160; el dispositivo se captura en la "
                    + "resolución de su panel y no se remuestrea.",
            VideoCodec = "h265",
            BitrateMbps = 60,
            MaxFps = 30,
            VideoBufferMs = 100,
            EncoderPreset = "medium",
            AudioCodec = "opus",
            AudioBitrateKbps = 256,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            HostPreset = "4k",
            LowLatency = false,
            Record = true,
            Container = "mkv",
            Osd = "none",
        };
        yield return new AppConfig
        {
            Name = "1440p 60",
            NameEs = "1440p 60fps",
            Notes = "h265 at 50 Mb/s and 60 fps with a 30 ms buffer and the window sized "
                  + "to 2560x1440 on the PC: the sweet spot directive v4 asks for on the "
                  + "S23 Ultra. That 1440p is the client-side maximum, not a resolution "
                  + "change on the phone, which keeps sending its own panel.",
            NotesEs = "h265 a 50 Mb/s y 60 fps con 30 ms de búfer y ventana del PC de "
                    + "2560x1440: el punto dulce que la directriz v4 pide para el S23 "
                    + "Ultra. Ese 1440p es el máximo del cliente, no un cambio de "
                    + "resolución del teléfono, que sigue enviando la de su panel.",
            VideoCodec = "h265",
            BitrateMbps = 50,
            MaxFps = 60,
            VideoBufferMs = 30,
            EncoderPreset = "fast",
            AudioCodec = "opus",
            AudioBitrateKbps = 160,
            RenderDriver = "direct3d11",
            Upscale = "linear",
            HostPreset = "1440p",
            LowLatency = true,
            Osd = "compact",
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
