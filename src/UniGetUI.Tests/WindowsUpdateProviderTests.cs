using System.Text;
using UniGetUI.Interface;

namespace UniGetUI.Tests;

public sealed class WindowsUpdateProviderTests
{
    // Same encoding as the -Deploy argument built by UniGetUI-provider.ps1
    private static string Encode(string json) =>
        Convert.ToBase64String(Encoding.UTF8.GetBytes(json)).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    [Fact]
    public void DecodeRequestReadsTheProviderScriptEncoding()
    {
        var request = WindowsUpdateProviderHost.DecodeRequest(Encode(
            """{"packageId":"Az.Accounts","managerName":"winps","packageSource":"PowerShell 5.x: PSGallery","version":"5.3.0"}"""
        ));

        Assert.Equal("Az.Accounts", request.PackageId);
        Assert.Equal("winps", request.ManagerName);
        Assert.Equal("PowerShell 5.x: PSGallery", request.PackageSource);
        Assert.Equal("5.3.0", request.Version);
        Assert.False(request.Interactive);
        Assert.True(request.WaitForCompletion);
    }

    [Theory]
    [InlineData("""{"managerName":"winget"}""")]
    [InlineData("""{"packageId":"Git.Git"}""")]
    public void DecodeRequestRequiresAPackageIdAndManager(string json)
    {
        Assert.Throws<ArgumentException>(() => WindowsUpdateProviderHost.DecodeRequest(Encode(json)));
    }
}
