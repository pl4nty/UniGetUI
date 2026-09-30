using UniGetUI.Interface;
using UniGetUI.PackageEngine;

namespace UniGetUI.Avalonia.Infrastructure;

internal static class HeadlessDaemonHost
{
    public static async Task<int> RunAsync()
    {
        return await HeadlessIpcHost.RunAsync(async () =>
        {
            await LoadPackageEngineAsync();
            MaintenanceScheduler.StartHeadless();
        });
    }

    public static async Task<int> RunWindowsUpdateProviderCommandAsync(IReadOnlyList<string> args)
    {
        return await WindowsUpdateProviderHost.RunAsync(args, LoadPackageEngineAsync);
    }

    private static async Task LoadPackageEngineAsync()
    {
        ProcessEnvironmentConfigurator.PrepareForCurrentPlatform();
        PEInterface.LoadLoaders();
        await Task.Run(PEInterface.LoadManagers);
    }
}
