using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.Versioning;
using Microsoft.Win32;
using UniGetUI.Core.Data;
using UniGetUI.Core.Logging;
using UniGetUI.Core.Tools;

namespace UniGetUI.Avalonia.Infrastructure;

/// <summary>
/// Registers UniGetUI as a Windows Update Orchestration Platform (UOP) provider, so Windows Update
/// schedules package updates alongside its own. The work happens in
/// Assets\Utilities\unigetui_uop_registration.ps1, which must run elevated; see docs/WINDOWS_UPDATE.md.
/// </summary>
internal static class WindowsUpdateProviderRegistration
{
    // Inno Setup uninstall key of a machine-wide install; the provider.json ProductCode points to it
    private const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{889610CC-4337-4BDB-AC3B-4F21806C0BDE}_is1";
    private const string MarkerKey = @"SOFTWARE\Devolutions\UniGetUI";
    private const string MarkerValue = "WindowsUpdateProviderRegistered";

    // UOP ships in the August 2026 cumulative update (26100.9168 / 26200.9168)
    private const int MinimumBuild = 26100;
    private const int MinimumUbr = 9168;

    private static string ProviderDirectory =>
        Path.Combine(CoreData.UniGetUIExecutableDirectory, "Assets", "WindowsUpdateProvider");

    private static string RegistrationScript =>
        Path.Combine(CoreData.UniGetUIExecutableDirectory, "Assets", "Utilities", "unigetui_uop_registration.ps1");

    public static bool IsSupported
    {
        get
        {
            if (!OperatingSystem.IsWindows() || CoreData.IsPortable)
                return false;

            try
            {
                return IsOrchestrationPlatformAvailable()
                    && IsMachineWideInstall()
                    && File.Exists(Path.Combine(ProviderDirectory, "provider.json"))
                    && File.Exists(RegistrationScript);
            }
            catch (Exception ex)
            {
                Logger.Warn("Could not determine whether the Windows Update provider is supported");
                Logger.Warn(ex);
                return false;
            }
        }
    }

    public static bool IsRegistered
    {
        get
        {
            if (!OperatingSystem.IsWindows())
                return false;

            using RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using RegistryKey? key = baseKey.OpenSubKey(MarkerKey);
            return key?.GetValue(MarkerValue) is int value && value == 1;
        }
    }

    /// <summary>Registers or unregisters the provider. Shows a UAC prompt when not elevated.</summary>
    /// <returns>null on success, otherwise the reason it failed</returns>
    public static async Task<string?> SetRegisteredAsync(bool registered)
    {
        string action = registered ? "Register" : "Unregister";
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");

        var startInfo = new ProcessStartInfo
        {
            FileName = powershell,
            Arguments = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{RegistrationScript}\" -Action {action} -ProviderPath \"{ProviderDirectory}\"",
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };

        try
        {
            Logger.Info($"Running the Windows Update provider registration script ({action})");
            using Process? process = Process.Start(startInfo);
            if (process is null)
                return CoreTools.Translate("The registration script could not be started");

            await process.WaitForExitAsync();
            Logger.Info($"The Windows Update provider registration script exited with code {process.ExitCode}");
            return process.ExitCode switch
            {
                0 => null,
                2 => CoreTools.Translate("The Windows Update Orchestration Platform is not available on this device"),
                _ => CoreTools.Translate("The registration script failed with exit code {0}", process.ExitCode),
            };
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // ERROR_CANCELLED: the UAC prompt was dismissed
            return CoreTools.Translate("Administrator rights are required");
        }
        catch (Exception ex)
        {
            Logger.Error(ex);
            return ex.Message;
        }
    }

    [SupportedOSPlatform("windows")]
    private static bool IsOrchestrationPlatformAvailable()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, MinimumBuild))
            return false;

        // Later feature updates always carry the platform; 26100 and 26200 need the servicing update
        if (Environment.OSVersion.Version.Build > 26200)
            return true;

        using RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using RegistryKey? key = baseKey.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
        return key?.GetValue("UBR") is int ubr && ubr >= MinimumUbr;
    }

    [SupportedOSPlatform("windows")]
    private static bool IsMachineWideInstall()
    {
        foreach (RegistryView view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
            using RegistryKey? key = baseKey.OpenSubKey(UninstallKey);
            if (key is not null)
                return true;
        }

        return false;
    }
}
