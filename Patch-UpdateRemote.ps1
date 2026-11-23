#Requires -Version 5.1
<#
.SYNOPSIS
    One-time patch: repoints an existing install's self-updater at the VHMSOFT GitHub repo.
.DESCRIPTION
    Older installs check releases on a Forgejo server and JFs743/windows-nginx-updater on GitHub,
    neither of which publishes releases any more. This rewrites the mirror list in the install's
    NginxUpdater\NginxUpdater.psm1 to point at VHMSOFT/windows-nginx-updater. The next normal run then
    self-updates to the latest release as usual.

    Run it from (or point -InstallDir at) the folder that contains Update-Nginx.ps1. Idempotent.
.PARAMETER InstallDir
    Folder containing Update-Nginx.ps1 and NginxUpdater\. Defaults to this script's folder.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Patch-UpdateRemote.ps1
.EXAMPLE
    .\Patch-UpdateRemote.ps1 -InstallDir C:\tools\nginx-updater -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallDir = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$psm1 = Join-Path $InstallDir 'NginxUpdater\NginxUpdater.psm1'
if (-not (Test-Path -LiteralPath $psm1)) { throw "Not an install folder (missing $psm1). Use -InstallDir." }

$newBlock = @'
$script:RepoWeb = 'https://github.com/VHMSOFT/windows-nginx-updater'
$script:Mirrors = @(
    [pscustomobject]@{
        Name       = 'github'
        ReleaseApi = 'https://api.github.com/repos/VHMSOFT/windows-nginx-updater/releases/latest'
    }
)
'@

$text = [System.IO.File]::ReadAllText($psm1)
if ($text -match 'repos/VHMSOFT/windows-nginx-updater/releases/latest' -and $text -notmatch 'git\.jfs743\.com') {
    Write-Host 'Already patched - nothing to do.' -ForegroundColor Green
    return
}

# Replace from the RepoWeb line through the closing ")" of the Mirrors array.
$pattern = '(?ms)^\$script:RepoWeb\s*=.*?^\)[ \t]*$'
if ($text -notmatch $pattern) { throw 'Could not find the mirror block in NginxUpdater.psm1; update this install manually.' }
$eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$patched = [regex]::Replace($text, $pattern, { param($m) ($newBlock -replace "`r?`n", $eol) }, 1)

if ($PSCmdlet.ShouldProcess($psm1, 'Repoint self-update at github.com/VHMSOFT/windows-nginx-updater')) {
    Copy-Item -LiteralPath $psm1 -Destination "$psm1.bak" -Force
    # UTF-8 with BOM: required for Windows PowerShell 5.1 to read non-ASCII correctly.
    [System.IO.File]::WriteAllText($psm1, $patched, (New-Object System.Text.UTF8Encoding($true)))
    # Drop stale per-mirror health so the new remote is tried fresh.
    $state = Join-Path $InstallDir '.nginx-updater-selfupdate.json'
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Force }
    Write-Host "Patched. Backup: $psm1.bak" -ForegroundColor Green
    Write-Host 'Run Update-Nginx.ps1 as usual; it will self-update from GitHub.'
}
