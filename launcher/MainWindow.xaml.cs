using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;

namespace GamingScrcpyLauncher;

public partial class MainWindow : Window
{
    private AppConfig _cfg = new();
    private List<AndroidDevice> _devices = new();
    private Process? _scrcpy;
    private bool _suppress;
    private bool _ready;
    // where the log stood when the audio diagnostic started, so it cannot quote
    // its own lines back as "what the server said"
    private int _diagLogMark = -1;

    public MainWindow()
    {
        InitializeComponent();
        ProfileStore.SeedDefaults();
        _suppress = true;
        PopulateSteps();
        SetDefaults();
        _suppress = false;
        RefreshProfiles();
        RefreshKeymaps();
        Loaded += async (_, _) => await RefreshDevicesAsync();
        TxtScrcpyPath.Text = Shorten(ResolveScrcpyPath() ?? "(not found)");
        TxtAdbPath.Text = Shorten(Adb.ResolvePath());
        _ready = true;
        RefreshLabels();
        UpdateCommandPreview();
    }

    private static string Shorten(string path) =>
        path.Length <= 46 ? path : "" + path[^43..];

    // used by the headless --validate-profiles self test
    public static string? FindScrcpyForSelfTest() => ResolveScrcpyPath();

    private static string? ResolveScrcpyPath()
    {
        var candidates = new List<string>
        {
            // packaged layout: <root>\launcher\GamingScrcpyLauncher.exe
            //                <root>\scrcpy\scrcpy.exe
            Path.Combine(AppContext.BaseDirectory, "..", "scrcpy", "scrcpy.exe"),
            Path.Combine(AppContext.BaseDirectory, "scrcpy", "scrcpy.exe"),
            Path.Combine(AppContext.BaseDirectory, "scrcpy.exe"),
        };
        // a settings file lets the launcher point at a freshly built tree
        var settings = Path.Combine(ProfileStore.Root, "settings.json");
        if (File.Exists(settings))
        {
            foreach (var line in File.ReadAllLines(settings))
            {
                var idx = line.IndexOf("\"scrcpy\"", StringComparison.Ordinal);
                if (idx < 0)
                {
                    continue;
                }
                var start = line.IndexOf(':', idx) + 1;
                var q1 = line.IndexOf('"', start);
                var q2 = line.IndexOf('"', q1 + 1);
                if (q1 > 0 && q2 > q1)
                {
                    candidates.Insert(0,
                        line[(q1 + 1)..q2].Replace("\\\\", "\\"));
                }
            }
        }
        foreach (var c in candidates.Where(File.Exists))
        {
            return c;
        }
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir.Trim(), "scrcpy.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return null;
    }

    private void SetDefaults()
    {
        CboVideoCodec.SelectedIndex = 0;
        CboAudioCodec.SelectedIndex = 0;
        CboHwdec.SelectedIndex = 0;
        CboDriver.SelectedIndex = 0;
        CboUpscale.SelectedIndex = 1;
        CboWindowFilter.SelectedIndex = 0; // GPU scaling unless the user opts in
        CboHostPreset.SelectedIndex = 0;
        CboRenderFit.SelectedIndex = 0;
        CboOsd.SelectedIndex = 1;
        CboContainer.SelectedIndex = 0;
        CboKeyboard.SelectedIndex = 0;
        CboMouse.SelectedIndex = 0;
        CboGamepad.SelectedIndex = 0;
        ChkLowLatency.IsChecked = true;
        ChkMipmaps.IsChecked = true;
        ChkFxSharp.IsChecked = true;
    }

    // ------------------------------------------------------------------
    // config <-> UI
    // ------------------------------------------------------------------

    private static string Cb(ComboBox box) =>
        box.SelectedItem is ComboBoxItem item ? item.Content.ToString() ?? "" : "";

    // ---- discrete numeric steps (directive v2 §E) ----
    // The UI cannot reach a value outside these lists, and the binary is
    // validated against exactly this set (--validate-profiles), so "17 fps" or
    // "23 Mbps" are not offerable mistakes any more.
    private static readonly int[] FpsSteps =
        { 15, 20, 25, 30, 40, 50, 60, 90, 120, 144 };
    private static readonly int[] BitrateSteps =
        { 5, 10, 15, 20, 25, 30, 40, 50, 60, 80 };
    private static readonly int[] AudioBitrateSteps =
        { 32, 48, 64, 96, 128, 160, 192, 256, 320, 512 };
    private static readonly int[] VideoBufferSteps =
        { 0, 10, 20, 30, 40, 50, 60, 80, 100, 120, 150, 200 };
    private static readonly int[] AudioOutBufferSteps =
        { 0, 40, 60, 80, 100, 120, 160, 200, 300, 400, 500 };

    private void PopulateSteps()
    {
        FillStepBox(CboBitrate, BitrateSteps);
        FillStepBox(CboMaxFps, FpsSteps);
        FillStepBox(CboAudioBitrate, AudioBitrateSteps);
        FillStepBox(CboVideoBuffer, VideoBufferSteps);
        FillStepBox(CboAudioOutBuffer, AudioOutBufferSteps);
    }

    private static void FillStepBox(ComboBox box, int[] steps)
    {
        box.Items.Clear();
        foreach (var v in steps)
        {
            box.Items.Add(new ComboBoxItem { Content = v.ToString() });
        }
    }

    private static int CbStep(ComboBox box, int fallback) =>
        box.SelectedItem is ComboBoxItem item &&
        int.TryParse(item.Content.ToString(), out var v) ? v : fallback;

    // an old profile may hold a value the steps no longer offer: pick the
    // nearest allowed one and write it back, so the preview shows what will run
    private static int SelectStep(ComboBox box, int[] steps, int wanted)
    {
        var best = steps[0];
        foreach (var s in steps)
        {
            if (Math.Abs(s - wanted) < Math.Abs(best - wanted))
            {
                best = s;
            }
        }
        box.SelectedIndex = Array.IndexOf(steps, best);
        return best;
    }

    private void OnStepChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress)
        {
            return;
        }
        RefreshLabels();
        UpdateCommandPreview();
    }

    private static string CbValue(ComboBox box, params string[] values)
    {
        var i = box.SelectedIndex;
        return i >= 0 && i < values.Length ? values[i] : values.Length > 0 ? values[0] : "";
    }

    private AppConfig Collect()
    {
        var c = _cfg.Clone();
        c.Name = string.IsNullOrWhiteSpace(TxtProfileName.Text) ? c.Name : TxtProfileName.Text.Trim();
        c.Serial = _devices.Count > 0 && DeviceCombo.SelectedIndex >= 0
            ? (_devices[DeviceCombo.SelectedIndex].Serial)
            : c.Serial;
        // Below Android 11 the server refuses device audio, so the audio flags
        // are dropped instead of sent and warned about: a codec picker that
        // changes nothing is worse than a greyed-out one.
        var picked = DeviceCombo.SelectedIndex >= 0 && DeviceCombo.SelectedIndex < _devices.Count
            ? _devices[DeviceCombo.SelectedIndex]
            : (_devices.Count > 0 ? _devices[0] : null);
        c.NoDeviceAudio = picked is { Sdk: > 0 and < 30 };

        c.VideoCodec = CbValue(CboVideoCodec, "h264", "hevc", "av1");
        c.BitrateMbps = CbStep(CboBitrate, c.BitrateMbps);
        c.MaxFps = CbStep(CboMaxFps, c.MaxFps);
        c.EncoderPreset = CbValue(CboEncoderPreset, "default", "ultrafast", "fast", "medium");
        c.AudioCodec = CbValue(CboAudioCodec, "opus", "aac", "raw");
        c.AudioBitrateKbps = CbStep(CboAudioBitrate, c.AudioBitrateKbps);
        c.Hwdec = CbValue(CboHwdec, "auto", "disabled", "d3d11va");

        c.VideoBufferMs = CbStep(CboVideoBuffer, c.VideoBufferMs);
        c.AudioOutputBufferMs = CbStep(CboAudioOutBuffer, c.AudioOutputBufferMs);

        c.RenderDriver = CbValue(CboDriver, "direct3d11", "opengl", "vulkan", "default");
        c.Upscale = CbValue(CboUpscale, "linear", "pixelart", "nearest", "default");
        c.WindowFilter = CbValue(CboWindowFilter, "off", "lanczos", "bicubic",
                                 "bilinear", "fast", "point");
        c.HostPreset = CbValue(CboHostPreset, "fit", "1080p", "1440p", "4k",
                               "9:16-1080", "9:16-1440");
        c.RenderFit = CbValue(CboRenderFit, "letterbox", "stretched", "unscaled");
        c.Osd = CbValue(CboOsd, "full", "compact", "none");
        c.LowLatency = ChkLowLatency.IsChecked == true;
        c.BorderlessFullscreen = ChkBorderless.IsChecked == true;
        c.AlwaysOnTop = ChkAlwaysOnTop.IsChecked == true;
        c.Mipmaps = ChkMipmaps.IsChecked == true;
        c.TouchVisualizer = ChkTouchViz.IsChecked == true;
        c.CursorAutohideMs = (int) Math.Round(SldCursorHide.Value);

        c.FxSharp = ChkFxSharp.IsChecked == true;
        c.FxNight = ChkFxNight.IsChecked == true;
        c.FxSat = ChkFxSat.IsChecked == true;
        c.FxContrast = ChkFxContrast.IsChecked == true;
        c.FxBright = ChkFxBright.IsChecked == true;
        c.FxGamma = ChkFxGamma.IsChecked == true;
        c.Sharpness = (int) Math.Round(SldSharp.Value);
        c.NightBoost = (int) Math.Round(SldNight.Value);
        c.Saturation = (int) Math.Round(SldSat.Value);
        c.Contrast = (int) Math.Round(SldContrast.Value);
        c.Brightness = (int) Math.Round(SldBright.Value);
        c.Gamma = (int) Math.Round(SldGamma.Value);
        c.FilterOverlay = ChkFilterOverlay.IsChecked == true;
        c.OverlayHotkey = TxtOverlayHotkey.Text.Trim();
        c.OverlayVisible = ChkOverlayVisible.IsChecked == true;

        c.KeyboardMode = CbValue(CboKeyboard, "auto", "sdk", "uhid", "aoa", "disabled");
        c.MouseMode = CbValue(CboMouse, "auto", "sdk", "uhid", "aoa", "disabled");
        c.GamepadMode = CbValue(CboGamepad, "disabled", "uhid", "aoa");
        c.MouseBindings = TxtMouseBindings.Text.Trim();

        c.Container = CbValue(CboContainer, "mkv", "mp4");
        c.RecordPath = TxtRecordPath.Text.Trim();
        c.FrameBridge = TxtFrameBridge.Text.Trim();
        c.BridgeScale = TxtBridgeScale.Text.Trim();
        c.BridgeFilter = CbValue(CboBridgeFilter, "lanczos", "bicubic", "bilinear",
                                 "fast", "point", "default");
        c.AudioBridge = TxtAudioBridge.Text.Trim();
        c.AudioPcm = TxtAudioPcm.Text.Trim();
        c.PcmMutePlayback = ChkPcmMute.IsChecked == true;
        c.ExtraArgs = TxtExtraArgs.Text.Trim();
        return c;
    }

    private void Apply(AppConfig c)
    {
        _cfg = c;
        _suppress = true;
        TxtProfileName.Text = c.Name;
        SelectByValue(CboVideoCodec, c.VideoCodec, "h264", "hevc", "av1");
        SelectByValue(CboAudioCodec, c.AudioCodec, "opus", "aac", "raw");
        SelectByValue(CboHwdec, c.Hwdec, "auto", "disabled", "d3d11va");
        SelectByValue(CboDriver, c.RenderDriver, "direct3d11", "opengl", "vulkan",
                      "default");
        SelectByValue(CboUpscale, c.Upscale, "linear", "pixelart", "nearest",
                      "default");
        SelectByValue(CboWindowFilter, c.WindowFilter, "off", "lanczos", "bicubic",
                      "bilinear", "fast", "point");
        SelectByValue(CboHostPreset, c.HostPreset, "fit", "1080p", "1440p", "4k",
                      "9:16-1080", "9:16-1440");
        SelectByValue(CboRenderFit, c.RenderFit, "letterbox", "stretched", "auto",
                      "unscaled");
        SelectByValue(CboOsd, c.Osd, "full", "compact", "none");
        SelectByValue(CboContainer, c.Container, "mkv", "mp4");
        SelectByValue(CboKeyboard, c.KeyboardMode, "auto", "sdk", "uhid", "aoa", "disabled");
        SelectByValue(CboMouse, c.MouseMode, "auto", "sdk", "uhid", "aoa", "disabled");
        SelectByValue(CboGamepad, c.GamepadMode, "disabled", "uhid", "aoa");

        c.BitrateMbps = SelectStep(CboBitrate, BitrateSteps, c.BitrateMbps);
        c.MaxFps = SelectStep(CboMaxFps, FpsSteps, c.MaxFps);
        c.AudioBitrateKbps = SelectStep(CboAudioBitrate, AudioBitrateSteps, c.AudioBitrateKbps);
        c.VideoBufferMs = SelectStep(CboVideoBuffer, VideoBufferSteps, c.VideoBufferMs);
        c.AudioOutputBufferMs =
            SelectStep(CboAudioOutBuffer, AudioOutBufferSteps, c.AudioOutputBufferMs);
        SelectByValue(CboEncoderPreset, c.EncoderPreset,
                      "default", "ultrafast", "fast", "medium");
        SldCursorHide.Value = c.CursorAutohideMs;
        SldSharp.Value = c.Sharpness;
        SldNight.Value = c.NightBoost;
        SldSat.Value = c.Saturation;
        SldContrast.Value = c.Contrast;
        SldBright.Value = c.Brightness;
        SldGamma.Value = c.Gamma;

        ChkLowLatency.IsChecked = c.LowLatency;
        ChkBorderless.IsChecked = c.BorderlessFullscreen;
        ChkAlwaysOnTop.IsChecked = c.AlwaysOnTop;
        ChkMipmaps.IsChecked = c.Mipmaps;
        ChkTouchViz.IsChecked = c.TouchVisualizer;
        ChkFxSharp.IsChecked = c.FxSharp;
        ChkFxNight.IsChecked = c.FxNight;
        ChkFxSat.IsChecked = c.FxSat;
        ChkFxContrast.IsChecked = c.FxContrast;
        ChkFxBright.IsChecked = c.FxBright;
        ChkFxGamma.IsChecked = c.FxGamma;
        ChkFilterOverlay.IsChecked = c.FilterOverlay;
        ChkOverlayVisible.IsChecked = c.OverlayVisible;
        TxtOverlayHotkey.Text = string.IsNullOrWhiteSpace(c.OverlayHotkey)
                                ? "super+alt+f" : c.OverlayHotkey;

        TxtRecordPath.Text = c.RecordPath;
        TxtFrameBridge.Text = c.FrameBridge;
        TxtBridgeScale.Text = c.BridgeScale;
        SelectByValue(CboBridgeFilter, c.BridgeFilter, "lanczos", "bicubic",
                      "bilinear", "fast", "point", "default");
        TxtAudioBridge.Text = c.AudioBridge;
        TxtAudioPcm.Text = c.AudioPcm;
        ChkPcmMute.IsChecked = c.PcmMutePlayback;
        TxtExtraArgs.Text = c.ExtraArgs;
        TxtMouseBindings.Text = c.MouseBindings;
        RefreshLabels();
        _suppress = false;
        UpdateCommandPreview();
    }

    private static void SelectByValue(ComboBox box, string value,
                                      params string[] values)
    {
        for (var i = 0; i < values.Length; ++i)
        {
            if (string.Equals(values[i], value, StringComparison.OrdinalIgnoreCase))
            {
                box.SelectedIndex = i;
                return;
            }
        }
        box.SelectedIndex = 0;
    }

    private void RefreshLabels()
    {
        // WPF raises Slider.ValueChanged while the window is still being parsed,
        // before the label elements exist
        if (!_ready)
        {
            return;
        }
        UpdateDeviceSummary();
        LblBitrate.Text = Loc.Format("UnitMbps", CbStep(CboBitrate, _cfg.BitrateMbps));
        LblMaxFps.Text = Loc.Format("UnitFps", CbStep(CboMaxFps, _cfg.MaxFps));
        LblAudioBitrate.Text =
            Loc.Format("UnitKbps", CbStep(CboAudioBitrate, _cfg.AudioBitrateKbps));
        LblVideoBuffer.Text = Loc.Format("UnitMs", CbStep(CboVideoBuffer, _cfg.VideoBufferMs));
        LblAudioOutBuffer.Text =
            Loc.Format("UnitMs", CbStep(CboAudioOutBuffer, _cfg.AudioOutputBufferMs));
        LblCursorHide.Text = $"{(int) SldCursorHide.Value}";
        LblSharp.Text = $"{(int) SldSharp.Value}";
        LblNight.Text = $"{(int) SldNight.Value}";
        LblSat.Text = $"{(int) SldSat.Value}";
        LblContrast.Text = $"{(int) SldContrast.Value}";
        LblBright.Text = $"{(int) SldBright.Value}";
        LblGamma.Text = $"{(int) SldGamma.Value}";
        LblCodecNote.Text = Cb(CboVideoCodec).Contains("av1", StringComparison.OrdinalIgnoreCase)
            ? Loc.T("NoteAv1")
            : Cb(CboVideoCodec).Contains("hevc", StringComparison.OrdinalIgnoreCase)
                ? Loc.T("NoteHevc") : Loc.T("NoteDeviceHw");
        LblOverlayHotkeyBad.Visibility = AppConfig.NormalizeOverlayHotkey(TxtOverlayHotkey.Text) != null
            ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdateCommandPreview()
    {
        if (!_ready)
        {
            return;
        }
        var exe = ResolveScrcpyPath() ?? "scrcpy";
        TxtCommand.Text = Collect().Preview(exe);
    }

    // ------------------------------------------------------------------
    // devices
    // ------------------------------------------------------------------

    private async Task RefreshDevicesAsync()
    {
        Log(Loc.T("LogScanning"));
        _devices = await Adb.ListDevicesAsync();
        DeviceCombo.Items.Clear();
        foreach (var d in _devices)
        {
            DeviceCombo.Items.Add(d.Display);
        }
        if (_devices.Count > 0)
        {
            DeviceCombo.SelectedIndex = 0;
            var first = _devices[0];
            DeviceBadge.Text = Loc.Format("BadgeDevices", _devices.Count);
            Log(Loc.Format("LogDetected", first.Display, first.State));
            if (!first.IsWireless && first.State == "device")
            {
                var model = await Adb.GetDevicePropAsync(first.Serial,
                    "ro.product.model");
                if (!string.IsNullOrWhiteSpace(model))
                {
                    Log(Loc.Format("LogDeviceModel", model));
                }
                // Read-only, and the only way to know before starting whether
                // this device can encode AV1 at all, or carry audio at all.
                var sdkText = await Adb.GetDevicePropAsync(first.Serial,
                    "ro.build.version.sdk");
                var release = await Adb.GetDevicePropAsync(first.Serial,
                    "ro.build.version.release");
                if (int.TryParse(sdkText, out var sdk) && sdk > 0)
                {
                    _devices[0] = first with { Sdk = sdk, Model = model, Release = release };
                    DeviceCombo.Items[0] = _devices[0].Display;
                    // Replacing an item drops the selection, which would leave
                    // the user with a device in the box and none selected.
                    DeviceCombo.SelectedIndex = 0;
                }
            }
        }
        else
        {
            DeviceBadge.Text = Loc.T("BadgeNoDevice");
            Log(Loc.T("LogNoDevice"));
        }
        UpdateDeviceSummary();
        UpdateCommandPreview();
    }

    // The header's second line: what the phone actually is, in one trimmed
    // sentence. Kept out of the badge so a long model name can never reach the
    // action buttons, and re-computed on a language switch because it is
    // localised text.
    private void UpdateDeviceSummary()
    {
        if (!_ready)
        {
            return;
        }
        var d = _devices.Count > 0 ? _devices[0] : null;
        var online = d is { State: "device" };
        var noAudio = d is { Sdk: > 0 and < 30 };
        var good = (System.Windows.Media.Brush)FindResource("Good");
        var warn = (System.Windows.Media.Brush)FindResource("Warn");
        DevDot.Fill = online ? good : warn;
        DeviceBadge.Foreground = online ? good : warn;
        TxtDeviceSummary.Text = d is null
            ? Loc.T("SummaryNoDevice")
            : Loc.Format("SummaryDevice",
                d.IsWireless ? "WiFi" : "USB",
                string.IsNullOrWhiteSpace(d.Model) ? d.Serial : d.Model,
                string.IsNullOrWhiteSpace(d.Release) ? "?" : d.Release,
                d.Sdk > 0 ? d.Sdk.ToString() : "?");
        // The phone answers for the audio: an SDK of 0 means it has not been
        // read yet, so the badge stays hidden rather than guessing.
        TxtAudioBadge.Visibility = d is { Sdk: > 0 } ? Visibility.Visible : Visibility.Collapsed;
        TxtAudioBadge.Text = noAudio ? Loc.T("AudioUnsupported") : Loc.T("AudioSupported");
        TxtAudioBadge.Foreground = noAudio ? warn : good;
        ApplyAudioCapability(noAudio);
    }

    // v3 §1.2: a control that changes nothing is worse than a greyed-out one, so
    // the audio widgets follow what the phone can actually do and say why in
    // their tooltip. IsEnabled leaves them in the UI tree, which is what gate
    // section 10 asserts.
    private void ApplyAudioCapability(bool unsupported)
    {
        var tip = unsupported ? Loc.T("TipAudioNeedsApi30") : Loc.T("TipAudioEnabled");
        foreach (var c in new System.Windows.Controls.Control[]
                 { CboAudioCodec, CboAudioBitrate, CboAudioOutBuffer,
                   TxtAudioBridge, TxtAudioPcm, ChkPcmMute })
        {
            c.IsEnabled = !unsupported;
            c.ToolTip = tip;
        }
    }

    // v3 §1.2: everything here is a read. The device is someone's phone, so the
    // diagnostic reads props and dumpsys and never writes, mutes or restarts.
    private async void OnAudioDiagnostic(object sender, RoutedEventArgs e)
    {
        var d = _devices.Count > 0 ? _devices[0] : null;
        _diagLogMark = TxtLog.Text.Length;
        if (d is null)
        {
            Log(Loc.T("DiagAudioNoDevice"));
            return;
        }
        Log(Loc.Format("DiagAudioSdk", d.Serial, d.Sdk, d.Release));
        var supported = d.Sdk >= 30;
        Log(supported ? Loc.T("DiagAudioYes") : Loc.T("DiagAudioNo"));

        var server = LastAudioLine();
        Log(Loc.Format("DiagAudioServer", server ?? Loc.T("DiagAudioNoLine")));

        var running = _scrcpy is { HasExited: false };
        var sink = !running
            ? Loc.T("DiagAudioIdle")
            : Collect().NoDeviceAudio ? Loc.T("DiagAudioNoAudioFlag")
            : Collect().PcmMutePlayback ? Loc.T("DiagAudioMuted")
            : Loc.T("DiagAudioPlaying");
        Log(Loc.Format("DiagAudioSink", sink));

        var dump = await Adb.RunAsync($"-s {d.Serial} shell dumpsys audio", 8000);
        // Android 9 prints the music stream as a "- STREAM_MUSIC:" block whose
        // Current:/Devices: lines carry the per-route indexes. Newer releases
        // reformat it, and then the honest answer is "not readable" rather than
        // a number invented from the wrong line.
        var lines = dump.output.Split('\n').Select(l => l.Trim()).ToList();
        var music = lines.FindIndex(l => l.StartsWith("- STREAM_MUSIC"));
        var volume = music < 0
            ? ""
            : string.Join(" ", lines.Skip(music + 1).Take(5)
                .Where(l => l.StartsWith("Current:") || l.StartsWith("Devices:")));
        Log(Loc.Format("DiagAudioVolume",
            string.IsNullOrWhiteSpace(volume) ? Loc.T("DiagAudioNoVolume") : volume));
    }

    // Only what the server said before this diagnostic started: the diagnostic
    // writes the word "audio" itself, and matching that would quote itself.
    private string? LastAudioLine()
    {
        var text = TxtLog.Text;
        var upto = _diagLogMark >= 0 && _diagLogMark <= text.Length ? _diagLogMark : text.Length;
        string? found = null;
        foreach (var raw in text.AsSpan(0, upto).ToString().Split('\n'))
        {
            var line = raw.Trim();
            if (line.Contains("Audio", StringComparison.OrdinalIgnoreCase)
                || line.Contains("audio", StringComparison.Ordinal))
            {
                found = line;
            }
        }
        return found;
    }

    private async void OnRefreshDevices(object sender, RoutedEventArgs e) =>
        await RefreshDevicesAsync();

    private void OnWirelessGuide(object sender, RoutedEventArgs e)
    {
        // Switching the device to TCP mode is a write on the device itself, so
        // this launcher only explains how to do it by hand and then uses the
        // read-only half (pair/connect against a device already in TCP mode).
        MessageBox.Show(this, Loc.T("WirelessGuideBody"), Loc.T("WirelessGuideTitle"),
                        MessageBoxButton.OK, MessageBoxImage.Information);
        Log(Loc.T("WirelessGuideLogged"));
    }

    private async void OnPairWireless(object sender, RoutedEventArgs e)
    {
        var hostPort = Prompt("Wireless pairing",
            "Android 11+: Developer options > Wireless debugging  Pair device.\n"
            + "Enter the ip:port shown on the phone:", "192.168.1.20:37021");
        if (hostPort == null)
        {
            return;
        }
        var code6 = Prompt("Pairing code",
            "Enter the 6-digit code shown on the phone:", "000000");
        if (code6 == null)
        {
            return;
        }
        var (rc, output) = await Adb.PairAsync(hostPort.Trim(), code6.Trim());
        Log(Loc.Format("LogPair", output));
        if (rc == 0)
        {
            var connect = Prompt("Connected", "Enter the debugging ip:port shown on the Wireless debugging screen:", "192.168.1.20:5555");
            if (connect != null)
            {
                var (_, o2) = await Adb.ConnectAsync(connect.Trim());
                Log(Loc.Format("LogConnect", o2));
            }
        }
        await RefreshDevicesAsync();
    }

    private async void OnConnectWireless(object sender, RoutedEventArgs e)
    {
        var hostPort = Prompt("Connect over TCP/IP", "Device ip:port",
            "192.168.1.20:5555");
        if (hostPort == null)
        {
            return;
        }
        var (_, output) = await Adb.ConnectAsync(hostPort.Trim());
        Log(Loc.Format("LogConnect", output));
        await RefreshDevicesAsync();
    }

    private AndroidDevice? SelectedDevice()
    {
        if (_devices.Count == 0 || DeviceCombo.SelectedIndex < 0)
        {
            return null;
        }
        return _devices[DeviceCombo.SelectedIndex];
    }

    private string? SelectedSerial()
    {
        var device = SelectedDevice();
        if (device == null)
        {
            MessageBox.Show(this, Loc.T("DlgNoDeviceBody"), Loc.T("AppName"),
                            MessageBoxButton.OK, MessageBoxImage.Information);
            return null;
        }
        return device.Serial;
    }

    // ------------------------------------------------------------------
    // launch / stop
    // ------------------------------------------------------------------

    private async void OnStartMirror(object sender, RoutedEventArgs e) =>
        await StartAsync(record: false);

    private async void OnStartMirrorRecord(object sender, RoutedEventArgs e) =>
        await StartAsync(record: true);

    private async void OnStartRecordOnly(object sender, RoutedEventArgs e) =>
        await StartAsync(record: true, noWindow: true);

    private async Task StartAsync(bool record, bool noWindow = false)
    {
        if (_scrcpy is { HasExited: false })
        {
            Log(Loc.T("LogAlreadyRunning"));
            return;
        }
        var exe = ResolveScrcpyPath();
        if (exe == null)
        {
            MessageBox.Show(this,
                Loc.Format("DlgNoExeBody",
                    Path.Combine(ProfileStore.Root, "settings.json")),
                Loc.T("AppName"), MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var cfg = Collect();
        // A device with no AV1 encoder does not say so: the server dies while
        // configuring the codec and the client exits without ever opening a
        // window. Measured on a moto g(7) power (Android 9, SDK 28), where
        // --video-codec=av1 logs "Demuxer 'video': stream disabled due to
        // connection error" and h264 on the same phone mirrors fine.
        var device = SelectedDevice();
        if (device is { Sdk: > 0 } && cfg.VideoCodec == "av1" && device.Sdk < 29)
        {
            cfg.VideoCodec = "h264";
            Log(Loc.Format("LogAv1Fallback", device.Sdk));
        }
        if (record)
        {
            cfg.Record = true;
            if (string.IsNullOrWhiteSpace(cfg.RecordPath))
            {
                Directory.CreateDirectory(ProfileStore.RecordingsDir);
                cfg.RecordPath = Path.Combine(ProfileStore.RecordingsDir,
                    $"rec-{DateTime.Now:yyyyMMdd-HHmmss}.{cfg.Container}");
            }
        }
        var args = cfg.BuildArguments(SelectedSerial() ?? cfg.Serial);
        if (noWindow)
        {
            args.Add("--no-window");
            args.Add("--no-control");
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

        Log(Loc.Format("LogLaunch", string.Join(" ", args)));
        try
        {
            _scrcpy = Process.Start(psi);
        }
        catch (Exception ex)
        {
            Log(Loc.Format("LogStartFailed", ex.Message));
            return;
        }
        if (_scrcpy == null)
        {
            Log(Loc.T("LogStartFailedPlain"));
            return;
        }
        TxtStatus.Text = Loc.T(noWindow ? "StatusRecording" : "StatusMirroring");
        _scrcpy.OutputDataReceived += (_, ev) =>
        {
            if (ev.Data != null)
            {
                Dispatcher.Invoke(() => Log(ev.Data));
            }
        };
        _scrcpy.ErrorDataReceived += (_, ev) =>
        {
            if (ev.Data != null)
            {
                Dispatcher.Invoke(() => Log("! " + ev.Data));
            }
        };
        _scrcpy.BeginOutputReadLine();
        _scrcpy.BeginErrorReadLine();
        _scrcpy.EnableRaisingEvents = true;
        _scrcpy.Exited += (_, _) => Dispatcher.Invoke(() =>
        {
            string exit = ((int?) _scrcpy?.ExitCode)?.ToString() ?? "?";
            TxtStatus.Text = Loc.Format("StatusStoppedExit", exit);
            Log(Loc.Format("LogExitCode", exit));
            if (record && File.Exists(cfg.RecordPath))
            {
                var bytes = new FileInfo(cfg.RecordPath).Length;
                Log(Loc.Format("LogRecordingKept", cfg.RecordPath, bytes.ToString("N0")));
            }
        });
        await Task.CompletedTask;
    }

    private void OnStop(object sender, RoutedEventArgs e)
    {
        if (_scrcpy is { HasExited: false })
        {
            _scrcpy.Kill(entireProcessTree: true);
            Log(Loc.T("LogStopRequested"));
        }
    }

    // ------------------------------------------------------------------
    // profiles / keymaps
    // ------------------------------------------------------------------

    private void RefreshProfiles(string? select = null)
    {
        ProfileList.Items.Clear();
        foreach (var f in ProfileStore.ListProfiles())
        {
            ProfileList.Items.Add(f);
        }
        if (select != null)
        {
            ProfileList.SelectedItem = ProfileList.Items.Cast<string>()
                .FirstOrDefault(x => x == select);
        }
        else if (ProfileList.Items.Count > 0)
        {
            ProfileList.SelectedIndex = 0;
        }
    }

    private void RefreshKeymaps()
    {
        KeymapList.Items.Clear();
        foreach (var f in ProfileStore.ListKeymaps())
        {
            KeymapList.Items.Add(f);
        }
        if (KeymapList.Items.Count > 0)
        {
            KeymapList.SelectedIndex = 0;
        }
    }

    private void OnProfileSelected(object sender, SelectionChangedEventArgs e)
    {
        if (ProfileList.SelectedItem is not string file || _suppress)
        {
            return;
        }
        var cfg = ProfileStore.LoadProfile(file);
        if (cfg != null)
        {
            Apply(cfg);
            Log(Loc.Format("LogProfileLoaded", cfg.Name));
        }
    }

    private void OnLoadProfile(object sender, RoutedEventArgs e)
    {
        if (ProfileList.SelectedItem is string file)
        {
            var cfg = ProfileStore.LoadProfile(file);
            if (cfg != null)
            {
                Apply(cfg);
            }
        }
    }

    private void OnSaveProfile(object sender, RoutedEventArgs e)
    {
        var name = Prompt("Save profile", "Profile name:",
            string.IsNullOrWhiteSpace(TxtProfileName.Text) ? "My profile"
                                                           : TxtProfileName.Text);
        if (name == null)
        {
            return;
        }
        var cfg = Collect();
        cfg.Name = name.Trim();
        // the panel keeps its grades in one file; the session carries the same
        // lines so loading it back restores what the user saved (v3 §5.4)
        cfg.FilterProfiles = ProfileStore.HarvestFilterProfiles();
        ProfileStore.SaveProfile(cfg);
        RefreshProfiles(name.Trim() + ".json");
        Log(Loc.Format("LogProfileSaved", cfg.Name));
        UpdateCommandPreview();
    }

    private void OnNewProfile(object sender, RoutedEventArgs e)
    {
        var cfg = new AppConfig { Name = Loc.T("ProfileNew") };
        Apply(cfg);
        TxtProfileName.Text = cfg.Name;
        Log(Loc.T("LogNewProfile"));
    }

    private void OnDeleteProfile(object sender, RoutedEventArgs e)
    {
        if (ProfileList.SelectedItem is not string file)
        {
            return;
        }
        if (MessageBox.Show(this, Loc.Format("ConfirmDeleteProfile", file),
                            Loc.T("ConfirmTitle"),
                            MessageBoxButton.YesNo, MessageBoxImage.Question) !=
            MessageBoxResult.Yes)
        {
            return;
        }
        File.Delete(Path.Combine(ProfileStore.ProfilesDir, file));
        RefreshProfiles();
        Log(Loc.Format("LogDeleted", file));
    }

    private void OnApplyKeymap(object sender, RoutedEventArgs e)
    {
        if (KeymapList.SelectedItem is not string file)
        {
            return;
        }
        var km = ProfileStore.LoadKeymap(file);
        if (km == null)
        {
            Log(Loc.T("LogKeymapBad"));
            return;
        }
        var cfg = Collect();
        cfg.KeyboardMode = km.KeyboardMode;
        cfg.MouseMode = km.MouseMode;
        cfg.GamepadMode = km.GamepadMode;
        cfg.ShortcutMods = km.ShortcutMod;
        cfg.MouseBindings = km.MouseBindings;
        _cfg = cfg;
        Apply(cfg);
        ShowKeymap(km);
        Log(Loc.Format("LogKeymapApplied", km.Name, km.KeyboardMode,
                       km.MouseMode, km.GamepadMode));
    }

    private void ShowKeymap(Keymap km)
    {
        KeymapDetails.Children.Clear();
        KeymapDetails.Children.Add(new TextBlock
        {
            Text = km.Name,
            FontWeight = FontWeights.SemiBold,
            Foreground = (System.Windows.Media.Brush) FindResource("Accent"),
        });
        foreach (var b in km.Bindings)
        {
            var line = new TextBlock
            {
                Text = $"  {b.Key}  {b.Action}",
                Foreground = (System.Windows.Media.Brush) FindResource("Fg"),
            };
            KeymapDetails.Children.Add(line);
            if (!string.IsNullOrWhiteSpace(b.Note))
            {
                KeymapDetails.Children.Add(new TextBlock
                {
                    Text = "      " + b.Note,
                    Foreground = (System.Windows.Media.Brush) FindResource("FgDim"),
                    FontSize = 11,
                });
            }
        }
    }

    private void OnOpenKeymapDir(object sender, RoutedEventArgs e)
    {
        Process.Start(new ProcessStartInfo("explorer.exe",
            $"\"{ProfileStore.KeymapsDir}\"") { UseShellExecute = true });
    }

    // ------------------------------------------------------------------
    // misc UI
    // ------------------------------------------------------------------

    // The panel hotkey is the only key combination typed as free text: a combo
    // the client cannot register would leave the panel answering only to Esc,
    // so the box warns while the user is still typing it.
    private void OnOverlayHotkeyChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppress)
        {
            return;
        }
        RefreshLabels();
        UpdateCommandPreview();
    }

    private void OnSliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_suppress)
        {
            return;
        }
        RefreshLabels();
        UpdateCommandPreview();
    }

    private void OnBrowseRecord(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "Video|*.mkv;*.mp4|All files|*.*",
            FileName = $"rec-{DateTime.Now:yyyyMMdd-HHmmss}.mkv",
            InitialDirectory = ProfileStore.RecordingsDir,
        };
        if (dlg.ShowDialog(this) == true)
        {
            TxtRecordPath.Text = dlg.FileName;
            var ext = Path.GetExtension(dlg.FileName).TrimStart('.');
            if (ext.Equals("mp4", StringComparison.OrdinalIgnoreCase))
            {
                CboContainer.SelectedIndex = 1;
            }
            else if (ext.Equals("mkv", StringComparison.OrdinalIgnoreCase))
            {
                CboContainer.SelectedIndex = 0;
            }
            UpdateCommandPreview();
        }
    }

    private void OnBridgePreset(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string size })
        {
            return;
        }
        TxtBridgeScale.Text = size;
        if (string.IsNullOrWhiteSpace(TxtFrameBridge.Text))
        {
            TxtFrameBridge.Text = @"\\.\pipe\gaming-frame";
        }
        Log(Loc.Format("LogBridgeResample", size));
        UpdateCommandPreview();
    }

    private void OnCopyCommand(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText(TxtCommand.Text);
        Log(Loc.T("LogCopiedCommand"));
    }

    private void OnCopyObsCommand(object sender, RoutedEventArgs e)
    {
        var cfg = Collect();
        var target = string.IsNullOrWhiteSpace(cfg.FrameBridge)
            ? @"\\.\pipe\gaming-frame"
            : cfg.FrameBridge;
        var sb = new StringBuilder();
        sb.AppendLine("REM Option A (recommended, zero extra latency):");
        sb.AppendLine("REM   OBS  >  Source  >  Window Capture  >  'Gaming Scrcpy'");
        sb.AppendLine("REM   Use --game-borderless-fullscreen so the window fills");
        sb.AppendLine("REM   the monitor without exclusive fullscreen.");
        sb.AppendLine();
        sb.AppendLine("REM Option B: raw frame bridge into a second encoder/OBS:");
        var size = AppConfig.NormalizeBridgeScale(cfg.BridgeScale) ?? "WIDTHxHEIGHT";
        if (size == "WIDTHxHEIGHT")
        {
            sb.AppendLine("REM   replace WIDTHxHEIGHT with the size reported by "
                          + "the bridge sidecar (.meta.txt)");
        }
        else
        {
            sb.AppendLine("REM   size taken from the bridge scale setting");
        }
        sb.AppendLine("ffplay -f rawvideo -pixel_format rgba -video_size "
                      + size + " \"" + target + "\"");
        sb.AppendLine("ffmpeg -f rawvideo -pixel_format rgba -video_size "
                      + size + " -i \"" + target +
                      "\" -c:v libx264 -preset veryfast out.mp4");
        if (!string.IsNullOrWhiteSpace(cfg.AudioBridge))
        {
            sb.AppendLine();
            sb.AppendLine("REM Audio splitter (raw device packets, no re-encode):");
            sb.AppendLine("REM with --audio-codec=raw the pipe is 48 kHz stereo s16le:");
            sb.AppendLine("ffmpeg -f s16le -ar 48000 -ac 2 -i \"" + cfg.AudioBridge +
                          "\" -f wasapi \"CABLE Output\"");
        }
        if (!string.IsNullOrWhiteSpace(cfg.AudioPcm))
        {
            sb.AppendLine();
            sb.AppendLine("REM Decoded audio (always s16le / 48 kHz / stereo), what a");
            sb.AppendLine("REM virtual cable actually plays:");
            sb.AppendLine("ffmpeg -f s16le -ar 48000 -ac 2 -i \"" + cfg.AudioPcm +
                          "\" -f wasapi \"CABLE Output\"");
        }
        Clipboard.SetText(sb.ToString());
        Log(Loc.T("LogCopiedObs"));
    }

    private void Log(string line)
    {
        TxtLog.AppendText($"[{DateTime.Now:HH:mm:ss}] {line}\n");
        TxtLog.ScrollToEnd();
    }

    private string? Prompt(string title, string message, string initial)
    {
        var panel = new StackPanel { Margin = new Thickness(12) };
        panel.Children.Add(new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8),
        });
        var box = new TextBox { Text = initial, MinWidth = 320 };
        panel.Children.Add(box);
        var result = default(string);
        var win = new Window
        {
            Title = title,
            Content = panel,
            SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this,
            ResizeMode = ResizeMode.NoResize,
            Background = (System.Windows.Media.Brush) FindResource("Bg"),
            Foreground = (System.Windows.Media.Brush) FindResource("Fg"),
        };
        var ok = new Button { Content = "OK", IsDefault = true, Margin = new Thickness(0, 10, 8, 0) };
        ok.Click += (_, _) =>
        {
            result = box.Text;
            win.DialogResult = true;
        };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Margin = new Thickness(0, 10, 0, 0) };
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        row.Children.Add(ok);
        row.Children.Add(cancel);
        panel.Children.Add(row);
        box.Focus();
        box.SelectAll();
        return win.ShowDialog() == true ? result : null;
    }
}
