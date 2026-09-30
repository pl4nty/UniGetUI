#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Prepares the UniGetUI Windows Update Orchestration Platform (UOP) provider folder for release.

.DESCRIPTION
    Refreshes the SHA-256 payload hashes in provider.json and, unless -SkipCatalog is passed,
    generates the catalog file (UniGetUI.cat) that vouches for provider.json. The catalog must then
    be code-signed with the same certificate as the binaries: the orchestrator refuses to register
    a provider whose catalog is unsigned or signed by an untrusted certificate.

    The payload files must keep CRLF line endings (see .gitattributes) so their hashes are stable.

.PARAMETER Path
    The provider folder, e.g. unigetui_bin/Assets/WindowsUpdateProvider.

.PARAMETER SkipCatalog
    Only refresh the payload hashes (used to update the checked-in provider.json).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Path,

    [switch] $SkipCatalog
)

$ErrorActionPreference = 'Stop'

$Path = (Resolve-Path $Path).Path
$ProviderJsonPath = Join-Path $Path 'provider.json'
$Provider = Get-Content $ProviderJsonPath -Raw | ConvertFrom-Json

foreach ($payload in $Provider.PayloadFiles) {
    $file = Join-Path $Path $payload.FileName
    if (-not (Test-Path $file -PathType Leaf)) {
        throw "Payload file '$($payload.FileName)' listed in provider.json does not exist."
    }

    $bytes = [System.IO.File]::ReadAllBytes($file)
    if ($payload.FileName -match '\.(ps1|psm1)$' -and ([System.Text.Encoding]::UTF8.GetString($bytes) -match "(?<!`r)`n")) {
        throw "Payload file '$($payload.FileName)' must use CRLF line endings."
    }

    $payload.FileHash = [System.Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData($bytes))
    Write-Host "$($payload.FileName): $($payload.FileHash)"
}

$Json = ($Provider | ConvertTo-Json -Depth 5) -replace "`r?`n", "`r`n"
[System.IO.File]::WriteAllText($ProviderJsonPath, $Json + "`r`n", [System.Text.UTF8Encoding]::new($false))

if ($SkipCatalog) {
    return
}

$MakeCat = Get-Command makecat.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $MakeCat) {
    $MakeCat = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makecat.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
        Select-Object -ExpandProperty FullName -First 1
}
if (-not $MakeCat) {
    throw "makecat.exe was not found. Install the Windows SDK."
}

# The orchestrator only expects provider.json in the catalog: the payload files are covered by
# the hashes provider.json carries.
$CatalogName = $Provider.CatalogFile
$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "unigetui-uop-$([guid]::NewGuid())"
New-Item $WorkDir -ItemType Directory | Out-Null
try {
    $CdfPath = Join-Path $WorkDir 'provider.cdf'
    @(
        '[CatalogHeader]'
        "Name=$CatalogName"
        "ResultDir=$WorkDir"
        'CatalogVersion=2'
        'HashAlgorithms=SHA256'
        'EncodingType=0x00010001'
        'CATATTR1=0x10010001:OSAttr:2:10'
        ''
        '[CatalogFiles]'
        "<HASH>provider.json=$ProviderJsonPath"
    ) | Set-Content $CdfPath -Encoding Ascii

    & $MakeCat -v $CdfPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "makecat.exe failed with exit code $LASTEXITCODE"
    }

    Move-Item (Join-Path $WorkDir $CatalogName) (Join-Path $Path $CatalogName) -Force
    Write-Host "Generated $(Join-Path $Path $CatalogName)"
}
finally {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
