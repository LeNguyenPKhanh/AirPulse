using System;
using System.Diagnostics;
using System.IO;

namespace PcAudioStreamer;

public partial class App : System.Windows.Application
{
    public App()
    {
        // Close any previous running instance of PcAudioStreamer so only one instance is active
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
