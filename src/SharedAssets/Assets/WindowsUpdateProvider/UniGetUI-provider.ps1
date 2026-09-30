#
# UniGetUI provider for the Windows Update Orchestration Platform, see docs/WINDOWS_UPDATE.md.
#
# Windows Update runs -Scan and -Deploy as SYSTEM from its own copy of this folder. UniGetUI's
# settings page and installer run -Register, -Unregister and -Refresh elevated from the installation.
# The package work is done by UniGetUI.exe; this script only reports it through Windows.Management.Update.
#

[CmdletBinding(DefaultParameterSetName = 'Scan')]
param(
    [Parameter(ParameterSetName = 'Scan')][switch]$Scan,
    [Parameter(ParameterSetName = 'Deploy', Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Deploy,
    [Parameter(ParameterSetName = 'Register')][switch]$Register,
    [Parameter(ParameterSetName = 'Unregister')][switch]$Unregister,
    [Parameter(ParameterSetName = 'Refresh')][switch]$Refresh
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
foreach ($type in 'WindowsSoftwareUpdate', 'WindowsSoftwareUpdateProvider', 'WindowsSoftwareUpdateProviderStatus', 'WindowsUpdateManager') {
    $null = [Type]::GetType("Windows.Management.Update.$type, Windows.Management.Update, ContentType=WindowsRuntime", $true)
}

$Provider = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provider.json') -Raw | ConvertFrom-Json
$E_FAIL = [uint32]2147500037 # 0x80004005, PowerShell reads hex literals above 0x7FFFFFFF as negative Int32

function Get-UniGetUIExecutable {
    # Windows Update runs a copy of this folder, so find the installation through the uninstall key
    # that provider.json already has to name
    $dirs = foreach ($view in 'Registry64', 'Registry32') {
        $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
        $key = $hklm.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($Provider.ProductCode)")
        if ($key) { $key.GetValue('InstallLocation') }
    }
    $dirs = @($dirs) + (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    foreach ($dir in $dirs | Where-Object { $_ }) {
        $exe = Join-Path $dir 'UniGetUI.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    throw 'UniGetUI.exe was not found'
}

# Runs UniGetUI.exe and returns the JSON it wrote, or $null when it failed
function Invoke-UniGetUI([string[]]$Arguments, [string]$Output) {
    Remove-Item -LiteralPath $Output -ErrorAction SilentlyContinue
    $exe = Get-UniGetUIExecutable
    $argumentLine = (@($Arguments) + "`"$Output`"") -join ' '
    Write-Host "Running `"$exe`" $argumentLine"
    $process = Start-Process -FilePath $exe -ArgumentList $argumentLine -WindowStyle Hidden -Wait -PassThru
    Write-Host "UniGetUI exited with code $($process.ExitCode)"
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Output)) { return $null }
    return Get-Content -LiteralPath $Output -Raw -Encoding UTF8 | ConvertFrom-Json
}

function ConvertTo-UpdateVersion([string]$Version) {
    # Package managers use free-form versions; keep the first four numeric groups
    $parts = @([regex]::Matches($Version, '\d+') | Select-Object -First 4 | ForEach-Object { [uint32][Math]::Min([double]$_.Value, [uint32]::MaxValue) })
    while ($parts.Count -lt 4) { $parts += [uint32]0 }
    return [Windows.Management.Update.WindowsSoftwareUpdateVersion]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Get-Hash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').Substring(0, 32)
}

function Invoke-Scan([string]$State) {
    $updates = [System.Collections.Generic.List[Windows.Management.Update.WindowsSoftwareUpdate]]::new()
    $packages = Invoke-UniGetUI '--uop-scan' (Join-Path $State 'scan-result.json')
    if ($null -ne $packages) {
        # The orchestrator requires each update to name an installed product; packages from most
        # managers have no identity it can check, so updates are attributed to UniGetUI itself
        $identity = [Windows.Management.Update.WindowsSoftwareUpdateIdentity]::new('ProductCode', $Provider.ProductCode)
        $optional = [Windows.Management.Update.WindowsSoftwareUpdateOptionalInfo]::new('Application', [System.Collections.Generic.List[Windows.Management.Update.WindowsSoftwareUpdateLocalizationInfo]]::new(), $null, $null)

        foreach ($package in @($packages)) {
            $updateId = Get-Hash "$($package.manager)|$($package.source)|$($package.id)|$($package.newVersion)"
            if ($updates | Where-Object UpdateId -eq $updateId) { continue }

            $request = ConvertTo-Json -Compress @{ packageId = $package.id; managerName = $package.manager; packageSource = $package.source; version = $package.newVersion }
            $request = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            $deploy = [Windows.Management.Update.WindowsSoftwareUpdateActionInfo]::new((Split-Path -Leaf $PSCommandPath), "-Deploy $request", 'Deploy')

            $updates.Add([Windows.Management.Update.WindowsSoftwareUpdate]::new(
                    $Provider.Id, 'Powershell', $updateId,
                    "$($package.name) $($package.newVersion)",
                    "Update $($package.name) from $($package.version) to $($package.newVersion) with UniGetUI.",
                    [Uri]'https://github.com/Devolutions/UniGetUI', [uint64]0, [uint64]0, $identity,
                    (ConvertTo-UpdateVersion $package.version), (ConvertTo-UpdateVersion $package.newVersion),
                    $null, [Windows.Management.Update.WindowsSoftwareUpdateExecutionInfo]::new($deploy, $null), $optional))
        }
    }

    $status = [Windows.Management.Update.WindowsSoftwareUpdateProviderStatus]::new($Provider.Id)
    $code = if ($null -ne $packages) { [uint32]0 } else { $E_FAIL }
    $result = $status.SetScanResult($null -ne $packages, $code, [uint64]0, $updates)
    Write-Host ("SetScanResult({0} updates) -> {1}, 0x{2:X8}" -f $updates.Count, $result.Succeeded, $result.ResultCode)
}

function Invoke-Deploy([string]$State) {
    $status = [Windows.Management.Update.WindowsSoftwareUpdateProviderStatus]::new($Provider.Id)
    $succeeded = $false
    try {
        [void]$status.SetActionProgress(0, 100)
        $result = Invoke-UniGetUI @('--uop-update', $Deploy) (Join-Path $State "deploy-$(Get-Hash $Deploy).json")
        $succeeded = $null -ne $result -and $result.status -eq 'success'
        if (-not $succeeded -and $result) { Write-Host "UniGetUI could not update the package: $($result.message)" }
    }
    finally {
        # The orchestrator treats an action without a result as failed, so always report one
        $actionResult = if ($succeeded) { 'Succeeded' } else { 'Failed' }
        $code = if ($succeeded) { [uint32]0 } else { $E_FAIL }
        $result = $status.SetActionResult([Windows.Management.Update.WindowsSoftwareUpdateProviderActionResult]::new($actionResult, 'None', $code, [uint64]0))
        Write-Host "SetActionResult($actionResult) -> $($result.Succeeded)"
    }
}

# Exits with the orchestrator's HRESULT when it rejects a call
function Assert-Result($Result, [string]$Operation) {
    Write-Host ("{0}() -> {1}, 0x{2:X8}" -f $Operation, $Result.Succeeded, $Result.ResultCode)
    if (-not $Result.Succeeded) { exit [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Result.ResultCode), 0) }
}

function Test-Registered {
    return [bool](Get-ChildItem "$env:ProgramData\USOPrivate\Providers\Registered" -Filter "$($Provider.Id)_*" -Directory -ErrorAction SilentlyContinue)
}

function Invoke-Unregister {
    if (-not (Test-Registered)) { return }
    # Windows Update refuses while one of our updates is installing (UO_E_PROVIDER_UNREGISTRATION_FAILED),
    # so wait for the deploy to finish
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $result = (New-Object Windows.Management.Update.WindowsUpdateManager('UniGetUI')).GetProvider($Provider.Id).Unregister()
        $retry = -not $result.Succeeded -and $result.ResultCode -eq [uint32]2149884676 -and (Get-Date) -lt $deadline
        if ($retry) { Start-Sleep -Seconds 5 }
    } while ($retry)
    Assert-Result $result 'Unregister'
}

function Invoke-Register {
    # Re-registering picks up the files shipped by a newer UniGetUI version
    Invoke-Unregister
    $new = New-Object Windows.Management.Update.WindowsSoftwareUpdateProvider($PSScriptRoot)
    Assert-Result $new.Validate() 'Validate'
    Assert-Result $new.Register() 'Register'
}

switch ($PSCmdlet.ParameterSetName) {
    'Register' { Invoke-Register }
    'Unregister' { Invoke-Unregister }
    'Refresh' { if (Test-Registered) { Invoke-Register } }
    default {
        $state = Join-Path $PSScriptRoot 'State'
        $log = Join-Path $state 'UniGetUI.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 5MB) { Remove-Item $log }
        Start-Transcript -Path $log -Append | Out-Null
        try {
            if ($PSCmdlet.ParameterSetName -eq 'Deploy') { Invoke-Deploy $state } else { Invoke-Scan $state }
        }
        finally {
            Stop-Transcript | Out-Null
        }
    }
}
