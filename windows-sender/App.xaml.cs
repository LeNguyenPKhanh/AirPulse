using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Principal;

namespace PcAudioStreamer;

public partial class App : System.Windows.Application
{
    public App()
    {
        var args = Environment.GetCommandLineArgs();
        bool fwOnly = args.Any(a => a.Equals("--fw-only", StringComparison.OrdinalIgnoreCase));

        // Close other instances unless this is a short-lived elevated firewall helper
        if (!fwOnly)
        {
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
        }

        EnsureFirewallRule();

        if (fwOnly)
        {
            Environment.Exit(0);
            return;
        }

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

    private static void EnsureFirewallRule()
    {
        try
        {
            var args = Environment.GetCommandLineArgs();
            bool elevatedAttempt = args.Any(a => a.Equals("--elevated-fw", StringComparison.OrdinalIgnoreCase));

            if (IsAdministrator())
            {
                AddFirewallRuleIfMissing();
                return;
            }

            // Non-admin: try silent add; if fails, elevate once to set up firewall then continue
            if (!TryAddFirewallRule(out _))
            {
                if (!elevatedAttempt)
                {
                    TryRelaunchElevatedForFirewall();
                }
            }
        }
        catch { }
    }

    private static bool IsAdministrator()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    private static void AddFirewallRuleIfMissing()
    {
        TryAddFirewallRule(out _);
    }

    private static bool TryAddFirewallRule(out string output)
    {
        output = "";
        try
        {
            // Delete existing then add to ensure correct ports/profile; ignore errors
            RunNetsh("advfirewall firewall delete rule name=\"AirPulse Audio Streamer (UDP)\"", out _);
            return RunNetsh(
                "advfirewall firewall add rule name=\"AirPulse Audio Streamer (UDP)\" dir=in action=allow protocol=UDP localport=49152,49153 profile=private,domain",
                out output);
        }
        catch { return false; }
    }

    private static bool RunNetsh(string arguments, out string output)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "netsh",
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            if (p == null) { output = ""; return false; }
            output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            p.WaitForExit(5000);
            return p.ExitCode == 0;
        }
        catch (Exception ex) { output = ex.Message; return false; }
    }

    private static void TryRelaunchElevatedForFirewall()
    {
        try
        {
            string? exe = Process.GetCurrentProcess().MainModule?.FileName;
            if (string.IsNullOrEmpty(exe)) return;

            // Spawn elevated helper instance to add rule only, then exit; current instance continues
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = "--elevated-fw --fw-only",
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(psi);
        }
        catch
        {
            // User may cancel UAC; app can still run if firewall already configured
        }
    }
}
