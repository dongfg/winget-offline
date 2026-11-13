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
$parallelDownloads = if ($configData.ContainsKey('parallelDownloads')) { $configData.parallelDownloads } else { 4 }
if (($parallelDownloads -isnot [int] -and $parallelDownloads -isnot [long]) -or $parallelDownloads -lt 1 -or $parallelDownloads -gt 32) {
    throw 'parallelDownloads must be an integer between 1 and 32'
}
$seen = @{}
foreach ($package in $configData.packages) {
    if ($package.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]+$' -or $seen.ContainsKey($package.id)) { throw "Invalid or duplicate package ID: $($package.id)" }
    $seen[$package.id] = $true
    foreach ($key in $package.Keys) {
        if ($key -notin @('id', 'version', 'scope', 'installerType', 'locale', 'installMode', 'architecture')) { throw "Unknown package option: $key" }
        if ([string]::IsNullOrWhiteSpace([string]$package[$key])) { throw "Empty option: $key" }
    }
    if ($package.ContainsKey('scope') -and $package.scope -notin @('user', 'machine')) { throw 'Invalid scope' }
    if ($package.ContainsKey('installMode') -and $package.installMode -cnotin @('silent', 'interactive')) { throw 'installMode must be silent or interactive' }
    $packageArchitecture = if ($package.ContainsKey('architecture')) { $package.architecture } else { $configData.architecture }
    if ($packageArchitecture -cne $configData.architecture -and -not ($configData.architecture -eq 'x64' -and $packageArchitecture -ceq 'x86')) {
        throw "$($package.id): architecture must match the bundle, or be x86 for an x64 bundle"
    }
}
$wingetPath = (Get-Command winget -ErrorAction Stop).Source
$work = Join-Path ([IO.Path]::GetTempPath()) ("winget-offline-" + [guid]::NewGuid())
$bundle = Join-Path $work 'bundle'
New-Item -ItemType Directory -Path "$bundle/packages", "$bundle/manifests" -Force | Out-Null
try {
    $lock = [ordered]@{ schemaVersion = 1; architecture = $configData.architecture; builtAt = [DateTime]::UtcNow.ToString('o'); packages = @() }
    $bundleArchitecture = $configData.architecture
    $downloadFailures = [Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
    Write-Host "Downloading with up to $parallelDownloads packages in parallel..."
    $configData.packages | ForEach-Object -ThrottleLimit $parallelDownloads -Parallel {
        $ErrorActionPreference = 'Stop'
        $failures = $using:downloadFailures
        # Stop starting queued downloads after a failure; finish active work before cleanup.
        if (-not $failures.IsEmpty) { return }
        $package = $_
        try {
            $download = Join-Path $using:work $package.id
            $packageArchitecture = if ($package.ContainsKey('architecture')) { $package.architecture } else { $using:bundleArchitecture }
            $arguments = @('download', '--id', $package.id, '--exact', '--source', 'winget', '--architecture', $packageArchitecture,
                '--download-directory', $download, '--skip-dependencies', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
            foreach ($mapping in @(@('version','--version'), @('scope','--scope'), @('installerType','--installer-type'), @('locale','--locale'))) {
                if ($package.ContainsKey($mapping[0])) { $arguments += @($mapping[1], [string]$package[$mapping[0]]) }
            }
            Write-Host "[$($package.id)] Starting download..."
            & $using:wingetPath @arguments
            if ($LASTEXITCODE -ne 0) { throw "WinGet exited with $LASTEXITCODE" }
        } catch {
            $failures[$package.id] = $_.Exception.Message
        }
    }
    if (-not $downloadFailures.IsEmpty) {
        $details = ($downloadFailures.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join '; '
        throw "Downloads failed: $details"
    }
    # Merge only after all workers finish, in configuration order. Shared payload hashes
    # are copied serially to avoid concurrent writes when two packages share a file.
    foreach ($package in $configData.packages) {
        $download = Join-Path $work $package.id
        $packageArchitecture = if ($package.ContainsKey('architecture')) { $package.architecture } else { $configData.architecture }
        $entry = ConvertTo-OfflinePackage $download $bundle $package.id $packageArchitecture
        $entry.architecture = $packageArchitecture
        $entry.scope = if ($package.ContainsKey('scope')) { $package.scope } elseif ($entry.payloads[0].effectiveInstallerType -eq 'portable') { 'machine' } else { $null }
        $entry.installMode = if ($package.ContainsKey('installMode')) { $package.installMode } else { 'silent' }
        $lock.packages += $entry
    }
    $lock | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath "$bundle/packages.json" -Encoding utf8
    Copy-Item -LiteralPath "$PSScriptRoot/install.ps1", "$PSScriptRoot/server.ps1", "$PSScriptRoot/install.cmd" -Destination $bundle
    Copy-Item -LiteralPath "$PSScriptRoot/../README.md", "$PSScriptRoot/../LICENSE" -Destination $bundle
    # .NET ZipFile supports ZIP64 and large installers, unlike Compress-Archive's 2 GB limit.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryZip = Join-Path $work 'bundle.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $temporaryZip, [IO.Compression.CompressionLevel]::Fastest, $false)
    & "$PSScriptRoot/split-bundle.ps1" -Archive $temporaryZip -ArchiveName "winget-offline-$($configData.architecture).zip" -OutputDirectory $OutputDirectory
} finally {
    # Only delete this invocation's freshly generated temp directory.
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
