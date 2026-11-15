using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using PcAudioStreamer.Audio;
using PcAudioStreamer.Discovery;
using PcAudioStreamer.Protocol;

namespace PcAudioStreamer;

public partial class MainWindow : Window
{
    private const string StartupRegistryKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string StartupValueName = "AirPulse";

    private readonly BleDiscoveryServer _bleDiscovery = new();
    private readonly WasapiAudioStreamer _audioStreamer = new();
    private readonly DispatcherTimer _uiTimer;
    private System.Windows.Forms.NotifyIcon? _trayIcon;
    private bool _allowRealExit;
    private bool _shownTrayTipOnce;
    private long _lastBytesSnapshot;
    private DateTime _lastSnapshotTime = DateTime.UtcNow;

    public MainWindow()
    {
        InitializeComponent();
        InitializeSystemTrayIcon();

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
        Closing += MainWindow_Closing;
        Closed += MainWindow_Closed;
    }

    private void InitializeSystemTrayIcon()
    {
        try
        {
            _trayIcon = new System.Windows.Forms.NotifyIcon
            {
                Text = "AirPulse — PC to iPhone Audio Streamer (Running)",
                Visible = true
            };

            var resourceStream = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/app.ico"));
            if (resourceStream != null)
            {
                _trayIcon.Icon = new System.Drawing.Icon(resourceStream.Stream);
            }

            var menu = new System.Windows.Forms.ContextMenuStrip();
            var openItem = new System.Windows.Forms.ToolStripMenuItem("Open AirPulse Dashboard");
            openItem.Click += (_, _) => Dispatcher.BeginInvoke(ShowFromTray);
            menu.Items.Add(openItem);

            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());

            var quitItem = new System.Windows.Forms.ToolStripMenuItem("Quit AirPulse Completely");
            quitItem.Click += (_, _) => Dispatcher.BeginInvoke(() =>
            {
                _allowRealExit = true;
                Close();
            });
            menu.Items.Add(quitItem);

            _trayIcon.ContextMenuStrip = menu;
            _trayIcon.DoubleClick += (_, _) => Dispatcher.BeginInvoke(ShowFromTray);
            _trayIcon.MouseClick += (_, e) =>
            {
                if (e.Button == System.Windows.Forms.MouseButtons.Left)
                {
                    Dispatcher.BeginInvoke(ShowFromTray);
                }
            };
        }
        catch
        {
            // Ignore tray creation errors
        }
    }

    private void ShowFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        RefreshPlaybackDevices();

        // Ensure Windows Startup auto-run is registered by default
        SetWindowsStartupEnabled(true);

        int port = ParsePort();
        await _bleDiscovery.StartAsync(port);
        StartStreamingInternal();

        // If launched by Windows Startup with --minimized, hide to System Tray immediately
        string[] args = Environment.GetCommandLineArgs();
        if (args.Any(a => a.Equals("--minimized", StringComparison.OrdinalIgnoreCase)))
        {
            Hide();
        }
    }

    private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_allowRealExit)
        {
            // Hide to System Tray instead of closing!
            e.Cancel = true;
            Hide();

            if (!_shownTrayTipOnce && _trayIcon != null)
            {
                _shownTrayTipOnce = true;
                _trayIcon.ShowBalloonTip(
                    2500,
                    "AirPulse đang chạy ngầm",
                    "Ứng dụng tiếp tục chạy ở khay hệ thống (System Tray). Nhấp vào biểu tượng AirPulse để mở lại.",
                    System.Windows.Forms.ToolTipIcon.Info
                );
            }
        }
    }

    private void MainWindow_Closed(object? sender, EventArgs e)
    {
        _uiTimer.Stop();
        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
        }
        _audioStreamer.Dispose();
        _bleDiscovery.Dispose();
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left)
        {
            try { DragMove(); } catch { }
        }
    }

    private void MinimizeBtn_Click(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState.Minimized;
    }

    private void CloseToTrayBtn_Click(object sender, RoutedEventArgs e)
    {
        Close(); // Triggers MainWindow_Closing which hides to System Tray
    }

    private void AutoStartCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (AutoStartCheckBox != null)
        {
            SetWindowsStartupEnabled(AutoStartCheckBox.IsChecked == true);
        }
    }

    private static void SetWindowsStartupEnabled(bool enable)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(StartupRegistryKey, writable: true);
            if (key == null)
                return;

            if (enable)
            {
                string exePath = Path.Combine(AppContext.BaseDirectory, "PcAudioStreamer.exe");
                if (!File.Exists(exePath))
                {
                    exePath = Process.GetCurrentProcess().MainModule?.FileName ?? exePath;
                }
                key.SetValue(StartupValueName, $"\"{exePath}\" --minimized");
            }
            else
            {
                key.DeleteValue(StartupValueName, throwOnMissingValue: false);
            }
        }
        catch
        {
            // Ignore registry permission errors
        }
    }

    private void RefreshPlaybackDevices()
    {
        var devices = WasapiAudioStreamer.GetPlaybackDevices();
        DeviceComboBox.ItemsSource = devices;
        if (devices.Count > 0)
        {
            DeviceComboBox.SelectedIndex = 0;
        }
    }

    private void DeviceComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DeviceComboBox.SelectedItem is AudioDeviceItem selected && _audioStreamer.IsStreaming)
        {
            _audioStreamer.SwitchCaptureDevice(selected.Id);
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
        if (_audioStreamer != null && CodecComboBox != null)
        {
            _audioStreamer.UseOpusCodec = CodecComboBox.SelectedIndex == 1;
        }
    }

    private void MutePcCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (_audioStreamer != null && MutePcCheckBox != null)
        {
            _audioStreamer.MutePcSpeaker = MutePcCheckBox.IsChecked == true;
        }
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
            StartStopBorder.Background = new LinearGradientBrush(
                System.Windows.Media.Color.FromRgb(14, 165, 233),
                System.Windows.Media.Color.FromRgb(37, 99, 235),
                45.0
            );
            FrameSizeComboBox.IsEnabled = true;
            TelemetryText.Text = "Status: Stopped";
            PeakMeterBar.Value = 0;
            return;
        }

        StartStreamingInternal();
    }

    private void StartStreamingInternal()
    {
        if (_audioStreamer.IsStreaming)
            return;

        try
        {
            var selectedDevice = DeviceComboBox.SelectedItem as AudioDeviceItem;
            int port = ParsePort();

            _audioStreamer.UseOpusCodec = CodecComboBox.SelectedIndex == 1;
            _audioStreamer.FrameDurationMs = 10;
            _audioStreamer.VolumeGain = (float)(VolumeSlider.Value / 100.0);
            _audioStreamer.MutePcSpeaker = MutePcCheckBox.IsChecked == true;

            _lastBytesSnapshot = 0;
            _lastSnapshotTime = DateTime.UtcNow;

            _audioStreamer.Start(selectedDevice?.Id, port, TargetIpTextBox.Text, port);

            StartStopBtn.Content = "STOP STREAMING";
            StartStopBorder.Background = new LinearGradientBrush(
                System.Windows.Media.Color.FromRgb(220, 38, 38),
                System.Windows.Media.Color.FromRgb(153, 27, 27),
                45.0
            );
            FrameSizeComboBox.IsEnabled = false;
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show($"Failed to start WASAPI audio stream:\n{ex.Message}", "Audio Streamer Error", MessageBoxButton.OK, MessageBoxImage.Error);
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
            TelemetryText.Text = $"Streaming: {codecName} (10ms) • {kbps:F1} kbps • Packets: {_audioStreamer.TotalPacketsSent:N0}";
        }
    }

    private int ParsePort()
    {
        if (int.TryParse(UdpPortTextBox.Text.Trim(), out int port) && port is > 1024 and <= 65535)
            return port;
        return AudioPacketProtocol.DefaultUdpPort;
    }
}
