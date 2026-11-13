#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $IsWindows) { throw 'The bundle build requires a Windows runner.' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run the CNB Windows runner under an administrator account with WinGet available.'
}
Install-Module Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force
Repair-WinGetPackageManager -AllUsers
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Repository PSGallery -Scope CurrentUser -Force
& winget --version
if ($LASTEXITCODE -ne 0) { throw 'WinGet is unavailable in the runner account.' }
