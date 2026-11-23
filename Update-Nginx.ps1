#Requires -Version 5.1
<#
.SYNOPSIS
    Launcher for the NginxUpdater module - a Windows nginx lifecycle manager.
.DESCRIPTION
    Imports the bundled NginxUpdater module (from the .\NginxUpdater folder next to this script)
    and runs its interactive menu. All the logic lives in the module; this file only wires up
    parameters and passes its own path through so an elevation relaunch re-runs this launcher.
.PARAMETER Root
    nginx root folder to manage (the folder that holds conf\, html\, logs\, nginx.exe). Optional:
    when omitted the tool auto-detects the root from ..\nginx.exe (tool deployed as a subfolder of
    the root), or asks. No parameter is required - it can be run with no arguments.
.PARAMETER NssmPath
    Path to nssm.exe (only needed to CREATE a service). Auto-detected if omitted.
.PARAMETER ServiceName
    Windows service name to manage. Auto-detected / created if omitted.
.PARAMETER Channel
    Release channel default: 'stable', 'mainline', or 'ask'.
.PARAMETER Status
    Skip the interactive menu and just report state, then exit.
.PARAMETER SkipUpdateCheck
    Skip the startup self-update check (for offline or locked-down servers).
.PARAMETER Mode
    'managed' - this install manages one nginx root (the default; what the tool always did) - or
    'manager' - a single install per server that tracks every managed install, keeps their tool code
    up to date and can update nginx on all of them at once. Remembered per install once chosen from
    the first-run prompt; pass it explicitly to override.
.PARAMETER Action
    Manager mode only: Menu (default, interactive) | Status | UpdateTools | UpdateNginx | Restart.
    Everything except Menu runs once without prompting and exits 0 (ok) or 1 (a failure) - for
    scheduled tasks. UpdateNginx/Restart need Administrator.
.PARAMETER Restart
    Manager mode, -Action UpdateNginx: also restart each service after updating (config tested first).
    Without it, new nginx binaries activate at each install's next natural restart.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Update-Nginx.ps1 -Root C:\nginx
.NOTES
    Requires Administrator for symlink creation and service management; the tool offers to relaunch
    elevated. Runs on Windows PowerShell 5.1 (built in) as well as PowerShell 7+.
#>

[CmdletBinding()]
param(
    [string]$Root,
    [string]$NssmPath,
    [string]$ServiceName,
    [ValidateSet('stable', 'mainline', 'ask')]
    [string]$Channel = 'ask',
    [switch]$Status,
    [switch]$SkipUpdateCheck,
    [ValidateSet('managed', 'manager')]
    [string]$Mode,
    [ValidateSet('Menu', 'Status', 'UpdateTools', 'UpdateNginx', 'Restart')]
    [string]$Action = 'Menu',
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot 'NginxUpdater\NginxUpdater.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "NginxUpdater module not found at '$manifest'. Keep the NginxUpdater folder next to this script."
}
Import-Module $manifest -Force

# Only forward -Channel / -Mode when given, so the module can tell "explicit" from "default".
$extra = @{}
if ($PSBoundParameters.ContainsKey('Channel')) { $extra.Channel = $Channel }
if ($PSBoundParameters.ContainsKey('Mode')) { $extra.Mode = $Mode }

$global:NginxUpdaterExitCode = 0
Invoke-NginxUpdater -Root $Root -NssmPath $NssmPath -ServiceName $ServiceName @extra `
    -Status:$Status -SkipUpdateCheck:$SkipUpdateCheck -Action $Action -Restart:$Restart `
    -LauncherPath $PSCommandPath
if ($Action -ne 'Menu' -and $global:NginxUpdaterExitCode) { exit $global:NginxUpdaterExitCode }
