#Requires -Version 7.0
# Standalone local POC: real compression -> 1 GiB chunks -> PS 5.1 merge/extract.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$work = Join-Path ([IO.Path]::GetTempPath()) ('winget-archive-poc-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$work/source" -Force | Out-Null
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # Repeat a random 4 MiB block, larger than DEFLATE's window, so compression
    # still produces a ZIP above 2 GiB without requiring random generation per block.
    $buffer = [byte[]]::new(4MB)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($buffer) } finally { $random.Dispose() }
    $payload = "$work/source/payload.bin"
    $stream = [IO.File]::Create($payload)
    try {
        for ($i = 0; $i -lt 528; $i++) { $stream.Write($buffer, 0, $buffer.Length) }
    } finally { $stream.Dispose() }
    $sourceHash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
    Write-Host 'Compressing a 2 GiB + 64 MiB payload with the production ZIP API...'
    $archive = "$work/bundle.zip"
    [IO.Compression.ZipFile]::CreateFromDirectory("$work/source", $archive, [IO.Compression.CompressionLevel]::Fastest, $false)
    $archiveSize = (Get-Item -LiteralPath $archive).Length
    if ($archiveSize -le 2GB) { throw "POC ZIP is too small to exercise the bug: $archiveSize" }
    Write-Host "ZIP size: $archiveSize bytes"
    & "$PSScriptRoot/../scripts/split-bundle.ps1" -Archive $archive -ArchiveName winget-offline-x64.zip -OutputDirectory "$work/dist"
    $manifest = Get-Content -LiteralPath "$work/dist/bundle-parts.json" -Raw | ConvertFrom-Json
    if ($manifest.parts.Count -ne 3 -or $manifest.parts[0].size -ne 1GB -or $manifest.parts[1].size -ne 1GB -or
        $manifest.parts[2].size -le 0 -or $manifest.parts[2].size -ge 1GB) { throw 'Incorrect chunk sizes.' }
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$work/dist/extract.ps1" -DestinationDirectory "$work/result"
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell 5.1 extraction failed: $LASTEXITCODE" }
    if ((Get-Item -LiteralPath "$work/result/payload.bin").Length -ne (Get-Item -LiteralPath $payload).Length -or
        (Get-FileHash -LiteralPath "$work/result/payload.bin" -Algorithm SHA256).Hash -ne $sourceHash) {
        throw 'Extracted payload does not match the source.'
    }
    Write-Host 'PASS: compression, three chunks, PS 5.1 merge/extraction, and payload SHA256.'
} finally {
    $resolvedWork = [IO.Path]::GetFullPath($work)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ((Split-Path -Parent $resolvedWork) -eq $tempRoot -and
        (Split-Path -Leaf $resolvedWork) -match '^winget-archive-poc-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    }
}
