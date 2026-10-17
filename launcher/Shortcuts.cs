using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace GamingScrcpyLauncher;

// v3 §3: the shortcut list the launcher shows is data, not prose, so it can be
// validated by the gate instead of being trusted. Every row is
// (category key, literal combination, action key, description key): the two
// text cells go through Loc so Spanish and English cannot drift apart, and the
// combination stays literal because a key cap is not a translatable word.
//
// Nothing here is invented. The Super/Alt+F1-F5 rows are this fork's own
// handler (app/src/gaming.c, gaming_event_watch), the MOD+ rows are upstream
// v5.0.1's documented shortcuts (doc/shortcuts.md), and MOD means the shortcut
// modifier, which the fork leaves at upstream's default of left Alt or left
// Super (options.c shortcut_mods, changed with --shortcut-mod).
public sealed record ShortcutRow(string Category, string Combo, string ActionKey, string DescriptionKey);

public static class Shortcuts
{
    public static readonly string[] Categories =
    {
        "ScCatMirror", "ScCatRecord", "ScCatFilters", "ScCatWindow", "ScCatOther",
    };

    public static readonly IReadOnlyList<ShortcutRow> Table = new List<ShortcutRow>
    {
        // Mirror: the fork's own keys first, then the device keys that matter
        // while playing.
        new("ScCatMirror", "Super/Alt+F1", "ScActOsd", "ScDescOsd"),
        new("ScCatMirror", "Super/Alt+F3", "ScActTouch", "ScDescTouch"),
        new("ScCatMirror", "Super/Alt+F4", "ScActCursor", "ScDescCursor"),
        new("ScCatMirror", "MOD+O", "ScActScreenOff", "ScDescScreenOff"),
        new("ScCatMirror", "MOD+Shift+O", "ScActScreenOn", "ScDescScreenOn"),
        new("ScCatMirror", "MOD+R", "ScActRotateDevice", "ScDescRotateDevice"),
        new("ScCatMirror", "MOD+H", "ScActHome", "ScDescHome"),
        new("ScCatMirror", "MOD+B", "ScActBack", "ScDescBack"),
        new("ScCatMirror", "MOD+S", "ScActAppSwitch", "ScDescAppSwitch"),
        new("ScCatMirror", "MOD+M", "ScActMenu", "ScDescMenu"),
        new("ScCatMirror", "MOD+Up / Down", "ScActVolume", "ScDescVolume"),
        new("ScCatMirror", "MOD+P", "ScActPower", "ScDescPower"),

        // Window
        new("ScCatWindow", "Super/Alt+F2", "ScActBorderless", "ScDescBorderless"),
        new("ScCatWindow", "Super/Alt+F5", "ScActOnTop", "ScDescOnTop"),
        new("ScCatWindow", "MOD+F / F11", "ScActFullscreen", "ScDescFullscreen"),
        new("ScCatWindow", "MOD+G", "ScActFit", "ScDescFit"),
        new("ScCatWindow", "MOD+W", "ScActCrop", "ScDescCrop"),
        new("ScCatWindow", "MOD+Shift+N", "ScActCollapse", "ScDescCollapse"),
        new("ScCatWindow", "MOD+Q", "ScActQuit", "ScDescQuit"),

        // Other
        new("ScCatOther", "MOD+C", "ScActCopy", "ScDescCopy"),
        new("ScCatOther", "MOD+V", "ScActPaste", "ScDescPaste"),
        new("ScCatOther", "MOD+Shift+V", "ScActInject", "ScDescInject"),
        new("ScCatOther", "MOD+I", "ScActFps", "ScDescFps"),
        new("ScCatOther", "MOD+Z", "ScActPause", "ScDescPause"),
        new("ScCatOther", "MOD+Shift+Z", "ScActUnpause", "ScDescUnpause"),
        new("ScCatOther", "MOD+Shift+R", "ScActResetEncoder", "ScDescResetEncoder"),
        new("ScCatOther", "MOD+N", "ScActNotifications", "ScDescNotifications"),
    };

    // Categories with no rows are not shown: scrcpy 5 has no recording or
    // filter hotkey, and the alternative was to print a key that does nothing,
    // which is the exact failure mode v3 §1.2 forbids for audio.
    public static IEnumerable<string> ShownCategories(IEnumerable<ShortcutRow> rows) =>
        from cat in Categories
        where rows.Any(r => r.Category == cat)
        select cat;

    public static List<string> Validate(IEnumerable<ShortcutRow> rows)
    {
        var problems = new List<string>();
        var keys = new HashSet<string>(Loc.Keys);
        var seen = new HashSet<string>();
        var count = 0;

        foreach (var r in rows)
        {
            count++;
            if (string.IsNullOrWhiteSpace(r.Combo))
            {
                problems.Add($"row {count}: empty key combination");
            }
            if (!Categories.Contains(r.Category))
            {
                problems.Add($"row {count}: unknown category '{r.Category}'");
            }
            foreach (var key in new[] { r.ActionKey, r.DescriptionKey })
            {
                if (!keys.Contains(key))
                {
                    problems.Add($"row {count}: '{key}' is not in the Loc table");
                }
                else if (string.IsNullOrWhiteSpace(Loc.T(key)))
                {
                    problems.Add($"row {count}: '{key}' has no text in this language");
                }
            }
            if (!seen.Add(r.Category + "\n" + (r.Combo ?? "").Trim()))
            {
                problems.Add($"duplicate combination '{r.Combo}' in category '{r.Category}'");
            }
        }

        if (count == 0)
        {
            problems.Add("the shortcut table is empty");
        }
        return problems;
    }

    // The gate feeds a fixture through this to prove the duplicate check is not
    // decorative; the fixture is plain JSON so it can be edited by hand.
    public static List<ShortcutRow> LoadFile(string path)
    {
        using var fs = File.OpenRead(path);
        var doc = JsonDocument.Parse(fs);
        var rows = new List<ShortcutRow>();
        foreach (var el in doc.RootElement.EnumerateArray())
        {
            rows.Add(new ShortcutRow(
                Str(el, "category"), Str(el, "combo"),
                Str(el, "action"), Str(el, "description")));
        }
        return rows;
    }

    private static string Str(JsonElement el, string name) =>
        el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : "";
}
