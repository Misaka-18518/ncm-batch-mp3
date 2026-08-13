using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using MediaColor = System.Windows.Media.Color;
using WpfApplication = System.Windows.Application;

namespace NcmBatchMp3.App;

internal static class ThemeManager
{
    private const string PersonalizeKey = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private static bool? _manualDarkMode;
    private static bool _isListening;

    public static bool IsDarkMode { get; private set; }
    public static event Action<bool>? ThemeChanged;

    public static void Initialize()
    {
        Apply(ReadSystemDarkMode());
        try
        {
            SystemEvents.UserPreferenceChanged += SystemEvents_UserPreferenceChanged;
            _isListening = true;
        }
        catch
        {
            // Theme watching can be unavailable in compatibility environments.
        }
    }

    public static void ToggleManualMode()
    {
        _manualDarkMode = !IsDarkMode;
        Apply(_manualDarkMode.Value);
    }

    public static void Shutdown()
    {
        if (_isListening)
        {
            SystemEvents.UserPreferenceChanged -= SystemEvents_UserPreferenceChanged;
            _isListening = false;
        }
    }

    public static MediaColor FallbackWindowColor(bool dark)
    {
        return dark ? MediaColor.FromRgb(20, 21, 23) : MediaColor.FromRgb(245, 245, 243);
    }

    private static void SystemEvents_UserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (_manualDarkMode is not null || WpfApplication.Current is null)
        {
            return;
        }

        WpfApplication.Current.Dispatcher.BeginInvoke(() => Apply(ReadSystemDarkMode()));
    }

    private static bool ReadSystemDarkMode()
    {
        try
        {
            return Registry.GetValue(PersonalizeKey, "AppsUseLightTheme", 1) is int value && value == 0;
        }
        catch
        {
            return false;
        }
    }

    private static void Apply(bool dark)
    {
        IsDarkMode = dark;
        var resources = WpfApplication.Current.Resources;

        SetBrush(resources, "InkBrush", dark ? "#F2F3F5" : "#17191C");
        SetBrush(resources, "MutedBrush", dark ? "#A9AFB7" : "#6A7078");
        SetBrush(resources, "LineBrush", dark ? "#465A5D62" : "#2A5A5D62");
        SetBrush(resources, "SurfaceBrush", dark ? "#D9242629" : "#EFFFFFFF");
        SetBrush(resources, "CanvasBrush", dark ? "#D6141517" : "#DDF5F5F3");
        SetBrush(resources, "FieldBrush", dark ? "#E32B2D31" : "#E8FFFFFF");
        SetBrush(resources, "HoverBrush", dark ? "#34373B" : "#F0F0EE");
        SetBrush(resources, "HoverLineBrush", dark ? "#64686E" : "#BFC1C4");
        SetBrush(resources, "PressedBrush", dark ? "#1E2023" : "#E7E7E4");
        SetBrush(resources, "PrimaryBackgroundBrush", dark ? "#F2F3F5" : "#17191C");
        SetBrush(resources, "PrimaryForegroundBrush", dark ? "#151719" : "#FFFFFF");
        SetBrush(resources, "PrimaryHoverBrush", dark ? "#DDE0E4" : "#2B2E32");
        SetBrush(resources, "PrimaryPressedBrush", dark ? "#C8CCD1" : "#050607");
        SetBrush(resources, "SubtleSurfaceBrush", dark ? "#D1292B2F" : "#F7F7F5");
        SetBrush(resources, "RaisedSurfaceBrush", dark ? "#E01E2023" : "#FCFCFB");
        SetBrush(resources, "EmphasisSurfaceBrush", dark ? "#3A3D42" : "#ECECE9");
        SetBrush(resources, "StrongLineBrush", dark ? "#5E6268" : "#C9CACC");

        ThemeChanged?.Invoke(dark);
    }

    private static void SetBrush(ResourceDictionary resources, string key, string color)
    {
        resources[key] = new SolidColorBrush((MediaColor)System.Windows.Media.ColorConverter.ConvertFromString(color));
    }
}
