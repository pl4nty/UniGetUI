using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using UniGetUI.Core.Logging;
using UniGetUI.PackageEngine;
using UniGetUI.PackageEngine.PackageLoader;

namespace UniGetUI.Interface;

public sealed class WindowsUpdateProviderPackage
{
    public string Name { get; set; } = "";
    public string Id { get; set; } = "";
    public string Manager { get; set; } = "";
    public string ManagerDisplayName { get; set; } = "";
    public string Source { get; set; } = "";
    public string Version { get; set; } = "";
    public string NewVersion { get; set; } = "";
}

public sealed class WindowsUpdateProviderRequest
{
    public string Manager { get; set; } = "";
    public string Id { get; set; } = "";
    public string Source { get; set; } = "";
    public string Version { get; set; } = "";
}

public sealed class WindowsUpdateProviderResult
{
    public bool Succeeded { get; set; }
    public string? Message { get; set; }
    public IReadOnlyList<WindowsUpdateProviderPackage> Packages { get; set; } = [];
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    WriteIndented = true
)]
[JsonSerializable(typeof(WindowsUpdateProviderRequest))]
[JsonSerializable(typeof(WindowsUpdateProviderResult))]
internal sealed partial class WindowsUpdateProviderJsonContext : JsonSerializerContext;

/// <summary>
/// One-shot commands run by the Windows Update Orchestration Platform provider scripts
/// (Assets\WindowsUpdateProvider). The orchestrator decides when to scan and when to install;
/// these commands only do the package work and hand the outcome back to the scripts as JSON,
/// which then report it through the Windows.Management.Update API.
/// </summary>
public static class WindowsUpdateProviderHost
{
    public const string ScanArgument = "--uop-scan";
    public const string UpdateArgument = "--uop-update";
    public const string RequestArgument = "--request";
    public const string OutputArgument = "--output";

    public static bool IsProviderCommand(IReadOnlyList<string> args)
    {
        return args.Contains(ScanArgument, StringComparer.OrdinalIgnoreCase)
            || args.Contains(UpdateArgument, StringComparer.OrdinalIgnoreCase);
    }

    public static async Task<int> RunAsync(IReadOnlyList<string> args, Func<Task> initializeAsync)
    {
        ArgumentNullException.ThrowIfNull(initializeAsync);

        string? outputPath = GetOptionValue(args, OutputArgument);
        if (string.IsNullOrWhiteSpace(outputPath))
        {
            Logger.Error($"The Windows Update provider commands require {OutputArgument} <path>");
            return 2;
        }

        WindowsUpdateProviderResult result;
        try
        {
            // Parse the request before loading the managers so malformed input fails fast
            WindowsUpdateProviderRequest? request = args.Contains(UpdateArgument, StringComparer.OrdinalIgnoreCase)
                ? DecodeRequest(GetOptionValue(args, RequestArgument))
                : null;

            await initializeAsync();
            await WaitForUpdatesAsync();

            result = request is null ? Scan() : await UpdateAsync(request);
        }
        catch (Exception ex)
        {
            Logger.Error("The Windows Update provider command failed");
            Logger.Error(ex);
            result = new WindowsUpdateProviderResult { Succeeded = false, Message = ex.Message };
        }

        await File.WriteAllTextAsync(
            outputPath,
            JsonSerializer.Serialize(result, WindowsUpdateProviderJsonContext.Default.WindowsUpdateProviderResult),
            new UTF8Encoding(false)
        );
        return result.Succeeded ? 0 : 1;
    }

    internal static WindowsUpdateProviderRequest DecodeRequest(string? encoded)
    {
        if (string.IsNullOrWhiteSpace(encoded))
        {
            throw new ArgumentException($"{UpdateArgument} requires {RequestArgument} <request>");
        }

        string base64 = encoded.Replace('-', '+').Replace('_', '/');
        base64 = base64.PadRight(base64.Length + ((4 - (base64.Length % 4)) % 4), '=');

        var request = JsonSerializer.Deserialize(
            Encoding.UTF8.GetString(Convert.FromBase64String(base64)),
            WindowsUpdateProviderJsonContext.Default.WindowsUpdateProviderRequest
        );

        if (request is null || string.IsNullOrWhiteSpace(request.Id) || string.IsNullOrWhiteSpace(request.Manager))
        {
            throw new ArgumentException("The Windows Update provider request must name a package id and a manager");
        }

        return request;
    }

    internal static string? GetOptionValue(IReadOnlyList<string> args, string option)
    {
        for (int i = 0; i < args.Count - 1; i++)
        {
            if (args[i].Equals(option, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }

        return null;
    }

    private static async Task WaitForUpdatesAsync()
    {
        if (UpgradablePackagesLoader.Instance is not { } loader)
        {
            return;
        }

        if (loader.IsLoading)
        {
            await loader.WaitForCurrentLoadAsync();
        }
        else if (!loader.IsLoaded)
        {
            await loader.ReloadPackages();
        }
    }

    private static WindowsUpdateProviderResult Scan()
    {
        var packages = IpcPackageApi.ListUpgradablePackages()
            .Select(package => new WindowsUpdateProviderPackage
            {
                Name = package.Name,
                Id = package.Id,
                Manager = package.Manager,
                ManagerDisplayName = PEInterface.Managers
                    .FirstOrDefault(manager => IpcManagerSettingsApi.MatchesManagerId(manager, package.Manager))
                    ?.DisplayName ?? package.Manager,
                Source = package.Source,
                Version = package.Version,
                NewVersion = package.NewVersion,
            })
            .ToArray();

        if (UpgradablePackagesLoader.Instance?.LastLoadReportedFailures == true)
        {
            Logger.Warn("Some package managers failed to list their updates; reporting the updates that were found");
        }

        Logger.Info($"Reporting {packages.Length} updates to the Windows Update orchestrator");
        return new WindowsUpdateProviderResult { Succeeded = true, Packages = packages };
    }

    private static async Task<WindowsUpdateProviderResult> UpdateAsync(WindowsUpdateProviderRequest request)
    {
        Logger.Info($"The Windows Update orchestrator requested an update of {request.Manager}\\{request.Id} to {request.Version}");

        var result = await IpcPackageApi.UpdatePackageAsync(new IpcPackageActionRequest
        {
            PackageId = request.Id,
            ManagerName = request.Manager,
            PackageSource = string.IsNullOrWhiteSpace(request.Source) ? null : request.Source,
            Version = string.IsNullOrWhiteSpace(request.Version) ? null : request.Version,
            // Nobody may be around to answer an installer's prompts
            Interactive = false,
            WaitForCompletion = true,
        });

        bool succeeded = result.Status == "success" && result.OperationStatus == "succeeded";
        return new WindowsUpdateProviderResult { Succeeded = succeeded, Message = result.Message };
    }
}
