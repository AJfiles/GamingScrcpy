using System.Diagnostics;
using System.IO;
using System.Windows;

namespace GamingScrcpyLauncher;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // headless self-test: build every seeded profile's command line and let
        // the real scrcpy binary parse it (--version short-circuits after
        // argument validation, so no device is needed)
        if (e.Args.Contains("--validate-profiles"))
        {
            ValidateProfiles();
            Shutdown();
            return;
        }
        if (e.Args.Contains("--validate-shortcuts"))
        {
            ValidateShortcuts(e.Args);
            Shutdown();
            return;
        }
        if (e.Args.Contains("--dump-profile-args"))
        {
            DumpProfileArgs(e.Args);
            Shutdown();
            return;
        }
        base.OnStartup(e);
        ApplyMotionPreference();
    }

    // v4 §5.2 gate §23: an animation the user cannot turn off is not a polish
    // detail but an accessibility defect, and Windows already exposes the switch
    // ("Show animations in Windows"). Every duration in the theme lives under an
    // Anim* key, so honouring the setting is this loop and nothing else: the
    // storyboards still run, they just finish at once.
    private static void ApplyMotionPreference()
    {
        if (SystemParameters.ClientAreaAnimation)
        {
            return;
        }
        var zero = new Duration(TimeSpan.Zero);
        foreach (var key in new[] { "AnimTab", "AnimPanel", "AnimOverlay",
                                    "AnimHover", "AnimCombo", "AnimHighlight" })
        {
            Current.Resources[key] = zero;
        }
    }

    // v4 §6.1: the on-device profile sweep has to run the command line a session
    // really uses. Hand-copying fps/codec/bitrate into the test would measure the
    // copy, so the launcher writes the argv itself and the harness only supplies
    // the serial. One record per profile, ASCII, no shell quoting traps: a name
    // line, one `ARG ` line per token (values with spaces keep their own token),
    // then `END`. `__SERIAL__` marks where the device name belongs.
    private static void DumpProfileArgs(string[] args)
    {
        ProfileStore.SeedDefaults();
        foreach (var cfg in ProfileStore.BuiltinProfiles())
        {
            // a bridge or pipe target makes the client wait for a consumer that a
            // plain mirror sweep never starts, so those tokens are not dumped
            var argv = cfg.BuildArguments("__SERIAL__");
            argv.RemoveAll(a => a.Contains(@"\\.\pipe\", StringComparison.Ordinal));
            Console.WriteLine("NAME " + Ascii(cfg.Name));
            foreach (var a in argv)
            {
                Console.WriteLine("ARG " + Ascii(a));
            }
            Console.WriteLine("END");
        }
        Console.WriteLine("DUMP OK n=" + ProfileStore.BuiltinProfiles().Count());
    }

    // v3 §3: the shortcut list is checked by a self-test mode, exactly like the
    // profiles, so the gate can assert both the table and the checker itself
    // (a fixture with a duplicated key has to be reported, not ignored).
    private static void ValidateShortcuts(string[] args)
    {
        IReadOnlyList<ShortcutRow> rows = Shortcuts.Table;
        var file = Array.Find(args, a => a.StartsWith("--shortcuts-file="));
        if (file != null)
        {
            rows = Shortcuts.LoadFile(file["--shortcuts-file=".Length..]);
        }

        var problems = Shortcuts.Validate(rows);
        foreach (var p in problems)
        {
            Console.WriteLine("FAIL " + p);
        }
        if (problems.Count == 0)
        {
            Console.WriteLine($"SHORTCUTS OK rows={rows.Count} categories="
                + System.Linq.Enumerable.Count(Shortcuts.ShownCategories(rows)));
            Environment.ExitCode = 0;
            return;
        }
        Console.WriteLine($"SHORTCUTS FAIL issues={problems.Count}");
        Environment.ExitCode = 1;
    }

    private static void ValidateProfiles()
    {
        ProfileStore.SeedDefaults();
        var exe = GamingScrcpyLauncher.MainWindow.FindScrcpyForSelfTest();
        if (exe == null)
        {
            Console.WriteLine("scrcpy.exe not found for self-test");
            Environment.ExitCode = 2;
            return;
        }
        var failures = 0;
        void Check(AppConfig cfg, string label)
        {
            var (ok, detail, args) = ValidateAgainstBinary(cfg);
            if (!ok)
            {
                ++failures;
            }
            Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {label} {detail}");
            var shown = new List<string>();
            foreach (var a in args)
            {
                // the fork flags plus the few gaming toggles that reuse an
                // upstream token; the rest of the line is the common baseline
                if (a.StartsWith("--game-", StringComparison.Ordinal)
                        || a == "--no-audio-playback"
                        || a == "--turn-screen-off")
                {
                    shown.Add(a);
                }
            }
            Console.WriteLine("      " + (ok
                ? string.Join(" ", shown)
                : "args: " + string.Join(" ", args)));
        }

        // The shipped presets are what a fresh install gets, so they are what
        // this must prove: valid against the real binary, and carrying both
        // localized texts. Stored profiles can be anything the user typed.
        var builtins = ProfileStore.BuiltinProfiles().ToList();
        var noEs = builtins.Count(p => string.IsNullOrWhiteSpace(p.NotesEs));
        var noEn = builtins.Count(p => string.IsNullOrWhiteSpace(p.Notes));
        var noName = builtins.Count(p => string.IsNullOrWhiteSpace(p.NameEs));
        foreach (var cfg in builtins)
        {
            Check(cfg, $"builtin {cfg.Name}");
        }
        Console.WriteLine($"BUILTINS n={builtins.Count} desc_es_missing={noEs} "
                          + $"desc_en_missing={noEn} name_es_missing={noName}");

        // The Spanish label is what the user reads, and what the mirror window is
        // titled with, while "name" stays the key of the stored file. Both halves
        // are only provable by switching the language, so switch it and compare.
        var back = Loc.Instance.Language;
        Loc.Instance.Language = "es";
        var es = builtins.Select(p => (p.Name, p.DisplayName,
                Title: TitleOf(p.BuildArguments("TESTSERIAL")))).ToList();
        Loc.Instance.Language = back;
        var notTranslated = es.Count(x => x.DisplayName == x.Name);
        var wrongTitle = es.Count(x => x.Title != x.DisplayName);
        Console.WriteLine($"SPANISH n={es.Count} display_equals_identity={notTranslated} "
                          + $"window_title_not_display_name={wrongTitle} "
                          + $"example={Ascii(es[0].DisplayName)}");

        // The store is what the launcher really launches from, so what the code
        // declares has to survive the JSON file: a parameter the serializer drops
        // (it writes properties only) would make a saved profile a different
        // profile.
        var lost = builtins.Count(p => !RoundTripKeeps(p));
        Console.WriteLine($"ROUNDTRIP n={builtins.Count} parameters_lost={lost}");

        foreach (var file in ProfileStore.ListProfiles())
        {
            var cfg = ProfileStore.LoadProfile(file);
            if (cfg == null)
            {
                Console.WriteLine($"FAIL {file}: could not parse");
                ++failures;
                continue;
            }
            Check(cfg, file);
        }
        // Not a stored profile: every configurator control pushed to a non-default
        // value, so a token the GUI can emit but scrcpy refuses fails here even if
        // no shipped preset happens to use it.
        Check(new AppConfig
        {
            Name = "synthetic max settings",
            Transport = "tcp",
            VideoCodec = "av1", BitrateMbps = 96, MaxFps = 120, Hwdec = "disabled",
            AudioCodec = "opus", AudioBitrateKbps = 256, AudioSource = "output",
            VideoBufferMs = 200, AudioBufferMs = 200, AudioOutputBufferMs = 500,
            RenderDriver = "vulkan", Upscale = "pixelart", WindowFilter = "lanczos",
            RenderFit = "stretched", Mipmaps = false, LowLatency = true,
            BorderlessFullscreen = true, AlwaysOnTop = true, Osd = "full",
            CursorAutohideMs = 60000, HostPreset = "4k",
            FxSharp = true, FxNight = true, FxSat = true,
            Sharpness = 100, NightBoost = 100, Saturation = 200,
            TouchVisualizer = true,
            OverlayHotkey = "ctrl+shift+f9", OverlayVisible = true,
            KeyboardMode = "uhid", MouseMode = "uhid", GamepadMode = "aoa",
            MouseBindings = "nbsh", ShortcutMods = "lctrl,lalt,lsuper",
            Record = true, Container = "mp4", RecordPath = "max.mp4",
            FrameBridge = @"\\.\pipe\gaming-frame", BridgeScale = "3840x2160",
            BridgeFilter = "lanczos", AudioBridge = @"\\.\pipe\gaming-audio",
            AudioPcm = @"\\.\pipe\gaming-pcm", PcmMutePlayback = true,
            TurnScreenOff = true,
        }, "synthetic max settings");
        // A combo the client cannot register would leave the filter panel
        // answering only to Esc, so an invalid one must never reach the command
        // line: the launcher drops the token and the client default stays live.
        var typo = new AppConfig { Name = "hotkey typo", OverlayHotkey = "super+alt+hyper" }
            .BuildArguments("TESTSERIAL");
        var typoSent = false;
        foreach (var a in typo)
        {
            if (a.StartsWith("--game-overlay-hotkey", StringComparison.Ordinal))
            {
                typoSent = true;
            }
        }
        if (typoSent)
        {
            Console.WriteLine("FAIL an invalid overlay hotkey was sent");
            ++failures;
        }
        else
        {
            Console.WriteLine("PASS invalid overlay hotkey dropped");
        }
        Console.WriteLine(failures == 0
            ? "ALL PROFILES VALID" : $"{failures} PROFILE(S) INVALID");
        Environment.ExitCode = failures == 0 ? 0 : 1;
    }

    // --window-title is emitted as two arguments: the flag, then the value.
    private static string TitleOf(List<string> args)
    {
        var i = args.IndexOf("--window-title");
        return i >= 0 && i + 1 < args.Count ? args[i + 1] : "";
    }

    // This console is not UTF-8, and a grep that has to print a matching line
    // calls such output a binary file: the self test keeps its own stdout ASCII so
    // section 9 of tools/verify_all.sh and tools/profiles_check.sh can read it.
    private static string Ascii(string text)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var ch in text)
        {
            if (ch < 128)
            {
                sb.Append(ch);
            }
            else
            {
                sb.Append($"\\u{(int) ch:x4}");
            }
        }
        return sb.ToString();
    }

    // A profile has to be the same profile after the store's JSON round trip. The
    // serializer writes properties only, so a public field vanishes from the file
    // without a word: an explicit 1280x720 host window came back as no cap at all.
    private static bool RoundTripKeeps(AppConfig cfg)
    {
        var back = System.Text.Json.JsonSerializer
            .Deserialize<AppConfig>(System.Text.Json.JsonSerializer.Serialize(cfg));
        if (back == null)
        {
            return false;
        }
        return back.Name == cfg.Name && back.NameEs == cfg.NameEs
            && back.Notes == cfg.Notes && back.NotesEs == cfg.NotesEs
            && back.MaxFps == cfg.MaxFps && back.BitrateMbps == cfg.BitrateMbps
            && back.VideoBufferMs == cfg.VideoBufferMs
            && back.EncoderPreset == cfg.EncoderPreset
            && back.LowLatency == cfg.LowLatency
            && back.CodecLabel == cfg.CodecLabel
            && back.HostCapLabel == cfg.HostCapLabel
            && back.ExpectedLatencyMs == cfg.ExpectedLatencyMs
            && back.AudioCodec == cfg.AudioCodec
            && back.AudioBitrateKbps == cfg.AudioBitrateKbps
            && back.Record == cfg.Record && back.Container == cfg.Container
            && back.Osd == cfg.Osd && back.Upscale == cfg.Upscale
            && back.FrameBridge == cfg.FrameBridge && back.BridgeScale == cfg.BridgeScale
            && back.MouseMode == cfg.MouseMode && back.KeyboardMode == cfg.KeyboardMode;
    }

    // One argument builder and one spawn for both callers: the headless self test
    // and the GUI's save button, so "valid" cannot mean two different things.
    // scrcpy is handed --version, which makes it parse the whole command line and
    // leave from main.c before the first device call: nothing here can open a
    // session or reach a phone.
    public static (bool ok, string detail, List<string> args) ValidateAgainstBinary(
        AppConfig cfg, string? exe = null)
    {
        var args = cfg.BuildArguments("TESTSERIAL");
        args.Add("--version");
        exe ??= GamingScrcpyLauncher.MainWindow.FindScrcpyForSelfTest();
        if (exe == null)
        {
            return (false, "scrcpy.exe not found", args);
        }
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(exe)!,
        };
        foreach (var a in args)
        {
            psi.ArgumentList.Add(a);
        }
        try
        {
            using var p = Process.Start(psi)!;
            var err = p.StandardError.ReadToEnd();
            p.StandardOutput.ReadToEnd();
            if (!p.WaitForExit(10000))
            {
                p.Kill(entireProcessTree: true);
                p.WaitForExit();
            }
            var first = err.Trim().Split('\n')[0];
            return (p.ExitCode == 0, $"(exit={p.ExitCode})"
                     + (string.IsNullOrWhiteSpace(first) ? "" : " " + first), args);
        }
        catch (Exception ex)
        {
            return (false, ex.Message, args);
        }
    }
}
