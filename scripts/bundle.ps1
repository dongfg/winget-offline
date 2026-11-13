Set-StrictMode -Version Latest

function ConvertTo-OfflinePackage {
    param([string]$DownloadDirectory, [string]$BundleDirectory, [string]$Id, [string]$Architecture)
    $yamlFiles = @(Get-ChildItem -LiteralPath $DownloadDirectory -Recurse -File -Filter *.yaml)
    if ($yamlFiles.Count -ne 1) { throw "$Id : expected exactly one merged manifest, found $($yamlFiles.Count)" }
    $manifest = Get-Content -LiteralPath $yamlFiles[0].FullName -Raw | ConvertFrom-Yaml -Ordered
    if ($manifest.PackageIdentifier -cne $Id) { throw "Manifest ID mismatch: $Id" }
    if ($manifest.ManifestType -notin @('merged', 'singleton')) { throw "$Id : expected a merged manifest from winget download" }
    $manifest.ManifestType = 'singleton'
    $byHash = @{}
    foreach ($file in Get-ChildItem -LiteralPath $DownloadDirectory -Recurse -File) {
        if ($file.Extension -in @('.yaml', '.yml')) { continue }
        $byHash[(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash] = $file
    }
    $selected = @()
    $payloads = @()
    foreach ($installer in $manifest.Installers) {
        $hash = [string]$installer.InstallerSha256
        if (-not $byHash.ContainsKey($hash)) { continue }
        if ($installer.Architecture -notin @($Architecture, 'neutral')) { continue }
        $type = if ($installer.Contains('InstallerType')) { $installer.InstallerType } else { $manifest.InstallerType }
        if ($type -notin @('exe', 'inno', 'nullsoft', 'burn', 'msi', 'wix', 'msix')) {
            throw "$Id : unsupported installer type '$type' (portable, ZIP and Store are excluded in V1)"
        }
        foreach ($node in @($manifest, $installer)) {
            if ($node.Contains('Dependencies') -and $node.Dependencies.Count -gt 0) {
                throw "$Id : additional dependencies are not supported in V1; use a self-contained installer/package"
            }
        }
        $file = $byHash[$hash]
        $name = $hash.ToLowerInvariant() + $file.Extension.ToLowerInvariant()
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $BundleDirectory "packages/$name") -Force
        $originalUrl = $installer.InstallerUrl
        $installer.InstallerUrl = "http://127.0.0.1:__PORT__/packages/$name"
        $selected += $installer
        $payloads += [ordered]@{ path = "packages/$name"; sha256 = $hash; originalUrl = $originalUrl; installerType = $type }
    }
    if ($selected.Count -ne 1) { throw "$Id : expected one downloaded applicable installer, found $($selected.Count)" }
    $manifest.Installers = $selected
    $manifestPath = "manifests/$Id.yaml"
    $manifest | ConvertTo-Yaml | Set-Content -LiteralPath (Join-Path $BundleDirectory $manifestPath) -Encoding utf8
    return [ordered]@{
        id = $Id; version = [string]$manifest.PackageVersion; manifest = $manifestPath
        manifestSha256 = (Get-FileHash -LiteralPath (Join-Path $BundleDirectory $manifestPath)).Hash
        payloads = $payloads
    }
}
