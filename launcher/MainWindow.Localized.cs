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
            UpdateCommandPreview();
            TxtStatus.Text = Loc.Format("StatusLangChanged", Loc.LanguageName(code));
        }

        private Slider? SliderFor(string which) => which switch
        {
            "sharp" => SldSharp,
            "night" => SldNight,
            "sat" => SldSat,
            _ => null,
        };

        private void OnResetFilter(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement fe || fe.Tag is not string tag)
            {
                return;
            }
            switch (tag)
            {
                case "sharp":
                    ChkFxSharp.IsChecked = false;
                    if (SliderFor("sharp") is { } s) s.Value = 0;
                    break;
                case "night":
                    ChkFxNight.IsChecked = false;
                    if (SliderFor("night") is { } n) n.Value = 0;
                    break;
                case "sat":
                    ChkFxSat.IsChecked = false;
                    if (SliderFor("sat") is { } t) t.Value = 100;
                    break;
            }
            PushConfig();
        }

        private void OnColorProfile(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement fe || fe.Tag is not string tag)
            {
                return;
            }
            // (sharp, night, sat, enabled flags) -- all of these map to real
            // fork flags today; nothing here is decorative.
            (bool fx, double sharp, double night, double sat) p = tag switch
            {
                "vivid" => (true, 25, 15, 140),
                "cinematic" => (true, 45, 55, 92),
                "night" => (true, 20, 85, 110),
                _ => (false, 0, 0, 100),
            };
            ChkFxSharp.IsChecked = p.fx;
            ChkFxNight.IsChecked = p.fx;
            ChkFxSat.IsChecked = p.fx;
            if (SliderFor("sharp") is { } s) s.Value = p.sharp;
            if (SliderFor("night") is { } n) n.Value = p.night;
            if (SliderFor("sat") is { } t) t.Value = p.sat;
            PushConfig();
        }

        private void PushConfig()
        {
            _cfg = Collect();
            RefreshLabels();
            UpdateCommandPreview();
        }

        private void OnShowShortcuts(object sender, RoutedEventArgs e)
        {
            MessageBox.Show(this, Loc.T("HintShortcuts"), Loc.T("SecShortcuts"),
                            MessageBoxButton.OK, MessageBoxImage.Information);
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
