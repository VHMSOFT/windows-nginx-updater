#Requires -Version 5.1
<#
.SYNOPSIS
    Module loader for NginxUpdater - the Windows nginx lifecycle manager.
.DESCRIPTION
    Sets module-wide state (StrictMode, TLS 1.2, constants), dot-sources the Private and Public
    function files, and exports the single public entry point Invoke-NginxUpdater.
#>

Set-StrictMode -Version Latest

# Windows PowerShell 5.1 does not enable TLS 1.2 by default; nginx.org requires it.
# Also silence the progress bar so downloads on 5.1 aren't crippled by it.
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose 'Could not set TLS 1.2 explicitly; relying on system defaults.'
}

# Module-scope constants and state (visible to every function in the module).
$script:DownloadPage = 'https://nginx.org/en/download.html'
$script:DownloadBase = 'https://nginx.org/download'          # /nginx-<ver>.zip
$script:ConfigFileName = '.nginx-updater.json'                # stored inside the root
$script:VersionsDir = 'versions'
$script:Invocation = @{}                                      # original args, for elevation relaunch
$script:ModuleRoot = $PSScriptRoot                            # this module's folder
$script:PendingUpdate = $null                                 # set by the self-updater when one is staged

# Self-update: repo release APIs, primary first. Each install records per-mirror health and prefers
# a mirror that last worked (see SelfUpdate.ps1).
$script:RepoWeb = 'https://github.com/VHMSOFT/windows-nginx-updater'
$script:Mirrors = @(
    [pscustomobject]@{
        Name       = 'github'
        ReleaseApi = 'https://api.github.com/repos/VHMSOFT/windows-nginx-updater/releases/latest'
    }
)

# $IsWindows is a PS7 automatic variable that does NOT exist in Windows PowerShell 5.1
# (referencing it under StrictMode would throw). Detect it safely: absent => we are on 5.1,
# which only runs on Windows.
$script:OnWindows = $true
if (Test-Path Variable:\IsWindows) { $script:OnWindows = [bool](Get-Variable -Name IsWindows -ValueOnly) }

# Dot-source all function files. Load order is irrelevant: nothing is invoked until the caller
# runs Invoke-NginxUpdater, by which point every function is defined.
foreach ($folder in 'Private', 'Public') {
    $dir = Join-Path $PSScriptRoot $folder
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }
    }
}

Export-ModuleMember -Function 'Invoke-NginxUpdater'
