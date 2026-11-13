#Requires -Version 5.1
[CmdletBinding()]
param([switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 progress rendering makes large Invoke-WebRequest transfers very slow.
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
$bundle = $PSScriptRoot
$job = $null
$changedSetting = $false
$transcribing = $false
$exitCode = 0
$temp = $null
$mutex = $null
$ownsMutex = $false

function Get-BundlePath([string]$Relative) {
    $base = [IO.Path]::GetFullPath($bundle).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $bundle $Relative))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Path outside bundle: $Relative" }
    return $path
}

try {
    if (-not $VerifyOnly) {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $process = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')) -Verb RunAs -Wait -PassThru
            exit $process.ExitCode
        }
        $mutex = New-Object Threading.Mutex($false, 'Global\WinGetOfflineBundleInstall')
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'Another offline installation is running.' }
    }
    $lock = Get-Content -LiteralPath "$bundle/packages.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($lock.schemaVersion -ne 1 -or @($lock.packages).Count -eq 0) { throw 'Invalid bundle lock file.' }
    $nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $architecture = switch ($nativeArch) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } 'x86' { 'x86' } default { throw "Unknown OS architecture: $nativeArch" } }
    if ($lock.architecture -ne $architecture) { throw "Bundle is $($lock.architecture); this Windows system is $architecture." }
    $logDirectory = Join-Path $bundle ('logs/' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    Start-Transcript -LiteralPath "$logDirectory/install.log" | Out-Null
    $transcribing = $true
    Write-Host 'Checking all manifests and installers before starting...'
    foreach ($package in $lock.packages) {
        if ($package.PSObject.Properties['installMode'] -and $package.installMode -cnotin @('silent', 'interactive')) {
            throw "Invalid installMode for $($package.id): $($package.installMode)"
        }
        $path = Get-BundlePath $package.manifest
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $package.manifestSha256) { throw "Manifest checksum mismatch: $($package.id)" }
        foreach ($payload in $package.payloads) {
            $path = Get-BundlePath $payload.path
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $payload.sha256) { throw "Installer checksum mismatch: $($package.id)" }
        }
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('winget-offline-install-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $temp | Out-Null
    $ready = Join-Path $temp 'port.txt'
    $job = Start-Job -FilePath "$bundle/server.ps1" -ArgumentList "$bundle/packages", $ready
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $ready)) {
        if ($job.State -in @('Failed', 'Completed', 'Stopped') -or [DateTime]::UtcNow -gt $deadline) {
            Receive-Job $job
            throw 'Local HTTP server failed to start.'
        }
        Start-Sleep -Milliseconds 100
    }
    $port = [int](Get-Content -LiteralPath $ready -Raw)
    Write-Host "Local installer server: http://127.0.0.1:$port"
    if ($VerifyOnly) {
        foreach ($package in $lock.packages) {
            foreach ($payload in $package.payloads) {
                Write-Host "Verifying local HTTP transfer: $($package.id) $($package.version)..."
                $target = Join-Path $temp 'http-check'
                Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/$($payload.path)" -OutFile $target -TimeoutSec 120
                if ((Get-FileHash -LiteralPath $target).Hash -ne $payload.sha256) { throw 'HTTP payload checksum mismatch.' }
            }
        }
        Write-Host 'Verification passed. No applications were installed.'
    } else {
        Get-Command winget -ErrorAction Stop | Out-Null
        $settingsOutput = & winget settings export
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect WinGet settings. Install a current stable WinGet release.' }
        $settings = ($settingsOutput -join "`n") | ConvertFrom-Json
        if (-not $settings.adminSettings.LocalManifestFiles) {
            # Set before invoking to ensure cleanup if the command partially succeeds.
            $changedSetting = $true
            & winget settings --enable LocalManifestFiles
            if ($LASTEXITCODE -ne 0) { throw 'Cannot enable LocalManifestFiles (check administrator rights and policy).' }
        }
        $results = @()
        foreach ($package in $lock.packages) {
            $template = Get-Content -LiteralPath (Get-BundlePath $package.manifest) -Raw -Encoding UTF8
            $manifest = Join-Path $temp ([IO.Path]::GetFileName($package.manifest))
            [IO.File]::WriteAllText($manifest, $template.Replace('http://127.0.0.1:__PORT__/', "http://127.0.0.1:$port/"), (New-Object Text.UTF8Encoding($false)))
            # Older bundles without this property retain the original silent behavior.
            $installMode = if ($package.PSObject.Properties['installMode']) { $package.installMode } else { 'silent' }
            Write-Host "Installing $($package.id) $($package.version) ($installMode)..."
            $arguments = @('install', '--manifest', $manifest, '--architecture', $lock.architecture, '--accept-package-agreements', '--accept-source-agreements', '--skip-dependencies')
            if ($installMode -eq 'interactive') {
                $arguments += '--interactive'
            } else {
                $arguments += @('--silent', '--disable-interactivity')
            }
            if ($package.scope) { $arguments += @('--scope', $package.scope) }
            & winget @arguments
            $code = $LASTEXITCODE
            # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE: installed version is equal or newer.
            $status = if ($code -eq 0) { 'success' } elseif ($code -eq -1978335189) { 'skipped' } else { 'failed' }
            $results += [pscustomobject]@{ id = $package.id; version = $package.version; status = $status; exitCode = $code }
            $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$logDirectory/results.json" -Encoding UTF8
            if ($status -eq 'failed') { $exitCode = 1 }
        }
        $results | Format-Table -AutoSize | Out-Host
        Write-Host "Logs: $logDirectory"
    }
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($job) { Stop-Job $job; Remove-Job $job -Force }
    if ($changedSetting) {
        & winget settings --disable LocalManifestFiles
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not restore LocalManifestFiles; run winget settings --disable LocalManifestFiles as administrator.'; $exitCode = 1 }
    }
    if ($temp -and (Test-Path -LiteralPath $temp)) {
        if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $temp -Recurse -Force
        }
    }
    if ($transcribing) { Stop-Transcript | Out-Null }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
exit $exitCode
