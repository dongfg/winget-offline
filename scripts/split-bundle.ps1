#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][ValidatePattern('^winget-offline-(x64|x86|arm64)\.zip$')][string]$ArchiveName,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[long]$partSize = 1GB # PowerShell's GB unit is 1024^3 bytes (1 GiB).
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -ne 0) {
    throw 'Output directory must be empty to avoid mixing builds.'
}
$source = Get-Item -LiteralPath $Archive
Write-Host "Hashing complete ZIP ($($source.Length) bytes) before splitting..."
$manifest = [ordered]@{
    schemaVersion = 1; archive = $ArchiveName; size = $source.Length
    sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    parts = @()
}
$inputStream = [IO.File]::OpenRead($source.FullName)
Write-Host 'Splitting ZIP into 1 GiB chunks...'
try {
    $buffer = [byte[]]::new(4MB)
    $index = 1
    while ($inputStream.Position -lt $inputStream.Length) {
        $name = '{0}.{1:000}' -f $ArchiveName, $index
        $path = Join-Path $OutputDirectory $name
        $outputStream = [IO.File]::Create($path)
        try {
            # Both arguments must be Int64: PowerShell otherwise picks Int32 Min
            # when the first argument is 1GB, overflowing for archives above 2 GiB.
            [long]$remaining = [Math]::Min($partSize, [long]($inputStream.Length - $inputStream.Position))
            while ($remaining -gt 0) {
                $read = $inputStream.Read($buffer, 0, [int][Math]::Min([long]$buffer.Length, $remaining))
                if ($read -eq 0) { throw 'Unexpected end of ZIP.' }
                $outputStream.Write($buffer, 0, $read)
                $remaining -= $read
            }
        } finally { $outputStream.Dispose() }
        $manifest.parts += [ordered]@{
            name = $name; size = (Get-Item -LiteralPath $path).Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        Write-Host "Created $name"
        $index++
    }
} finally { $inputStream.Dispose() }
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'bundle-parts.json') -Encoding utf8
Copy-Item -LiteralPath "$PSScriptRoot/extract.cmd", "$PSScriptRoot/extract.ps1" -Destination $OutputDirectory
