using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace GamingScrcpyLauncher;

// The ATAJOS list (v3 §3): grouped cards, three fixed columns -- key
// combination, short action, quiet description -- built inside the main window
// rather than in a separate one. An owned WPF window is not reliably visible to
// UI Automation while the launcher itself is, so a panel keeps the list
// measurable by gate section 17 and out of the taskbar.
public static class ShortcutsList
{
    public static void Build(Panel host)
    {
        host.Children.Clear();
        var index = 0;
        var first = true;
        foreach (var cat in Shortcuts.ShownCategories(Shortcuts.Table))
        {
            var rows = Shortcuts.Table.Where(r => r.Category == cat).ToList();
            var body = new StackPanel();
            foreach (var r in rows)
            {
                index++;
                body.Children.Add(Row(host, index, r));
            }

            if (rows.Count > 6)
            {
                // More than six rows in one group gets a collapse switch, and the
                // Expander header is the category title, so nothing repeats.
                var exp = new Expander
                {
                    Content = body,
                    IsExpanded = true,
                    Margin = new Thickness(0, first ? 0 : 8, 0, 8),
                };
                exp.SetResourceReference(HeaderedItemsControl.HeaderProperty, cat);
                AutomationProperties.SetAutomationId(exp, "ScGroup" + cat);
                host.Children.Add(exp);
            }
            else
            {
                var header = new TextBlock { Margin = new Thickness(0, first ? 0 : 8, 0, 8) };
                header.SetResourceReference(TextBlock.TextProperty, cat);
                header.SetResourceReference(TextBlock.ForegroundProperty, "Accent");
                header.FontFamily = (FontFamily)host.FindResource("Mono");
                header.FontSize = 12;
                host.Children.Add(header);
                host.Children.Add(body);
            }
            first = false;
        }
    }

    private static UIElement Row(Panel host, int index, ShortcutRow r)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(168) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(216) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        // The key cap: monospaced, its own background and border, radius 6. The
        // AutomationId goes on the TextBlock because a Border is a decorator and
        // has no automation peer, so an id on it is invisible to UI Automation.
        var capText = new TextBlock
        {
            Text = r.Combo,
            FontFamily = (FontFamily)host.FindResource("Mono"),
            FontSize = 12,
            Foreground = (Brush)host.FindResource("Fg"),
        };
        AutomationProperties.SetAutomationId(capText, $"Sc{index}Key");

        var cap = new Border
        {
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(8, 4, 8, 4),
            Margin = new Thickness(0, 0, 8, 0),
            MinWidth = 140,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = capText,
        };
        cap.SetResourceReference(Border.BackgroundProperty, "Panel2");
        cap.SetResourceReference(Border.BorderBrushProperty, "Line");

        var act = new TextBlock
        {
            FontSize = 13,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        act.SetResourceReference(TextBlock.TextProperty, r.ActionKey);
        act.SetResourceReference(TextBlock.ForegroundProperty, "Fg");
        AutomationProperties.SetAutomationId(act, $"Sc{index}Act");

        var desc = new TextBlock
        {
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
        };
        desc.SetResourceReference(TextBlock.TextProperty, r.DescriptionKey);
        desc.SetResourceReference(TextBlock.ForegroundProperty, "FgDim");
        AutomationProperties.SetAutomationId(desc, $"Sc{index}Desc");

        Grid.SetColumn(cap, 0);
        Grid.SetColumn(act, 1);
        Grid.SetColumn(desc, 2);
        grid.Children.Add(cap);
        grid.Children.Add(act);
        grid.Children.Add(desc);
        return grid;
    }
}
