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
/// Registers UniGetUI as a Windows Update Orchestration Platform provider through
/// Assets\WindowsUpdateProvider\UniGetUI-provider.ps1, see docs/WINDOWS_UPDATE.md.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class WindowsUpdateProviderRegistration
{
    private static string Script =>
        Path.Combine(CoreData.UniGetUIExecutableDirectory, "Assets", "WindowsUpdateProvider", "UniGetUI-provider.ps1");

    /// <summary>
    /// Needs the platform (Windows 11 26100/26200.9168+) and a machine-wide install, whose uninstall
    /// key is the product the provider.json ProductCode points to.
    /// </summary>
    public static bool IsSupported =>
        !CoreData.IsPortable
        && File.Exists(Script)
        && Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Management.Update.WindowsSoftwareUpdateProvider") is not null
        && Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{889610CC-4337-4BDB-AC3B-4F21806C0BDE}_is1") is not null;

    // Windows Update keeps its own copy of each registered provider here, readable by everyone
    public static bool IsRegistered =>
        Directory.Exists(RegisteredProvidersDirectory)
        && Directory.EnumerateDirectories(RegisteredProvidersDirectory, "UniGetUI_*").Any();

    private static string RegisteredProvidersDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "USOPrivate", "Providers", "Registered");

    /// <returns>null on success, otherwise why it failed</returns>
    public static async Task<string?> SetRegisteredAsync(bool registered)
    {
        try
        {
            using Process process = Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{Script}\" {(registered ? "-Register" : "-Unregister")}",
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            })!;
            await process.WaitForExitAsync();

            // The script exits with the orchestrator's HRESULT when it rejects the provider
            return process.ExitCode == 0 ? null : $"0x{process.ExitCode:X8}";
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            return CoreTools.Translate("Administrator rights are required");
        }
        catch (Exception ex)
        {
            Logger.Error(ex);
            return ex.Message;
        }
    }
}
