using System.Text;
using UniGetUI.Core.Logging;
using UniGetUI.PackageEngine.PackageLoader;

namespace UniGetUI.Interface;

/// <summary>
/// One-shot commands behind the Windows Update provider script (Assets\WindowsUpdateProvider).
/// Windows Update decides when to scan and when to install; these only do the package work and
/// write the result as IPC JSON for the script to report back.
/// </summary>
public static class WindowsUpdateProviderHost
{
    public const string ScanArgument = "--uop-scan";
    public const string UpdateArgument = "--uop-update";

    public static bool IsProviderCommand(IReadOnlyList<string> args)
    {
        return args.Contains(ScanArgument, StringComparer.OrdinalIgnoreCase)
            || args.Contains(UpdateArgument, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// <c>--uop-scan &lt;output&gt;</c> writes the available updates, <c>--uop-update &lt;request&gt; &lt;output&gt;</c>
    /// updates one package, where the request is a base64url-encoded <see cref="IpcPackageActionRequest"/>.
    /// </summary>
    public static async Task<int> RunAsync(IReadOnlyList<string> args, Func<Task> initializeAsync)
    {
        try
        {
            int i = args.ToList().FindIndex(arg => arg.Equals(UpdateArgument, StringComparison.OrdinalIgnoreCase));
            IpcPackageActionRequest? request = i >= 0 ? DecodeRequest(args[i + 1]) : null;
            string output = args[^1];

            await initializeAsync();
            if (UpgradablePackagesLoader.Instance is { } loader)
            {
                if (loader.IsLoading)
                    await loader.WaitForCurrentLoadAsync();
                else if (!loader.IsLoaded)
                    await loader.ReloadPackages();
            }

            string json;
            bool succeeded = true;
            if (request is null)
            {
                json = IpcJson.Serialize(IpcPackageApi.ListUpgradablePackages());
            }
            else
            {
                Logger.Info($"Windows Update requested an update of {request.ManagerName}\\{request.PackageId}");
                var result = await IpcPackageApi.UpdatePackageAsync(request);
                succeeded = result.Status == "success";
                json = IpcJson.Serialize(result);
            }

            await File.WriteAllTextAsync(output, json, new UTF8Encoding(false));
            return succeeded ? 0 : 1;
        }
        catch (Exception ex)
        {
            Logger.Error("The Windows Update provider command failed");
            Logger.Error(ex);
            return 1;
        }
    }

    internal static IpcPackageActionRequest DecodeRequest(string encoded)
    {
        string base64 = encoded.Replace('-', '+').Replace('_', '/');
        base64 = base64.PadRight(base64.Length + ((4 - (base64.Length % 4)) % 4), '=');
        var request = IpcJson.Deserialize<IpcPackageActionRequest>(Encoding.UTF8.GetString(Convert.FromBase64String(base64)));

        if (request is null || string.IsNullOrWhiteSpace(request.PackageId) || string.IsNullOrWhiteSpace(request.ManagerName))
            throw new ArgumentException("The Windows Update provider request must name a package id and a manager");

        // Nobody may be around to answer an installer's prompts
        request.Interactive = false;
        request.WaitForCompletion = true;
        return request;
    }
}
