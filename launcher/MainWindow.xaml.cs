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

    public MainWindow()
    {
        InitializeComponent();
        ProfileStore.SeedDefaults();
        _suppress = true;
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

        c.VideoCodec = CbValue(CboVideoCodec, "h264", "hevc", "av1");
        c.BitrateMbps = (int) Math.Round(SldBitrate.Value);
        c.MaxFps = (int) Math.Round(SldMaxFps.Value);
        c.AudioCodec = CbValue(CboAudioCodec, "opus", "aac", "raw");
        c.AudioBitrateKbps = (int) Math.Round(SldAudioBitrate.Value);
        c.Hwdec = CbValue(CboHwdec, "auto", "disabled", "d3d11va");

        c.VideoBufferMs = (int) Math.Round(SldVideoBuffer.Value);
        c.AudioOutputBufferMs = (int) Math.Round(SldAudioOutBuffer.Value);

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
        c.Sharpness = (int) Math.Round(SldSharp.Value);
        c.NightBoost = (int) Math.Round(SldNight.Value);
        c.Saturation = (int) Math.Round(SldSat.Value);

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

        SldBitrate.Value = c.BitrateMbps;
        SldMaxFps.Value = c.MaxFps;
        SldAudioBitrate.Value = c.AudioBitrateKbps;
        SldVideoBuffer.Value = c.VideoBufferMs;
        SldAudioOutBuffer.Value = c.AudioOutputBufferMs;
        SldCursorHide.Value = c.CursorAutohideMs;
        SldSharp.Value = c.Sharpness;
        SldNight.Value = c.NightBoost;
        SldSat.Value = c.Saturation;

        ChkLowLatency.IsChecked = c.LowLatency;
        ChkBorderless.IsChecked = c.BorderlessFullscreen;
        ChkAlwaysOnTop.IsChecked = c.AlwaysOnTop;
        ChkMipmaps.IsChecked = c.Mipmaps;
        ChkTouchViz.IsChecked = c.TouchVisualizer;
        ChkFxSharp.IsChecked = c.FxSharp;
        ChkFxNight.IsChecked = c.FxNight;
        ChkFxSat.IsChecked = c.FxSat;

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
        LblBitrate.Text = $"{(int) SldBitrate.Value} Mb";
        LblMaxFps.Text = $"{(int) SldMaxFps.Value}";
        LblAudioBitrate.Text = $"{(int) SldAudioBitrate.Value}";
        LblVideoBuffer.Text = $"{(int) SldVideoBuffer.Value}";
        LblAudioOutBuffer.Text = $"{(int) SldAudioOutBuffer.Value}";
        LblCursorHide.Text = $"{(int) SldCursorHide.Value}";
        LblSharp.Text = $"{(int) SldSharp.Value}";
        LblNight.Text = $"{(int) SldNight.Value}";
        LblSat.Text = $"{(int) SldSat.Value}";
        LblCodecNote.Text = Cb(CboVideoCodec).Contains("av1", StringComparison.OrdinalIgnoreCase)
            ? "needs AV1 encoder"
            : Cb(CboVideoCodec).Contains("hevc", StringComparison.OrdinalIgnoreCase)
                ? "needs HEVC encoder" : "device HW";
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
        Log("scanning adb devices");
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
            DeviceBadge.Text = $"{_devices.Count} device(s)";
            Log($"detected: {first.Display} state={first.State}");
            if (!first.IsWireless && first.State == "device")
            {
                var model = await Adb.GetDevicePropAsync(first.Serial,
                    "ro.product.model");
                if (!string.IsNullOrWhiteSpace(model))
                {
                    Log($"device model: {model}");
                }
            }
        }
        else
        {
            DeviceBadge.Text = "no device";
            Log("no adb device found (connect by USB, or pair wirelessly)");
        }
        UpdateCommandPreview();
    }

    private async void OnRefreshDevices(object sender, RoutedEventArgs e) =>
        await RefreshDevicesAsync();

    private async void OnEnableTcpIp(object sender, RoutedEventArgs e)
    {
        var serial = SelectedSerial();
        if (serial == null)
        {
            return;
        }
        var (code, output) = await Adb.TcpIpAsync(serial, 5555);
        Log($"adb tcpip 5555 -> {output}");
        if (code == 0)
        {
            Log("now unplug USB and use 'Connect ip:port' with the device IP");
        }
        await RefreshDevicesAsync();
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
        Log($"adb pair -> {output}");
        if (rc == 0)
        {
            var connect = Prompt("Connected", "Enter the debugging ip:port shown on the Wireless debugging screen:", "192.168.1.20:5555");
            if (connect != null)
            {
                var (_, o2) = await Adb.ConnectAsync(connect.Trim());
                Log($"adb connect -> {o2}");
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
        Log($"adb connect -> {output}");
        await RefreshDevicesAsync();
    }

    private string? SelectedSerial()
    {
        if (_devices.Count == 0 || DeviceCombo.SelectedIndex < 0)
        {
            MessageBox.Show(this,
                "No device selected. Connect a phone (USB debugging enabled) or "
                + "pair one over Wi-Fi first.", "Gaming Scrcpy",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return null;
        }
        return _devices[DeviceCombo.SelectedIndex].Serial;
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
            Log("already running - stop it first");
            return;
        }
        var exe = ResolveScrcpyPath();
        if (exe == null)
        {
            MessageBox.Show(this,
                "scrcpy.exe not found. Put GamingScrcpyLauncher.exe next to the "
                + "scrcpy package, or write {\"scrcpy\": \"C:\\\\path\\\\scrcpy.exe\"} "
                + "into " + Path.Combine(ProfileStore.Root, "settings.json"),
                "Gaming Scrcpy", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var cfg = Collect();
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

        Log("launch: " + string.Join(" ", args));
        try
        {
            _scrcpy = Process.Start(psi);
        }
        catch (Exception ex)
        {
            Log("failed to start scrcpy: " + ex.Message);
            return;
        }
        if (_scrcpy == null)
        {
            Log("failed to start scrcpy");
            return;
        }
        TxtStatus.Text = noWindow ? "recording" : "mirroring";
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
            TxtStatus.Text = $"stopped (exit {_scrcpy?.ExitCode})";
            Log($"scrcpy exited with code {_scrcpy?.ExitCode}");
            if (record && File.Exists(cfg.RecordPath))
            {
                var bytes = new FileInfo(cfg.RecordPath).Length;
                Log($"recording kept: {cfg.RecordPath} ({bytes:N0} bytes)");
            }
        });
        await Task.CompletedTask;
    }

    private void OnStop(object sender, RoutedEventArgs e)
    {
        if (_scrcpy is { HasExited: false })
        {
            _scrcpy.Kill(entireProcessTree: true);
            Log("stop requested");
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
            Log($"loaded profile {cfg.Name}");
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
        ProfileStore.SaveProfile(cfg);
        RefreshProfiles(name.Trim() + ".json");
        Log($"saved profile {cfg.Name}");
        UpdateCommandPreview();
    }

    private void OnNewProfile(object sender, RoutedEventArgs e)
    {
        var cfg = new AppConfig { Name = "New profile" };
        Apply(cfg);
        TxtProfileName.Text = cfg.Name;
        Log("new profile started (Save it when ready)");
    }

    private void OnDeleteProfile(object sender, RoutedEventArgs e)
    {
        if (ProfileList.SelectedItem is not string file)
        {
            return;
        }
        if (MessageBox.Show(this, $"Delete profile {file}?", "Confirm",
                MessageBoxButton.YesNo, MessageBoxImage.Question) !=
            MessageBoxResult.Yes)
        {
            return;
        }
        File.Delete(Path.Combine(ProfileStore.ProfilesDir, file));
        RefreshProfiles();
        Log($"deleted {file}");
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
            Log("keymap could not be parsed");
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
        Log($"applied keymap {km.Name} (keyboard={km.KeyboardMode} "
            + $"mouse={km.MouseMode} gamepad={km.GamepadMode})");
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
        Log("frame bridge will resample to " + size + " on its own thread");
        UpdateCommandPreview();
    }

    private void OnCopyCommand(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText(TxtCommand.Text);
        Log("command line copied to clipboard");
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
        Log("OBS / FFmpeg consumer commands copied to clipboard");
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
