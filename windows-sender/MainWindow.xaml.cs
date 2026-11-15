using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using PcAudioStreamer.Audio;
using PcAudioStreamer.Discovery;
using PcAudioStreamer.Protocol;

namespace PcAudioStreamer;

public partial class MainWindow : Window
{
    private readonly BleDiscoveryServer _bleDiscovery = new();
    private readonly WasapiAudioStreamer _audioStreamer = new();
    private readonly DispatcherTimer _uiTimer;
    private long _lastBytesSnapshot;
    private DateTime _lastSnapshotTime = DateTime.UtcNow;

    public MainWindow()
    {
        InitializeComponent();

        _bleDiscovery.StatusChanged += status =>
        {
            Dispatcher.BeginInvoke(() => BleStatusText.Text = status);
        };

        _audioStreamer.ClientConnected += info =>
        {
            Dispatcher.BeginInvoke(() => ClientStatusText.Text = info);
        };

        _uiTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(50)
        };
        _uiTimer.Tick += OnUiTimerTick;
        _uiTimer.Start();

        Loaded += MainWindow_Loaded;
        Closed += MainWindow_Closed;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        RefreshPlaybackDevices();
        int port = ParsePort();
        await _bleDiscovery.StartAsync(port);
    }

    private void MainWindow_Closed(object? sender, EventArgs e)
    {
        _uiTimer.Stop();
        _audioStreamer.Dispose();
        _bleDiscovery.Dispose();
    }

    private void RefreshPlaybackDevices()
    {
        var devices = WasapiAudioStreamer.GetPlaybackDevices();
        DeviceComboBox.ItemsSource = devices;
        var defaultDevice = devices.FirstOrDefault(d => d.IsDefault) ?? devices.FirstOrDefault();
        if (defaultDevice != null)
        {
            DeviceComboBox.SelectedItem = defaultDevice;
        }
    }

    private void RefreshDevicesBtn_Click(object sender, RoutedEventArgs e)
    {
        RefreshPlaybackDevices();
    }

    private void ApplyTargetBtn_Click(object sender, RoutedEventArgs e)
    {
        string ip = TargetIpTextBox.Text.Trim();
        int port = ParsePort();
        if (!string.IsNullOrWhiteSpace(ip))
        {
            _audioStreamer.SetManualTarget(ip, port);
        }
    }

    private void CodecComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _audioStreamer.UseOpusCodec = CodecComboBox.SelectedIndex == 0;
    }

    private void VolumeSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (VolumeValueText != null)
        {
            int pct = (int)Math.Round(e.NewValue);
            VolumeValueText.Text = $"{pct}%";
            _audioStreamer.VolumeGain = (float)(e.NewValue / 100.0);
        }
    }

    private void StartStopBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_audioStreamer.IsStreaming)
        {
            _audioStreamer.Stop();
            StartStopBtn.Content = "START STREAMING TO IPHONE";
            StartStopBtn.Background = new SolidColorBrush(Color.FromRgb(2, 132, 199));
            DeviceComboBox.IsEnabled = true;
            FrameSizeComboBox.IsEnabled = true;
            TelemetryText.Text = "Status: Stopped";
            PeakMeterBar.Value = 0;
            return;
        }

        try
        {
            var selectedDevice = DeviceComboBox.SelectedItem as AudioDeviceItem;
            int port = ParsePort();

            _audioStreamer.UseOpusCodec = CodecComboBox.SelectedIndex == 0;
            _audioStreamer.FrameDurationMs = FrameSizeComboBox.SelectedIndex == 1 ? 10 : 5;
            _audioStreamer.VolumeGain = (float)(VolumeSlider.Value / 100.0);

            _lastBytesSnapshot = 0;
            _lastSnapshotTime = DateTime.UtcNow;

            _audioStreamer.Start(selectedDevice?.Id, port, TargetIpTextBox.Text, port);

            StartStopBtn.Content = "STOP STREAMING";
            StartStopBtn.Background = new SolidColorBrush(Color.FromRgb(220, 38, 38));
            DeviceComboBox.IsEnabled = false;
            FrameSizeComboBox.IsEnabled = false;
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Failed to start WASAPI audio stream:\n{ex.Message}", "Audio Streamer Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OnUiTimerTick(object? sender, EventArgs e)
    {
        if (!_audioStreamer.IsStreaming)
            return;

        PeakMeterBar.Value = Math.Clamp(_audioStreamer.CurrentPeakLevel * 100.0, 0.0, 100.0);

        var now = DateTime.UtcNow;
        double elapsedSec = (now - _lastSnapshotTime).TotalSeconds;
        if (elapsedSec >= 0.5)
        {
            long currentBytes = _audioStreamer.TotalBytesSent;
            long deltaBytes = currentBytes - _lastBytesSnapshot;
            double kbps = (deltaBytes * 8.0) / (elapsedSec * 1000.0);

            _lastBytesSnapshot = currentBytes;
            _lastSnapshotTime = now;

            string codecName = _audioStreamer.UseOpusCodec ? "Opus 48kHz" : "Raw PCM16 48kHz";
            TelemetryText.Text = $"Streaming: {codecName} ({_audioStreamer.FrameDurationMs}ms) • {kbps:F1} kbps • Packets: {_audioStreamer.TotalPacketsSent:N0}";
        }
    }

    private int ParsePort()
    {
        if (int.TryParse(UdpPortTextBox.Text.Trim(), out int port) && port is > 1024 and <= 65535)
            return port;
        return AudioPacketProtocol.DefaultUdpPort;
    }
}
