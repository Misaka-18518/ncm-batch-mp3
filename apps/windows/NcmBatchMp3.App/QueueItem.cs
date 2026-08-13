using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;

namespace NcmBatchMp3.App;

public enum QueueStatus
{
    Queued,
    Running,
    Finished,
    Failed,
    Cancelled
}

public sealed class QueueItem : INotifyPropertyChanged
{
    private QueueStatus _status = QueueStatus.Queued;
    private string _detail = "等待";
    private string _outputPath = string.Empty;
    private double _progress;

    public QueueItem(string filePath)
    {
        FilePath = filePath;
    }

    public string FilePath { get; }
    public string FileName => Path.GetFileName(FilePath);
    public string DisplayPath => string.IsNullOrWhiteSpace(OutputPath)
        ? Path.GetDirectoryName(FilePath) ?? FilePath
        : OutputPath;

    public QueueStatus Status
    {
        get => _status;
        set
        {
            if (SetField(ref _status, value))
            {
                OnPropertyChanged(nameof(StatusGlyph));
            }
        }
    }

    public string StatusGlyph => Status switch
    {
        QueueStatus.Running => "◌",
        QueueStatus.Finished => "✓",
        QueueStatus.Failed => "!",
        QueueStatus.Cancelled => "–",
        _ => "·"
    };

    public string Detail
    {
        get => _detail;
        set => SetField(ref _detail, value);
    }

    public string OutputPath
    {
        get => _outputPath;
        set
        {
            if (SetField(ref _outputPath, value))
            {
                OnPropertyChanged(nameof(DisplayPath));
            }
        }
    }

    public double Progress
    {
        get => _progress;
        set => SetField(ref _progress, value);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }
        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
