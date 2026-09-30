#
# Registers or unregisters UniGetUI as a Windows Update Orchestration Platform (UOP) provider.
#
# Must run elevated, in 64-bit Windows PowerShell. Called by UniGetUI's settings page (Register /
# Unregister) and by the installer (Refresh after an upgrade, Unregister on uninstall).
# Exit codes: 0 success, 2 not supported on this device or installation, the orchestrator's
# HRESULT (0x8024A3xx, so negative) when it rejected a call, 1 any other failure.
#

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Register', 'Unregister', 'Refresh')]
    [string]$Action,

    [string]$ProviderPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $ProviderPath) {
    $ProviderPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'WindowsUpdateProvider'
}

$ProviderId = 'UniGetUI'
$ClientId = 'UniGetUI'
$MarkerKey = 'HKLM:\SOFTWARE\Devolutions\UniGetUI'
$MarkerValue = 'WindowsUpdateProviderRegistered'

# HRESULT of the last orchestrator call that failed, used as the exit code
$script:FailureCode = 0

function Test-IsRegisteredMarker {
    $value = Get-ItemProperty -Path $MarkerKey -Name $MarkerValue -ErrorAction SilentlyContinue
    return ($null -ne $value -and $value.$MarkerValue -eq 1)
}

function Set-RegisteredMarker {
    param([bool]$Registered)

    if ($Registered) {
        if (-not (Test-Path $MarkerKey)) {
            [void](New-Item -Path $MarkerKey -Force)
        }
        Set-ItemProperty -Path $MarkerKey -Name $MarkerValue -Value 1 -Type DWord
    }
    elseif (Test-Path $MarkerKey) {
        Remove-ItemProperty -Path $MarkerKey -Name $MarkerValue -ErrorAction SilentlyContinue
    }
}

function Set-FailureCode {
    param($Result)
    $script:FailureCode = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Result.ResultCode), 0)
}

function Format-Result {
    param($Result)
    return ("Succeeded: {0}, ResultCode: 0x{1:X8}, ExtendedError: {2}" -f $Result.Succeeded, $Result.ResultCode, $Result.ExtendedError)
}

function Get-RegisteredProvider {
    $manager = New-Object Windows.Management.Update.WindowsUpdateManager($ClientId)
    if (@($manager.ProviderIds) -notcontains $ProviderId) {
        return $null
    }
    return $manager.GetProvider($ProviderId)
}

function Invoke-Unregister {
    $provider = Get-RegisteredProvider
    if ($null -ne $provider) {
        $result = $provider.Unregister()
        Write-Host "Unregister() -> $(Format-Result $result)"
        if (-not $result.Succeeded) {
            Set-FailureCode $result
            throw "Could not unregister the UniGetUI Windows Update provider"
        }
    }
    else {
        Write-Host "The UniGetUI Windows Update provider is not registered"
    }
    Set-RegisteredMarker -Registered $false
}

function Invoke-Register {
    if (-not (Test-Path -LiteralPath (Join-Path $ProviderPath 'provider.json'))) {
        throw "No Windows Update provider was found at $ProviderPath"
    }

    # Re-registering picks up the files shipped by a newer UniGetUI version
    if ($null -ne (Get-RegisteredProvider)) {
        Invoke-Unregister
    }

    $provider = New-Object Windows.Management.Update.WindowsSoftwareUpdateProvider($ProviderPath)
    $validation = $provider.Validate()
    Write-Host "Validate() -> $(Format-Result $validation)"
    if (-not $validation.Succeeded) {
        Set-FailureCode $validation
        throw "The UniGetUI Windows Update provider failed validation, see docs/WINDOWS_UPDATE.md for the result codes"
    }

    $result = $provider.Register()
    Write-Host "Register() -> $(Format-Result $result)"
    if (-not $result.Succeeded) {
        Set-FailureCode $result
        throw "Could not register the UniGetUI Windows Update provider"
    }

    Set-RegisteredMarker -Registered $true
}

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Management.Update.WindowsSoftwareUpdateProvider, Windows.Management.Update, ContentType = WindowsRuntime]
    [void][Windows.Management.Update.WindowsUpdateManager, Windows.Management.Update, ContentType = WindowsRuntime]
}
catch {
    Write-Host "The Windows Update Orchestration Platform is not available on this device: $($_.Exception.Message)"
    if ($Action -eq 'Register') { exit 2 }
    exit 0
}

try {
    switch ($Action) {
        'Register' { Invoke-Register }
        'Unregister' { Invoke-Unregister }
        'Refresh' {
            if (Test-IsRegisteredMarker) {
                Invoke-Register
            }
            else {
                Write-Host "The UniGetUI Windows Update provider is not enabled, nothing to refresh"
            }
        }
    }
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    if ($script:FailureCode -ne 0) { exit $script:FailureCode }
    exit 1
}
