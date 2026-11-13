#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$archives = @(Get-ChildItem -LiteralPath "$root/dist" -Filter *.zip -File)
if ($archives.Count -ne 1) { throw 'Expected exactly one bundle ZIP in dist.' }
$destination = Join-Path $root ('.work/cnb-verify-' + [guid]::NewGuid())
Expand-Archive -LiteralPath $archives[0].FullName -DestinationPath $destination
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$destination/install.ps1" -VerifyOnly
if ($LASTEXITCODE -ne 0) { throw 'Bundle verification failed.' }
