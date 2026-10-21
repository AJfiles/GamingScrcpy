using System;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace GamingScrcpyLauncher
{
    // The v2 additions that do not belong in the original 800-line window file:
    // language switching (hot), per-filter resets, one-click color profiles,
    // the read-only device panel, the shortcuts overlay and the live
    // performance panel fed by the child's --game-telemetry-log lines.
    public partial class MainWindow
    {
        private const string DefaultSharp = "35";
        private static readonly Regex TelemetryRx = new(
            @"telemetry:\s*fps=([0-9.]+)\s+v_kbps=(\d+)\s+a_kbps=(\d+)\s+lat=(\d+)ms",
            RegexOptions.Compiled);

        private readonly System.Collections.Generic.List<double> latencyHistory = new();

        // runs before InitializeComponent, so {DynamicResource} finds real
        // strings on the very first layout pass
        private readonly object _locBootstrap = Loc.Bootstrap();

        private static string LanguageSettingPath =>
            System.IO.Path.Combine(ProfileStore.Root, "language.txt");

        private void OnWindowLoaded(object sender, RoutedEventArgs e)
        {
            TryRestoreLanguage();
            // The child process output already lands in TxtLog; watching it is
            // the only way to get telemetry without changing the run path.
            TxtLog.TextChanged += (_, _) => ConsumeTelemetry();
        }

        private void TryRestoreLanguage()
        {
            try
            {
                if (File.Exists(LanguageSettingPath))
                {
                    string code = File.ReadAllText(LanguageSettingPath).Trim();
                    if (code.Length > 0)
                    {
                        Loc.Instance.Language = code;
                    }
                }
            }
            catch
            {
                // a broken settings file must never stop the UI from opening
            }
            SelectLanguageCombo();
        }

        private void SelectLanguageCombo()
        {
            if (CboLanguage == null)
            {
                return;
            }
            int want = Loc.Instance.Language == "es" ? 0 : 1;
            if (CboLanguage.SelectedIndex != want)
            {
                CboLanguage.SelectedIndex = want;
            }
        }

        private void OnLanguageChanged(object sender,
                                       SelectionChangedEventArgs e)
        {
            if (CboLanguage == null || CboLanguage.SelectedIndex < 0)
            {
                return;   // the initial selection happens before the restore
            }
            string code = CboLanguage.SelectedIndex == 0 ? "es" : "en";
            Loc.Instance.Language = code;
            try
            {
                Directory.CreateDirectory(ProfileStore.Root);
                File.WriteAllText(LanguageSettingPath, code);
            }
            catch
            {
                // persistence is best-effort; the switch itself already worked
            }
            // anything the code-behind sets imperatively has to be re-applied
            RefreshLabels();
            // the profile cells and the footer line are built as localized text,
            // so a language switch rebuilds them rather than re-showing old strings
            RefreshProfiles(adopt: false);
            UpdateProfilePendingHint();
            UpdateCommandPreview();
            TxtStatus.Text = Loc.Format("StatusLangChanged", Loc.LanguageName(code));
        }

        private Slider? SliderFor(string which) => which switch
        {
            "sharp" => SldSharp,
            "night" => SldNight,
            "sat" => SldSat,
            "contrast" => SldContrast,
            "bright" => SldBright,
            "gamma" => SldGamma,
            _ => null,
        };

        private CheckBox? CheckFor(string which) => which switch
        {
            "sharp" => ChkFxSharp,
            "night" => ChkFxNight,
            "sat" => ChkFxSat,
            "contrast" => ChkFxContrast,
            "bright" => ChkFxBright,
            "gamma" => ChkFxGamma,
            _ => null,
        };

        private static readonly string[] GradeFilters =
            { "sharp", "night", "sat", "contrast", "bright", "gamma" };

        // the additive filters start from nothing, the percent ones from 100
        private static double NeutralFor(string which) =>
            which is "sharp" or "night" ? 0 : 100;

        private void OnResetFilter(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement fe || fe.Tag is not string tag)
            {
                return;
            }
            if (CheckFor(tag) is { } chk)
            {
                chk.IsChecked = false;
            }
            if (SliderFor(tag) is { } s)
            {
                s.Value = NeutralFor(tag);
            }
            PushConfig();
        }

        private void OnColorProfile(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement fe || fe.Tag is not string tag)
            {
                return;
            }
            ApplyColorProfile(tag);
        }

        // Split from the click handler because the presentation shortcut reuses
        // it: "neutral" is not a look, it is every filter off and every slider at
        // its own zero, which is what a projector or a capture wants.
        private void ApplyColorProfile(string tag)
        {
            // Every number here maps to a real fork flag, and a profile only
            // enables the filters it actually moves: each enabled filter costs
            // host CPU on the frame path, so switching all six on for a look
            // would add latency the user did not ask for.
            (string[] On, Dictionary<string, double> Values) p = tag switch
            {
                "vivid" => (new[] { "sharp", "sat", "contrast" },
                            new Dictionary<string, double>
                            { ["sharp"] = 30, ["sat"] = 135, ["contrast"] = 118 }),
                "cinematic" => (new[] { "sharp", "night", "sat", "gamma", "contrast" },
                            new Dictionary<string, double>
                            {
                                ["sharp"] = 45, ["night"] = 25, ["sat"] = 92,
                                ["gamma"] = 115, ["contrast"] = 108,
                            }),
                "night" => (new[] { "sharp", "night", "bright", "gamma" },
                            new Dictionary<string, double>
                            {
                                ["sharp"] = 20, ["night"] = 85, ["bright"] = 112,
                                ["gamma"] = 130,
                            }),
                _ => (Array.Empty<string>(), new Dictionary<string, double>()),
            };
            foreach (string name in GradeFilters)
            {
                if (CheckFor(name) is { } chk)
                {
                    chk.IsChecked = Array.IndexOf(p.On, name) >= 0;
                }
                if (SliderFor(name) is { } s)
                {
                    s.Value = p.Values.TryGetValue(name, out double v) ? v : NeutralFor(name);
                }
            }
            PushConfig();
        }

        private void PushConfig()
        {
            _cfg = Collect();
            RefreshLabels();
            UpdateCommandPreview();
        }

        private bool _shortcutsBuilt;

        private void OnShowShortcuts(object sender, RoutedEventArgs e)
        {
            // v3 §3: a grouped keycap list, opened in place. It is built once and
            // re-localized through resource references, so switching language
            // while it is open updates every cell.
            if (!_shortcutsBuilt)
            {
                ShortcutsList.Build(ScGroups);
                _shortcutsBuilt = true;
            }
            var open = ScPanel.Visibility != Visibility.Visible;
            ScPanel.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
            if (open)
            {
                Reveal(ScPanel, "AnimPanel");
            }
        }

        // Profiles travel as one JSON array, so a machine can be set up by
        // copying a file instead of clicking through the configurator.
        private void OnExportProfiles(object sender, RoutedEventArgs e)
        {
            var dlg = new Microsoft.Win32.SaveFileDialog
            {
                FileName = "gamingscrcpy-profiles.json",
                Filter = "JSON|*.json",
            };
            if (dlg.ShowDialog(this) != true)
            {
                return;
            }
            var all = new System.Collections.Generic.List<AppConfig>();
            foreach (string file in ProfileStore.ListProfiles())
            {
                if (ProfileStore.LoadProfile(file) is { } cfg)
                {
                    all.Add(cfg);
                }
            }
            File.WriteAllText(dlg.FileName,
                              System.Text.Json.JsonSerializer.Serialize(all,
                                  new System.Text.Json.JsonSerializerOptions
                                  { WriteIndented = true }));
            TxtStatus.Text = Loc.Format("StatusExported", dlg.FileName);
        }

        private void OnImportProfiles(object sender, RoutedEventArgs e)
        {
            var dlg = new Microsoft.Win32.OpenFileDialog
            {
                Filter = "JSON|*.json",
                CheckFileExists = true,
            };
            if (dlg.ShowDialog(this) != true)
            {
                return;
            }
            int n = 0;
            try
            {
                var imported = System.Text.Json.JsonSerializer.Deserialize<AppConfig[]>(
                    File.ReadAllText(dlg.FileName));
                foreach (AppConfig cfg in imported ?? Array.Empty<AppConfig>())
                {
                    ProfileStore.SaveProfile(cfg);
                    ++n;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, Loc.Format("ErrBadValue", ex.Message),
                                Loc.T("AskTitle"), MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                return;
            }
            RefreshProfiles();
            TxtStatus.Text = Loc.Format("StatusImported", dlg.FileName + " (" + n + ")");
        }

        private async void OnRefreshDevice(object sender, RoutedEventArgs e)
        {
            string? serial = SelectedSerial();
            if (string.IsNullOrEmpty(serial))
            {
                TxtDeviceModel.Text = "--";
                TxtDeviceBattery.Text = "--";
                TxtDeviceTemp.Text = "--";
                return;
            }
            TxtDeviceModel.Text = await Adb.GetDevicePropAsync(serial, "ro.product.model");
            var (_, dump) = await Adb.RunAsync(
                "-s " + serial + " shell dumpsys battery");
            int level = MatchInt(dump, @"level:\s*(\d+)");
            int temp = MatchInt(dump, @"temperature:\s*(\d+)");
            TxtDeviceBattery.Text = level >= 0 ? level + " %" : "--";
            TxtDeviceTemp.Text = temp >= 0
                ? (temp / 10.0).ToString("0.#", CultureInfo.InvariantCulture) + " \u00b0C"
                : "--";
        }

        private static int MatchInt(string text, string pattern)
        {
            var m = Regex.Match(text ?? "", pattern);
            return m.Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)
                             : -1;
        }

        // The fork prints one telemetry line per second on the child's stdout;
        // the run log already carries them into TxtLog, so parse the tail.
        private void ConsumeTelemetry()
        {
            string text = TxtLog.Text ?? "";
            int start = text.LastIndexOf("telemetry:", StringComparison.Ordinal);
            if (start < 0)
            {
                return;
            }
            int end = text.IndexOf('\n', start);
            string line = end < 0 ? text[start..] : text[start..end];
            var m = TelemetryRx.Match(line);
            if (!m.Success)
            {
                return;
            }
            TxtPerfFps.Text = m.Groups[1].Value;
            TxtPerfVideo.Text = m.Groups[2].Value;
            TxtPerfAudio.Text = m.Groups[3].Value;
            TxtPerfLatency.Text = m.Groups[4].Value + " ms";

            latencyHistory.Add(double.Parse(m.Groups[4].Value,
                                            CultureInfo.InvariantCulture));
            if (latencyHistory.Count > 60)
            {
                latencyHistory.RemoveAt(0);
            }
            DrawSpark();
        }

        private void DrawSpark()
        {
            if (latencyHistory.Count < 2)
            {
                return;
            }
            double max = 1;
            foreach (double v in latencyHistory)
            {
                max = Math.Max(max, v);
            }
            var points = new PointCollection();
            for (int i = 0; i < latencyHistory.Count; ++i)
            {
                points.Add(new Point(i, latencyHistory[i] / max));
            }
            PerfSpark.Points = points;
        }
    }
}
