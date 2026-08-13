using System.Windows;
using MessageBox = System.Windows.MessageBox;

namespace NcmBatchMp3.App;

public partial class App : System.Windows.Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(
                $"应用遇到错误：\n{args.Exception.Message}",
                "NCM 批量转 MP3",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            args.Handled = true;
        };
        ThemeManager.Initialize();
        base.OnStartup(e);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        ThemeManager.Shutdown();
        base.OnExit(e);
    }
}
