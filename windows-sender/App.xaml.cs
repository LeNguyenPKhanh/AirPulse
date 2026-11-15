using System;
using System.Diagnostics;
using System.IO;
using System.Windows;

namespace PcAudioStreamer;

public partial class App : Application
{
    public App()
    {
        // Close any previous running instance of PcAudioStreamer so only one window & UDP listener is active
        try
        {
            var current = Process.GetCurrentProcess();
            foreach (var proc in Process.GetProcessesByName(current.ProcessName))
            {
                if (proc.Id != current.Id)
                {
                    try { proc.Kill(); } catch { }
                }
            }
        }
        catch { }

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
