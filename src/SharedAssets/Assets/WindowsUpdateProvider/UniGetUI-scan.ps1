#
# UniGetUI Windows Update provider: scan
#
# Asks UniGetUI for every package update it would offer (ignored updates and the minimum update
# age are already applied) and reports each one to the orchestrator as a Deploy action that runs
# UniGetUI-action.ps1.
#

[CmdletBinding()]
param(
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UniGetUI-provider.psm1') -Force

Enable-ProviderLog -FileName $LogFile
Write-ProviderLog '=== UniGetUI provider scan started ==='

$updates = [System.Collections.Generic.List[Windows.Management.Update.WindowsSoftwareUpdate]]::new()

try {
    $scan = Invoke-UniGetUI -Arguments @('--uop-scan') -OutputPath (Join-Path (Get-StateDirectory) 'scan-result.json')
    if (-not $scan.succeeded) {
        throw "UniGetUI could not list updates: $($scan.message)"
    }

    $providerId = Get-ProviderId
    $identity = Get-ProviderIdentity
    $seen = @{}

    foreach ($package in @($scan.packages)) {
        $key = "$($package.manager)|$($package.source)|$($package.id)|$($package.newVersion)"
        $updateId = New-UpdateId -Key $key
        if ($seen.ContainsKey($updateId)) {
            continue
        }
        $seen[$updateId] = $true

        $request = ConvertTo-Base64Url -Text (@{
            manager = [string]$package.manager
            id      = [string]$package.id
            source  = [string]$package.source
            version = [string]$package.newVersion
        } | ConvertTo-Json -Compress)

        $actionArguments = "-Request $request"
        if ($LogFile) {
            $actionArguments += " -LogFile UniGetUI-action.log"
        }

        $deploy = [Windows.Management.Update.WindowsSoftwareUpdateActionInfo]::new(
            'UniGetUI-action.ps1',
            $actionArguments,
            [Windows.Management.Update.WindowsSoftwareUpdateActionType]::Deploy)
        $execution = [Windows.Management.Update.WindowsSoftwareUpdateExecutionInfo]::new($deploy, $null)

        $optional = [Windows.Management.Update.WindowsSoftwareUpdateOptionalInfo]::new(
            [Windows.Management.Update.WindowsSoftwareUpdateCategory]::Application,
            [System.Collections.Generic.List[Windows.Management.Update.WindowsSoftwareUpdateLocalizationInfo]]::new(),
            $null,
            $null)

        $moreInfo = [System.Uri]::new('https://github.com/Devolutions/UniGetUI')

        $update = [Windows.Management.Update.WindowsSoftwareUpdate]::new(
            $providerId,
            [Windows.Management.Update.WindowsSoftwareUpdateInstallationType]::Powershell,
            $updateId,
            "$($package.name) $($package.newVersion)",
            "Update $($package.name) from $($package.version) to $($package.newVersion) with $($package.managerDisplayName) (via UniGetUI).",
            $moreInfo,
            [uint64]0,
            [uint64]0,
            $identity,
            (ConvertTo-UpdateVersion -Version $package.version),
            (ConvertTo-UpdateVersion -Version $package.newVersion),
            $null,
            $execution,
            $optional)

        $updates.Add($update)
        Write-ProviderLog "Offering $key as $updateId"
    }

    Set-ProviderScanResult -Succeeded $true -Updates $updates
}
catch {
    Write-ProviderLog "Scan failed: $($_.Exception.Message)"
    $updates.Clear()
    Set-ProviderScanResult -Succeeded $false -Updates $updates -ResultCode (Get-GenericFailureCode)
    exit 1
}

Write-ProviderLog '=== UniGetUI provider scan finished ==='
