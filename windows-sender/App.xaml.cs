using System;
using System.IO;
using System.Windows;

namespace PcAudioStreamer;

public partial class App : Application
{
    public App()
    {
        DispatcherUnhandledException += (s, e) =>
        {
            File.WriteAllText("crash.log", e.Exception.ToString());
            e.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (s, e) =>
        {
            File.WriteAllText("crash.log", e.ExceptionObject?.ToString() ?? "Unknown crash");
        };
    }
}
