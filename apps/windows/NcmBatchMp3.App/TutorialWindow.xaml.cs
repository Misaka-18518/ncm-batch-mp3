using System.Windows;

namespace NcmBatchMp3.App;

public partial class TutorialWindow : Window
{
    public TutorialWindow()
    {
        InitializeComponent();
        ThemeManager.ThemeChanged += ThemeManager_ThemeChanged;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        ApplyWindowTheme(ThemeManager.IsDarkMode);
    }

    private void ThemeManager_ThemeChanged(bool darkMode)
    {
        if (new System.Windows.Interop.WindowInteropHelper(this).Handle != IntPtr.Zero)
        {
            ApplyWindowTheme(darkMode);
        }
    }

    private void ApplyWindowTheme(bool darkMode)
    {
        Background = MicaBackdrop.TryApply(this, darkMode)
            ? System.Windows.Media.Brushes.Transparent
            : new System.Windows.Media.SolidColorBrush(ThemeManager.FallbackWindowColor(darkMode));
    }

    private void Close_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        ThemeManager.ThemeChanged -= ThemeManager_ThemeChanged;
        base.OnClosed(e);
    }
}
