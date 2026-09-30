using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using UniGetUI.Interface;

namespace UniGetUI.Tests;

public sealed class WindowsUpdateProviderTests
{
    private static string ProviderDirectory =>
        Path.Combine(AppContext.BaseDirectory, "Assets", "WindowsUpdateProvider");

    // Same encoding as ConvertTo-Base64Url in UniGetUI-provider.psm1
    private static string EncodeRequest(string json)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(json))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    [Fact]
    public void DecodeRequestReadsTheScanScriptEncoding()
    {
        string encoded = EncodeRequest(
            """{"manager":"winps","id":"Az.Accounts","source":"PowerShell 5.x: PSGallery","version":"5.3.0"}"""
        );

        var request = WindowsUpdateProviderHost.DecodeRequest(encoded);

        Assert.Equal("winps", request.Manager);
        Assert.Equal("Az.Accounts", request.Id);
        Assert.Equal("PowerShell 5.x: PSGallery", request.Source);
        Assert.Equal("5.3.0", request.Version);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not base64!")]
    public void DecodeRequestRejectsMalformedInput(string? encoded)
    {
        Assert.ThrowsAny<Exception>(() => WindowsUpdateProviderHost.DecodeRequest(encoded));
    }

    [Fact]
    public void DecodeRequestRequiresAPackageIdAndManager()
    {
        Assert.Throws<ArgumentException>(() =>
            WindowsUpdateProviderHost.DecodeRequest(EncodeRequest("""{"manager":"winget"}"""))
        );
        Assert.Throws<ArgumentException>(() =>
            WindowsUpdateProviderHost.DecodeRequest(EncodeRequest("""{"id":"Git.Git"}"""))
        );
    }

    [Fact]
    public void ProviderCommandsAreRecognized()
    {
        Assert.True(WindowsUpdateProviderHost.IsProviderCommand(["--uop-scan", "--output", "a.json"]));
        Assert.True(WindowsUpdateProviderHost.IsProviderCommand(["--UOP-UPDATE", "--request", "x"]));
        Assert.False(WindowsUpdateProviderHost.IsProviderCommand(["package", "update", "--id", "x"]));
    }

    [Fact]
    public void GetOptionValueReturnsTheFollowingArgument()
    {
        string[] args = ["--uop-scan", "--output", @"C:\State\scan-result.json"];

        Assert.Equal(@"C:\State\scan-result.json", WindowsUpdateProviderHost.GetOptionValue(args, "--output"));
        Assert.Null(WindowsUpdateProviderHost.GetOptionValue(args, "--request"));
        Assert.Null(WindowsUpdateProviderHost.GetOptionValue(["--output"], "--output"));
    }

    [Fact]
    public void ProviderJsonHashesMatchTheShippedScripts()
    {
        // The orchestrator refuses the provider when a payload hash is stale, so editing a script
        // requires running scripts/prepare-windows-update-provider.ps1 -SkipCatalog
        using JsonDocument provider = JsonDocument.Parse(File.ReadAllText(Path.Combine(ProviderDirectory, "provider.json")));
        var payloads = provider.RootElement.GetProperty("PayloadFiles").EnumerateArray().ToArray();

        var shipped = Directory.GetFiles(ProviderDirectory)
            .Select(Path.GetFileName)
            .Where(name => name is not "provider.json" and not "UniGetUI.cat")
            .Order(StringComparer.OrdinalIgnoreCase);
        Assert.Equal(
            shipped,
            payloads.Select(payload => payload.GetProperty("FileName").GetString()).Order(StringComparer.OrdinalIgnoreCase)
        );

        foreach (JsonElement payload in payloads)
        {
            string file = Path.Combine(ProviderDirectory, payload.GetProperty("FileName").GetString()!);
            string hash = Convert.ToBase64String(SHA256.HashData(File.ReadAllBytes(file)));
            Assert.Equal(payload.GetProperty("FileHash").GetString(), hash);
        }
    }
}
