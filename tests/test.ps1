#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module powershell-yaml -RequiredVersion 0.4.12
. "$PSScriptRoot/../scripts/bundle.ps1"
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { if ("$_" -match $Pattern) { return }; throw }
    throw "Expected error: $Pattern"
}
$work = Join-Path ([IO.Path]::GetTempPath()) ('winget-offline-tests-' + [guid]::NewGuid())
$job = $null
New-Item -ItemType Directory -Path "$work/download", "$work/bundle/packages", "$work/bundle/manifests" -Force | Out-Null
try {
    [IO.File]::WriteAllBytes("$work/download/setup.msi", [byte[]](0..255) * 1000)
    $hash = (Get-FileHash "$work/download/setup.msi").Hash
    $data = [ordered]@{
        PackageIdentifier = 'Test.App'; PackageVersion = '1.0'; PackageLocale = 'en-US'
        Publisher = 'Test'; PackageName = 'Test'; License = 'MIT'; ShortDescription = 'Test'
        ManifestType = 'merged'; ManifestVersion = '1.6.0'
        Installers = @(
            [ordered]@{ Architecture = 'x64'; InstallerType = 'msi'; InstallerUrl = 'https://example.com/setup.msi'; InstallerSha256 = $hash; ProductCode = '{12345678-1234-1234-1234-123456789012}'; InstallerSwitches = @{ Silent = '/quiet' } },
            [ordered]@{ Architecture = 'arm64'; InstallerType = 'msi'; InstallerUrl = 'https://example.com/other.msi'; InstallerSha256 = ('0' * 64) }
        )
    }
    function Save-Manifest { $data | ConvertTo-Yaml | Set-Content "$work/download/app.yaml" -Encoding utf8 }
    Save-Manifest
    $entry = ConvertTo-OfflinePackage "$work/download" "$work/bundle" 'Test.App' 'x64'
    $result = Get-Content "$work/bundle/manifests/Test.App.yaml" -Raw | ConvertFrom-Yaml
    Assert ($result.Installers.Count -eq 1) 'Installer selection failed'
    Assert ($result.ManifestType -eq 'singleton') 'Merged format was not normalized'
    Assert ($result.Installers[0].InstallerSwitches.Silent -eq '/quiet') 'Switches lost'
    Assert ($result.Installers[0].ProductCode -eq $data.Installers[0].ProductCode) 'Detection metadata lost'
    Assert ($result.Installers[0].InstallerUrl -match '^http://127\.0\.0\.1:__PORT__/packages/[a-f0-9]{64}\.msi$') 'URL was not rewritten'
    $data.Installers[0].Dependencies = @{ PackageDependencies = @(@{ PackageIdentifier = 'Test.Dependency' }) }
    Save-Manifest
    Assert-Throws { ConvertTo-OfflinePackage "$work/download" "$work/bundle" 'Test.App' 'x64' } 'dependencies'
    $data.Installers[0].Remove('Dependencies')
    $data.Installers[0].InstallerType = 'portable'
    Save-Manifest
    Assert-Throws { ConvertTo-OfflinePackage "$work/download" "$work/bundle" 'Test.App' 'x64' } 'unsupported installer'
    $data.Installers[0].InstallerType = 'msi'
    $data.Installers[0].InstallerSha256 = '1' * 64
    Save-Manifest
    Assert-Throws { ConvertTo-OfflinePackage "$work/download" "$work/bundle" 'Test.App' 'x64' } 'found 0'

    $ready = "$work/port.txt"
    $job = Start-Job -FilePath "$PSScriptRoot/../scripts/server.ps1" -ArgumentList "$work/bundle/packages", $ready
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path $ready)) {
        if ($job.State -ne 'Running' -or [DateTime]::UtcNow -gt $deadline) { Receive-Job $job; throw 'Server did not start' }
        Start-Sleep -Milliseconds 100
    }
    $port = [int](Get-Content $ready -Raw)
    $url = "http://127.0.0.1:$port/$($entry.payloads[0].path)"
    Invoke-WebRequest $url -OutFile "$work/received.msi"
    Assert ((Get-FileHash "$work/received.msi").Hash -eq $hash) 'HTTP response corrupted'
    $head = Invoke-WebRequest $url -Method Head
    Assert ([long]$head.Headers['Content-Length'][0] -eq 256000) 'HEAD length mismatch'
    foreach ($path in @('/packages/missing.exe', '/packages/../port.txt', '/manifests/Test.App.yaml')) {
        $response = Invoke-WebRequest "http://127.0.0.1:$port$path" -SkipHttpErrorCheck
        Assert ($response.StatusCode -eq 404) "Unexpected access: $path"
    }
    Write-Host 'All manifest conversion and HTTP tests passed.'
} finally {
    if ($job) { Stop-Job $job; Remove-Job $job -Force }
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
