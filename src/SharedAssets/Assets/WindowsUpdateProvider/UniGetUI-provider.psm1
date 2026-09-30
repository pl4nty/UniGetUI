#
# Shared helpers for the UniGetUI Windows Update Orchestration Platform (UOP) provider.
#
# The orchestrator runs UniGetUI-scan.ps1 and UniGetUI-action.ps1 from this folder. Both scripts
# delegate the package work to UniGetUI.exe (two folders up) and only translate its results into
# the Windows.Management.Update WinRT API. See docs/WINDOWS_UPDATE.md.
#
# Every file in this folder is listed in provider.json with its SHA-256 hash, and the orchestrator
# rejects the provider if anything else is written here: logs and results go to the State folder.
#

Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Management.Update.WindowsSoftwareUpdate, Windows.Management.Update, ContentType = WindowsRuntime]
[void][Windows.Management.Update.WindowsSoftwareUpdateProviderStatus, Windows.Management.Update, ContentType = WindowsRuntime]
[void][Windows.Management.Update.WindowsSoftwareUpdateProviderActionResult, Windows.Management.Update, ContentType = WindowsRuntime]
[void][Windows.Management.Update.WindowsSoftwareUpdateVersion, Windows.Management.Update, ContentType = WindowsRuntime]
[void][Windows.Management.Update.WindowsSoftwareUpdateActionInfo, Windows.Management.Update, ContentType = WindowsRuntime]
[void][Windows.Management.Update.WindowsSoftwareUpdateExecutionInfo, Windows.Management.Update, ContentType = WindowsRuntime]
[void][Windows.Management.Update.WindowsSoftwareUpdateOptionalInfo, Windows.Management.Update, ContentType = WindowsRuntime]
[void][Windows.Management.Update.WindowsSoftwareUpdateLocalizationInfo, Windows.Management.Update, ContentType = WindowsRuntime]
[void][Windows.Management.Update.WindowsSoftwareUpdateIdentity, Windows.Management.Update, ContentType = WindowsRuntime]

$script:ProviderId = 'UniGetUI'
$script:LogPath = $null

# E_FAIL, reported when UniGetUI could not complete a scan or an action
$script:GenericFailure = [uint32]2147500037 # 0x80004005, as PowerShell reads hex literals above 0x7FFFFFFF as negative Int32

function Get-ProviderId {
    return $script:ProviderId
}

# The orchestrator requires every update to name an installed product. Packages from arbitrary
# managers have no identity it can check, so updates are attributed to UniGetUI itself.
function Get-ProviderIdentity {
    $provider = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSCommandPath) 'provider.json') -Raw | ConvertFrom-Json
    return [Windows.Management.Update.WindowsSoftwareUpdateIdentity]::new(
        [Windows.Management.Update.WindowsSoftwareUpdateIdentityType]::ProductCode,
        [string]$provider.ProductCode)
}

function Get-StateDirectory {
    $state = Join-Path (Split-Path -Parent $PSCommandPath) 'State'
    if (-not (Test-Path -LiteralPath $state)) {
        [void](New-Item -ItemType Directory -Path $state -Force)
    }
    return $state
}

function Enable-ProviderLog {
    param([string]$FileName)

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        return
    }

    $script:LogPath = Join-Path (Get-StateDirectory) ([System.IO.Path]::GetFileName($FileName))

    # Keep a single previous generation so the State folder cannot grow without bound
    if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 5MB) {
        Move-Item -LiteralPath $script:LogPath -Destination "$($script:LogPath).old" -Force
    }
}

function Write-ProviderLog {
    param([string]$Message)

    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    else {
        Write-Host $line
    }
}

function Get-UniGetUIExecutable {
    # The provider ships in <install dir>\Assets\WindowsUpdateProvider
    $installDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $exe = Join-Path $installDir 'UniGetUI.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "UniGetUI.exe was not found at $exe"
    }
    return $exe
}

# Runs UniGetUI.exe with the given arguments and returns the parsed JSON it wrote to OutputPath.
# Arguments must not contain spaces or quotes; OutputPath is quoted here.
function Invoke-UniGetUI {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    $exe = Get-UniGetUIExecutable
    $argumentLine = (($Arguments + @('--output', "`"$OutputPath`"")) -join ' ')
    Write-ProviderLog "Running `"$exe`" $argumentLine"

    $process = Start-Process -FilePath $exe -ArgumentList $argumentLine -WindowStyle Hidden -Wait -PassThru
    Write-ProviderLog "UniGetUI exited with code $($process.ExitCode)"

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "UniGetUI exited with code $($process.ExitCode) and did not write $OutputPath"
    }

    return (Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function ConvertTo-UpdateVersion {
    param([string]$Version)

    # Package managers use free-form versions; keep the first four numeric groups
    $parts = @([regex]::Matches([string]$Version, '\d+') | Select-Object -First 4 | ForEach-Object {
        $value = [uint64]0
        if ([uint64]::TryParse($_.Value, [ref]$value) -and $value -le [uint32]::MaxValue) { [uint32]$value } else { [uint32]::MaxValue }
    })
    while ($parts.Count -lt 4) {
        $parts += [uint32]0
    }

    return [Windows.Management.Update.WindowsSoftwareUpdateVersion]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function New-UpdateId {
    param([string]$Key)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key))
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 32)
}

function ConvertTo-Base64Url {
    param([string]$Text)

    return [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Set-ProviderScanResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]
        [System.Collections.Generic.List[Windows.Management.Update.WindowsSoftwareUpdate]]$Updates,
        [uint32]$ResultCode = 0
    )

    $status = [Windows.Management.Update.WindowsSoftwareUpdateProviderStatus]::new($script:ProviderId)
    $result = $status.SetScanResult($Succeeded, $ResultCode, [uint64]0, $Updates)
    Write-ProviderLog ("SetScanResult({0} updates) -> Succeeded: {1}, ResultCode: 0x{2:X8}, ExtendedError: {3}" -f $Updates.Count, $result.Succeeded, $result.ResultCode, $result.ExtendedError)
}

function Set-ProviderActionProgress {
    param([uint64]$Current, [uint64]$Total = 100)

    try {
        $status = [Windows.Management.Update.WindowsSoftwareUpdateProviderStatus]::new($script:ProviderId)
        [void]$status.SetActionProgress($Current, $Total)
    }
    catch {
        Write-ProviderLog "SetActionProgress failed: $($_.Exception.Message)"
    }
}

function Set-ProviderActionResult {
    param([Parameter(Mandatory = $true)][bool]$Succeeded)

    $status = [Windows.Management.Update.WindowsSoftwareUpdateProviderStatus]::new($script:ProviderId)
    if ($Succeeded) {
        $actionResult = [Windows.Management.Update.WindowsSoftwareUpdateProviderActionResult]::new(
            [Windows.Management.Update.WindowsSoftwareUpdateActionResult]::Succeeded,
            [Windows.Management.Update.WindowsSoftwareUpdateRestartReason]::None,
            [uint32]0,
            [uint64]0)
    }
    else {
        $actionResult = [Windows.Management.Update.WindowsSoftwareUpdateProviderActionResult]::new(
            [Windows.Management.Update.WindowsSoftwareUpdateActionResult]::Failed,
            [Windows.Management.Update.WindowsSoftwareUpdateRestartReason]::None,
            $script:GenericFailure,
            [uint64]0)
    }

    $result = $status.SetActionResult($actionResult)
    Write-ProviderLog ("SetActionResult(Succeeded: {0}) -> Succeeded: {1}, ResultCode: 0x{2:X8}" -f $Succeeded, $result.Succeeded, $result.ResultCode)
}

function Get-GenericFailureCode {
    return $script:GenericFailure
}

Export-ModuleMember -Function *
