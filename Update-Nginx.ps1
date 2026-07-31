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
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot 'NginxUpdater\NginxUpdater.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "NginxUpdater module not found at '$manifest'. Keep the NginxUpdater folder next to this script."
}
Import-Module $manifest -Force

Invoke-NginxUpdater -Root $Root -NssmPath $NssmPath -ServiceName $ServiceName -Channel $Channel `
    -Status:$Status -LauncherPath $PSCommandPath
