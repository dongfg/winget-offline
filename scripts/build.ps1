#Requires -Version 7.0
[CmdletBinding()]
param([string]$Config = "$PSScriptRoot/../packages.json", [string]$OutputDirectory = "$PSScriptRoot/../dist")
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module powershell-yaml -RequiredVersion 0.4.12
. "$PSScriptRoot/bundle.ps1"
$configData = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json -AsHashtable
if ($configData.architecture -notin @('x64', 'x86', 'arm64')) { throw 'architecture must be x64, x86 or arm64' }
if (-not $configData.packages -or $configData.packages.Count -eq 0) { throw 'packages must not be empty' }
$seen = @{}
foreach ($package in $configData.packages) {
    if ($package.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]+$' -or $seen.ContainsKey($package.id)) { throw "Invalid or duplicate package ID: $($package.id)" }
    $seen[$package.id] = $true
    foreach ($key in $package.Keys) {
        if ($key -notin @('id', 'version', 'scope', 'installerType', 'locale')) { throw "Unknown package option: $key" }
        if ([string]::IsNullOrWhiteSpace([string]$package[$key])) { throw "Empty option: $key" }
    }
    if ($package.ContainsKey('scope') -and $package.scope -notin @('user', 'machine')) { throw 'Invalid scope' }
}
Get-Command winget -ErrorAction Stop | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ("winget-offline-" + [guid]::NewGuid())
$bundle = Join-Path $work 'bundle'
New-Item -ItemType Directory -Path "$bundle/packages", "$bundle/manifests" -Force | Out-Null
try {
    $lock = [ordered]@{ schemaVersion = 1; architecture = $configData.architecture; builtAt = [DateTime]::UtcNow.ToString('o'); packages = @() }
    foreach ($package in $configData.packages) {
        $download = Join-Path $work $package.id
        $arguments = @('download', '--id', $package.id, '--exact', '--source', 'winget', '--architecture', $configData.architecture,
            '--download-directory', $download, '--skip-dependencies', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
        foreach ($mapping in @(@('version','--version'), @('scope','--scope'), @('installerType','--installer-type'), @('locale','--locale'))) {
            if ($package.ContainsKey($mapping[0])) { $arguments += @($mapping[1], [string]$package[$mapping[0]]) }
        }
        & winget @arguments
        if ($LASTEXITCODE -ne 0) { throw "Download failed for $($package.id): $LASTEXITCODE" }
        $entry = ConvertTo-OfflinePackage $download $bundle $package.id $configData.architecture
        $entry.scope = if ($package.ContainsKey('scope')) { $package.scope } else { $null }
        $lock.packages += $entry
    }
    $lock | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath "$bundle/packages.json" -Encoding utf8
    Copy-Item -LiteralPath "$PSScriptRoot/install.ps1", "$PSScriptRoot/server.ps1", "$PSScriptRoot/install.cmd" -Destination $bundle
    Copy-Item -LiteralPath "$PSScriptRoot/../README.md" -Destination $bundle
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $zip = Join-Path $OutputDirectory "winget-offline-$($configData.architecture).zip"
    # .NET ZipFile supports ZIP64 and large installers, unlike Compress-Archive's 2 GB limit.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryZip = Join-Path $work 'bundle.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $temporaryZip, [IO.Compression.CompressionLevel]::Fastest, $false)
    Move-Item -LiteralPath $temporaryZip -Destination $zip -Force
    Write-Host "Created $zip"
} finally {
    # Only delete this invocation's freshly generated temp directory.
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
