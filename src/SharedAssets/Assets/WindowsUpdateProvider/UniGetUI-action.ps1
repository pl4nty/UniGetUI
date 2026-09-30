#
# UniGetUI Windows Update provider: deploy action
#
# Called by the orchestrator, when it decides it is a good time, for one update reported by
# UniGetUI-scan.ps1. -Request is the base64url-encoded package identity built by the scan.
#

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Request,

    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UniGetUI-provider.psm1') -Force

Enable-ProviderLog -FileName $LogFile
Write-ProviderLog '=== UniGetUI provider deploy started ==='

$succeeded = $false
try {
    Set-ProviderActionProgress -Current 0

    $output = Join-Path (Get-StateDirectory) "action-$(New-UpdateId -Key $Request).json"
    $result = Invoke-UniGetUI -Arguments @('--uop-update', '--request', $Request) -OutputPath $output
    $succeeded = [bool]$result.succeeded

    if ($succeeded) {
        Set-ProviderActionProgress -Current 100
    }
    else {
        Write-ProviderLog "UniGetUI could not update the package: $($result.message)"
    }
}
catch {
    Write-ProviderLog "Deploy failed: $($_.Exception.Message)"
}
finally {
    # The orchestrator treats an action without a result as failed, so always report one
    Set-ProviderActionResult -Succeeded $succeeded
}

Write-ProviderLog '=== UniGetUI provider deploy finished ==='
if (-not $succeeded) {
    exit 1
}
