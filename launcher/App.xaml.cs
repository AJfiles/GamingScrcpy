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
        base.OnStartup(e);
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
        void Check(AppConfig cfg)
        {
            var args = cfg.BuildArguments("TESTSERIAL");
            args.Add("--version");
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
            using var p = Process.Start(psi)!;
            var err = p.StandardError.ReadToEnd();
            p.StandardOutput.ReadToEnd();
            if (!p.WaitForExit(10000))
            {
                p.Kill(entireProcessTree: true);
                p.WaitForExit();
            }
            var ok = p.ExitCode == 0;
            if (!ok)
            {
                ++failures;
            }
            Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {cfg.Name} "
                              + $"(exit={p.ExitCode}) {err.Trim().Split('\n')[0]}");
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
        foreach (var file in ProfileStore.ListProfiles())
        {
            var cfg = ProfileStore.LoadProfile(file);
            if (cfg == null)
            {
                Console.WriteLine($"FAIL {file}: could not parse");
                ++failures;
                continue;
            }
            Check(cfg);
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
            KeyboardMode = "uhid", MouseMode = "uhid", GamepadMode = "aoa",
            MouseBindings = "nbsh", ShortcutMods = "lctrl,lalt,lsuper",
            Record = true, Container = "mp4", RecordPath = "max.mp4",
            FrameBridge = @"\\.\pipe\gaming-frame", BridgeScale = "3840x2160",
            BridgeFilter = "lanczos", AudioBridge = @"\\.\pipe\gaming-audio",
            AudioPcm = @"\\.\pipe\gaming-pcm", PcmMutePlayback = true,
            TurnScreenOff = true,
        });
        Console.WriteLine(failures == 0
            ? "ALL PROFILES VALID" : $"{failures} PROFILE(S) INVALID");
        Environment.ExitCode = failures == 0 ? 0 : 1;
    }
}
