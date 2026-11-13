#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Publish', 'Cleanup')][string]$Mode)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
foreach ($name in @('CNB_API_ENDPOINT', 'CNB_REPO_SLUG', 'CNB_TOKEN')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Missing CNB environment variable: $name" }
}
$endpoint = [uri]($env:CNB_API_ENDPOINT.TrimEnd('/') + '/')
$repo = (($env:CNB_REPO_SLUG -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
$base = "$repo/-"
$headers = @{ Authorization = "Bearer $env:CNB_TOKEN"; Accept = 'application/vnd.cnb.api+json' }

function Invoke-CnbApi([string]$Method, [string]$Path, [object]$Body = $null) {
    $uri = [uri]::new($endpoint, $Path)
    # Verification URLs come from the API; never send its bearer token to object storage.
    if ($uri.Scheme -ne $endpoint.Scheme -or $uri.Authority -ne $endpoint.Authority) { throw 'Unexpected CNB API URL origin.' }
    $parameters = @{ Uri = $uri; Method = $Method; Headers = $headers; TimeoutSec = 120 }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
    }
    Invoke-RestMethod @parameters
}

function Send-CnbAttachment([string]$Resource, [IO.FileInfo]$File, [int]$Days, [string]$Name) {
    $upload = Invoke-CnbApi POST "$Resource/asset-upload-url" @{ asset_name = $Name; size = $File.Length; ttl = $Days }
    Write-Host "Uploading $Name ($($File.Length) bytes)..."
    # Pre-signed URL authenticates the PUT; CNB_TOKEN must not be forwarded to storage.
    Invoke-WebRequest -Uri $upload.upload_url -Method Put -InFile $File.FullName -ContentType 'application/octet-stream' -TimeoutSec 900 | Out-Null
    $separator = if ($upload.verify_url.Contains('?')) { '&' } else { '?' }
    Invoke-CnbApi POST ($upload.verify_url + $separator + "ttl=$Days") | Out-Null
}

if ($Mode -eq 'Cleanup') {
    # Fetch all pages before deleting, so page offsets cannot shift during enumeration.
    $releases = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $batch = @(Invoke-CnbApi GET "$base/releases?page=$page&page_size=100")
        foreach ($release in $batch) { $releases.Add($release) }
        $page++
    } while ($batch.Count -eq 100)
    $published = @($releases | Where-Object { -not $_.draft -and $_.published_at } |
        Sort-Object -Property @{ Expression = { [DateTimeOffset]$_.published_at }; Descending = $true }, @{ Expression = { $_.id }; Descending = $true })
    Write-Host "Found $($published.Count) published releases; retaining the newest one."
    foreach ($release in ($published | Select-Object -Skip 1)) {
        Write-Host "Deleting release $($release.tag_name) ($($release.id))..."
        Invoke-CnbApi DELETE "$base/releases/$([uri]::EscapeDataString($release.id))" | Out-Null
    }
    exit 0
}

foreach ($name in @('CNB_COMMIT', 'CNB_BUILD_ID')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Missing CNB environment variable: $name" }
}
$root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem -LiteralPath "$root/dist" -Filter *.zip -File)
if ($files.Count -ne 1) { throw 'Expected exactly one bundle ZIP in dist.' }
$file = $files[0]
$commit = [uri]::EscapeDataString($env:CNB_COMMIT)
# Commit attachments replace GitHub's build artifacts and expire after 14 days.
$buildId = $env:CNB_BUILD_ID -replace '[^A-Za-z0-9._-]', '_'
$buildName = [IO.Path]::GetFileNameWithoutExtension($file.Name) + "-$buildId.zip"
Send-CnbAttachment "$base/git/commit-assets/$commit" $file 14 $buildName

$timestamp = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyyMMddHHmmss')
$release = Invoke-CnbApi POST "$base/releases" @{
    tag_name = $timestamp; name = $timestamp; target_commitish = $env:CNB_COMMIT
    draft = $true; prerelease = $false; make_latest = 'false'
    body = "WinGet offline bundle, commit $env:CNB_COMMIT. Extract the ZIP and run install.cmd. WinGet must be installed. Published at $timestamp (Asia/Shanghai)."
}
$resource = "$base/releases/$([uri]::EscapeDataString($release.id))"
# On failure leave the draft for inspection; daily cleanup ignores incomplete drafts.
Send-CnbAttachment $resource $file 0 $file.Name
Invoke-CnbApi PATCH $resource @{ draft = $false; make_latest = 'true' } | Out-Null
Write-Host "Published CNB release $timestamp."
