#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Prepares the UniGetUI Windows Update provider folder for release.

.DESCRIPTION
    Lists every file of the folder in provider.json with its SHA-256 hash and generates the
    catalog vouching for provider.json. The catalog must then be code-signed: Windows Update
    refuses a provider whose catalog is unsigned or signed by an untrusted certificate.

.PARAMETER Path
    The provider folder, e.g. unigetui_bin/Assets/WindowsUpdateProvider.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Path
)

$ErrorActionPreference = 'Stop'

$Path = (Resolve-Path $Path).Path
$ProviderJsonPath = Join-Path $Path 'provider.json'
$Provider = Get-Content $ProviderJsonPath -Raw | ConvertFrom-Json

$Provider.PayloadFiles = @(Get-ChildItem $Path -File | Where-Object Name -notin 'provider.json', $Provider.CatalogFile | ForEach-Object {
    [ordered]@{
        FileName = $_.Name
        FileHash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($_.FullName)))
    }
})
$Provider | ConvertTo-Json -Depth 5 | Set-Content $ProviderJsonPath -Encoding utf8NoBOM

# Only provider.json goes in the catalog; it carries the hashes of the other files
$CatalogPath = Join-Path $Path $Provider.CatalogFile
New-FileCatalog -Path $ProviderJsonPath -CatalogFilePath $CatalogPath -CatalogVersion 2 | Out-Null
Write-Host "Generated $CatalogPath for $($Provider.PayloadFiles.Count) payload files"
