#Requires -Version 5.1
[CmdletBinding()]
param([string]$DestinationDirectory)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
$work = $null
try {
    $manifest = Get-Content -LiteralPath "$PSScriptRoot/bundle-parts.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.archive -notmatch '^winget-offline-(x64|x86|arm64)\.zip$' -or
        $manifest.size -le 0 -or $manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or @($manifest.parts).Count -eq 0) {
        throw 'Invalid bundle-parts.json.'
    }
    if (-not $DestinationDirectory) {
        $DestinationDirectory = Join-Path $PSScriptRoot ([IO.Path]::GetFileNameWithoutExtension($manifest.archive))
    }
    $destination = [IO.Path]::GetFullPath($DestinationDirectory)
    if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination. Choose another directory or move the existing one." }
    # Validate the complete set before creating the temporary merged ZIP.
    [long]$total = 0
    $index = 1
    foreach ($part in $manifest.parts) {
        $expectedName = '{0}.{1:000}' -f $manifest.archive, $index
        if ($part.name -cne $expectedName -or $part.size -le 0 -or $part.size -gt 1GB -or
            ($index -lt @($manifest.parts).Count -and $part.size -ne 1GB) -or
            $part.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid part entry: $expectedName" }
        $path = Join-Path $PSScriptRoot $expectedName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing part: $expectedName. Download every part from the same release." }
        if ((Get-Item -LiteralPath $path).Length -ne $part.size) { throw "Size mismatch: $expectedName" }
        $total += $part.size
        $index++
    }
    if ($total -ne $manifest.size) { throw 'Total ZIP size mismatch in bundle-parts.json.' }
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $work = Join-Path $parent ('.winget-extract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $archive = Join-Path $work 'bundle.zip'
    $outputStream = [IO.File]::Create($archive)
    try {
        foreach ($part in $manifest.parts) {
            Write-Host "Verifying and merging $($part.name)..."
            $path = Join-Path $PSScriptRoot $part.name
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $part.sha256) {
                throw "SHA256 mismatch: $($part.name). Download this part again."
            }
            $inputStream = [IO.File]::OpenRead($path)
            try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose() }
        }
    } finally { $outputStream.Dispose() }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $manifest.sha256) { throw 'Merged ZIP SHA256 mismatch.' }
    Write-Host 'Extracting ZIP...'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extracted = Join-Path $work 'extracted'
    # Use ZIP64-capable .NET directly, without Expand-Archive's size restrictions.
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extracted)
    Move-Item -LiteralPath $extracted -Destination $destination
    Write-Host "Extracted to $destination"
    Write-Host 'Run install.cmd in that directory to install the software.'
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    # Only remove the unique directory created by this invocation, beside destination.
    if ($work -and (Test-Path -LiteralPath $work)) {
        $resolvedWork = [IO.Path]::GetFullPath($work)
        if ((Split-Path -Parent $resolvedWork) -eq $parent -and (Split-Path -Leaf $resolvedWork) -match '^\.winget-extract-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedWork -Recurse -Force
        }
    }
}
