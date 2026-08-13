using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using NcmBatchMp3.Core;
using Forms = System.Windows.Forms;
using MessageBox = System.Windows.MessageBox;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;
using DragEventArgs = System.Windows.DragEventArgs;
using DataFormats = System.Windows.DataFormats;
using DragDropEffects = System.Windows.DragDropEffects;

namespace NcmBatchMp3.App;

public partial class MainWindow : Window
{
    private readonly NcmConverter _converter = new();
    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(7) };
    private CancellationTokenSource? _conversionCancellation;
    private string? _ffmpegPath;
    private bool _isConverting;
    private bool _updateCheckRunning;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        ThemeManager.ThemeChanged += ThemeManager_ThemeChanged;
        UpdateThemeIcon(ThemeManager.IsDarkMode);
        _httpClient.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("NCM-Batch-MP3", CurrentVersion));
    }

    public ObservableCollection<QueueItem> QueueItems { get; } = [];
    public ObservableCollection<string> Logs { get; } = [];

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        ApplyWindowTheme(ThemeManager.IsDarkMode);
    }

    private static string CurrentVersion
    {
        get
        {
            var version = Assembly.GetEntryAssembly()?.GetName().Version;
            return version is null ? "1.2.1" : $"{version.Major}.{version.Minor}.{Math.Max(0, version.Build)}";
        }
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        var musicDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyMusic);
        if (string.IsNullOrWhiteSpace(musicDirectory))
        {
            musicDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
        OutputDirectoryTextBox.Text = Path.Combine(musicDirectory, "NCM 转换输出");

        _ffmpegPath = FindFfmpeg();
        FfmpegStatusText.Text = _ffmpegPath is null ? "缺失" : "可用";
        AddLog("原生转换核心已就绪");
        UpdateInterface();

        await Task.Delay(1200);
        await CheckForUpdatesAsync(false);
    }

    private async void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "选择 NCM 文件",
            Filter = "网易云音乐 NCM (*.ncm)|*.ncm",
            Multiselect = true,
            CheckFileExists = true
        };
        if (dialog.ShowDialog(this) == true)
        {
            await AddPathsAsync(dialog.FileNames);
        }
    }

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        using var dialog = new Forms.FolderBrowserDialog
        {
            Description = "选择包含 NCM 文件的文件夹",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = false
        };
        if (dialog.ShowDialog() == Forms.DialogResult.OK)
        {
            await AddPathsAsync([dialog.SelectedPath]);
        }
    }

    private async Task AddPathsAsync(IEnumerable<string> paths)
    {
        var recursive = RecursiveCheckBox.IsChecked == true;
        OverallStatusText.Text = "正在读取文件…";
        var files = await Task.Run(() => CollectNcmFiles(paths, recursive));
        var existing = new HashSet<string>(QueueItems.Select(item => item.FilePath), StringComparer.OrdinalIgnoreCase);
        var added = 0;

        foreach (var path in files)
        {
            if (existing.Add(path))
            {
                QueueItems.Add(new QueueItem(path));
                added++;
            }
        }

        if (added > 0)
        {
            AddLog($"已添加 {added} 个 NCM 文件");
        }
        OverallStatusText.Text = added > 0 ? $"已添加 {added} 个文件" : "没有发现新的 NCM 文件";
        UpdateInterface();
    }

    private static IReadOnlyList<string> CollectNcmFiles(IEnumerable<string> paths, bool recursive)
    {
        var results = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var candidate in paths)
        {
            try
            {
                if (File.Exists(candidate) && Path.GetExtension(candidate).Equals(".ncm", StringComparison.OrdinalIgnoreCase))
                {
                    results.Add(Path.GetFullPath(candidate));
                    continue;
                }

                if (!Directory.Exists(candidate))
                {
                    continue;
                }

                var options = new EnumerationOptions
                {
                    RecurseSubdirectories = recursive,
                    IgnoreInaccessible = true,
                    // Skip junctions and symlinks so a directory cycle cannot loop forever.
                    AttributesToSkip = FileAttributes.ReparsePoint
                };
                foreach (var file in Directory.EnumerateFiles(candidate, "*.ncm", options))
                {
                    results.Add(Path.GetFullPath(file));
                }
            }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException)
            {
                // Keep readable files from the same drop even if one folder is protected.
            }
        }

        return results.Order(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (_isConverting || QueueList.SelectedItem is not QueueItem selected)
        {
            return;
        }
        QueueItems.Remove(selected);
        UpdateInterface();
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        if (_isConverting)
        {
            return;
        }
        QueueItems.Clear();
        Logs.Clear();
        OverallProgressBar.Value = 0;
        OverallStatusText.Text = "就绪";
        UpdateInterface();
    }

    private void QueueList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateInterface();
    }

    private void Tutorial_Click(object sender, RoutedEventArgs e)
    {
        new TutorialWindow { Owner = this }.ShowDialog();
    }

    private void ChooseOutput_Click(object sender, RoutedEventArgs e)
    {
        using var dialog = new Forms.FolderBrowserDialog
        {
            Description = "选择输出目录",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true,
            SelectedPath = OutputDirectoryTextBox.Text
        };
        if (dialog.ShowDialog() == Forms.DialogResult.OK)
        {
            OutputDirectoryTextBox.Text = dialog.SelectedPath;
        }
    }

    private void OpenOutput_Click(object sender, RoutedEventArgs e)
    {
        var directory = OutputDirectoryTextBox.Text.Trim();
        if (directory.Length == 0)
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(directory);
            Process.Start(new ProcessStartInfo(directory) { UseShellExecute = true });
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法打开输出目录", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void Start_Click(object sender, RoutedEventArgs e)
    {
        if (_isConverting || QueueItems.Count == 0)
        {
            return;
        }

        var outputDirectory = OutputDirectoryTextBox.Text.Trim();
        if (outputDirectory.Length == 0)
        {
            MessageBox.Show(this, "请选择输出目录。", "NCM 批量转 MP3", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        try
        {
            Directory.CreateDirectory(outputDirectory);
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法使用输出目录", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        foreach (var item in QueueItems)
        {
            item.Status = QueueStatus.Queued;
            item.Detail = "等待";
            item.OutputPath = string.Empty;
            item.Progress = 0;
        }

        _conversionCancellation = new CancellationTokenSource();
        SetConverting(true);
        AddLog($"开始转换 {QueueItems.Count} 个文件");
        var processed = 0;
        var failed = 0;
        var cancelled = false;

        var options = new ConversionOptions(
            outputDirectory,
            PreferMp3Radio.IsChecked == true ? OutputMode.PreferMp3 : OutputMode.Original,
            RenameCheckBox.IsChecked == true,
            OverwriteCheckBox.IsChecked == true);

        foreach (var item in QueueItems)
        {
            if (_conversionCancellation.IsCancellationRequested)
            {
                cancelled = true;
                item.Status = QueueStatus.Cancelled;
                item.Detail = "已取消";
                continue;
            }

            item.Status = QueueStatus.Running;
            item.Detail = "解密中";
            QueueList.ScrollIntoView(item);
            UpdateStats();

            var itemIndex = processed;
            var progress = new Progress<ConversionProgress>(value =>
            {
                item.Progress = value.Fraction;
                item.Detail = value.Phase == "transcode" ? "转码中" : "解密中";
                OverallProgressBar.Value = (itemIndex + value.Fraction) / QueueItems.Count;
                OverallStatusText.Text = $"{Path.GetFileName(item.FilePath)} · {Math.Round(value.Fraction * 100)}%";
            });

            try
            {
                var result = await _converter.ConvertAsync(
                    item.FilePath,
                    options,
                    _ffmpegPath,
                    _conversionCancellation.Token,
                    progress);
                item.Status = QueueStatus.Finished;
                item.Detail = result.Message;
                item.OutputPath = result.OutputPath;
                item.Progress = 1;
                AddLog($"完成 · {Path.GetFileName(result.OutputPath)}");
            }
            catch (OperationCanceledException)
            {
                cancelled = true;
                item.Status = QueueStatus.Cancelled;
                item.Detail = "已取消";
            }
            catch (Exception error)
            {
                failed++;
                item.Status = QueueStatus.Failed;
                item.Detail = "失败";
                AddLog($"失败 · {Path.GetFileName(item.FilePath)} · {ShortError(error.Message)}");
            }

            processed++;
            OverallProgressBar.Value = processed / (double)QueueItems.Count;
            UpdateStats();
        }

        OverallStatusText.Text = cancelled
            ? "转换已取消"
            : failed == 0
                ? $"全部完成 · {processed} 个文件"
                : $"转换完成 · {failed} 个失败";
        AddLog(cancelled ? "转换已取消" : "批量转换结束");
        SetConverting(false);
        _conversionCancellation.Dispose();
        _conversionCancellation = null;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        _conversionCancellation?.Cancel();
        CancelButton.IsEnabled = false;
        OverallStatusText.Text = "正在取消…";
    }

    private void Window_DragEnter(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private async void Window_Drop(object sender, DragEventArgs e)
    {
        if (_isConverting || e.Data.GetData(DataFormats.FileDrop) is not string[] paths)
        {
            return;
        }
        await AddPathsAsync(paths);
    }

    private async void CheckUpdate_Click(object sender, RoutedEventArgs e)
    {
        await CheckForUpdatesAsync(true);
    }

    private void Theme_Click(object sender, RoutedEventArgs e)
    {
        ThemeManager.ToggleManualMode();
    }

    private void ThemeManager_ThemeChanged(bool darkMode)
    {
        UpdateThemeIcon(darkMode);
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

    private void UpdateThemeIcon(bool darkMode)
    {
        ThemeButton.Content = darkMode ? "\uE708" : "\uE706";
    }

    private async Task CheckForUpdatesAsync(bool manual)
    {
        if (_updateCheckRunning)
        {
            return;
        }
        _updateCheckRunning = true;

        try
        {
            using var response = await _httpClient.GetAsync(UpdateRules.LatestReleaseApi);
            response.EnsureSuccessStatusCode();
            await using var stream = await response.Content.ReadAsStreamAsync();
            using var document = await JsonDocument.ParseAsync(stream);
            var root = document.RootElement;
            var tagName = root.TryGetProperty("tag_name", out var tag) ? tag.GetString() : null;
            var releaseUrl = root.TryGetProperty("html_url", out var url) ? url.GetString() : null;
            var officialUri = UpdateRules.OfficialReleaseUri(tagName, releaseUrl);
            if (officialUri is null)
            {
                throw new InvalidDataException("更新地址不可信");
            }

            if (UpdateRules.IsVersionNewer(tagName, CurrentVersion))
            {
                var answer = MessageBox.Show(
                    this,
                    $"NCM 批量转 MP3 {tagName} 已发布。\n\n前往 GitHub Release 下载最新版？",
                    "发现新版本",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information);
                if (answer == MessageBoxResult.Yes)
                {
                    Process.Start(new ProcessStartInfo(officialUri.AbsoluteUri) { UseShellExecute = true });
                }
            }
            else if (manual)
            {
                MessageBox.Show(this, "当前已是最新版本。", "检查更新", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }
        catch when (!manual)
        {
            // Startup checks stay silent when the machine is offline.
        }
        catch
        {
            MessageBox.Show(this, "暂时无法检查更新，请稍后再试。", "检查更新失败", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            _updateCheckRunning = false;
        }
    }

    private void EasterHeart_Click(object sender, RoutedEventArgs e)
    {
        EasterMessageText.Text = EasterEgg.Message(DateTime.Now);
        EasterOverlay.Visibility = Visibility.Visible;
    }

    private void EasterClose_Click(object sender, RoutedEventArgs e)
    {
        EasterOverlay.Visibility = Visibility.Collapsed;
    }

    private void EasterOverlay_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        EasterOverlay.Visibility = Visibility.Collapsed;
    }

    private void EasterCard_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
    }

    private void SetConverting(bool converting)
    {
        _isConverting = converting;
        AddFilesButton.IsEnabled = !converting;
        AddFolderButton.IsEnabled = !converting;
        ClearButton.IsEnabled = !converting && QueueItems.Count > 0;
        RemoveButton.IsEnabled = !converting && QueueList.SelectedItem is not null;
        StartButton.IsEnabled = !converting && QueueItems.Count > 0;
        CancelButton.IsEnabled = converting;
        OutputDirectoryTextBox.IsEnabled = !converting;
        PreferMp3Radio.IsEnabled = !converting;
        OriginalRadio.IsEnabled = !converting;
        RenameCheckBox.IsEnabled = !converting;
        OverwriteCheckBox.IsEnabled = !converting;
        RecursiveCheckBox.IsEnabled = !converting;
        UpdateInterface();
    }

    private void UpdateInterface()
    {
        EmptyState.Visibility = QueueItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        QueueSummaryText.Text = $"{QueueItems.Count} 个文件";
        StartButton.IsEnabled = !_isConverting && QueueItems.Count > 0;
        ClearButton.IsEnabled = !_isConverting && QueueItems.Count > 0;
        RemoveButton.IsEnabled = !_isConverting && QueueList.SelectedItem is not null;
        UpdateStats();
    }

    private void UpdateStats()
    {
        QueuedCountText.Text = QueueItems.Count(item => item.Status is QueueStatus.Queued or QueueStatus.Running).ToString();
        FinishedCountText.Text = QueueItems.Count(item => item.Status == QueueStatus.Finished).ToString();
        FailedCountText.Text = QueueItems.Count(item => item.Status == QueueStatus.Failed).ToString();
    }

    private void AddLog(string message)
    {
        Logs.Add($"{DateTime.Now:HH:mm:ss}  {message}");
        while (Logs.Count > 200)
        {
            Logs.RemoveAt(0);
        }
        if (Logs.Count > 0)
        {
            LogList.ScrollIntoView(Logs[^1]);
        }
    }

    private static string ShortError(string message)
    {
        var line = message.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "未知错误";
        return line.Length <= 120 ? line : line[..120] + "…";
    }

    private static string? FindFfmpeg()
    {
        var bundled = Path.Combine(AppContext.BaseDirectory, "ffmpeg", "ffmpeg.exe");
        if (File.Exists(bundled))
        {
            return bundled;
        }

        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(directory.Trim(), "ffmpeg.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch
            {
                // Ignore malformed PATH entries.
            }
        }

        return null;
    }

    protected override void OnClosed(EventArgs e)
    {
        ThemeManager.ThemeChanged -= ThemeManager_ThemeChanged;
        _conversionCancellation?.Cancel();
        _conversionCancellation?.Dispose();
        _httpClient.Dispose();
        base.OnClosed(e);
    }
}
