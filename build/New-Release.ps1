#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the release zip of the minimal runtime files (runAsAdmin.cmd, Update-Nginx.ps1, NginxUpdater\).
.DESCRIPTION
    Reads the version from NginxUpdater\NginxUpdater.psd1 and produces
    <OutputDir>\windows-nginx-updater-<version>.zip containing only the files an install needs.
    Runs on Windows PowerShell 5.1 and PowerShell 7+ (uses Compress-Archive).
.PARAMETER OutputDir
    Folder to write the zip into. Defaults to <repo>\dist.
.EXAMPLE
    ./build/New-Release.ps1
.EXAMPLE
    ./build/New-Release.ps1 -OutputDir artifacts
#>
[CmdletBinding()]
param(
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'dist' }

$manifestPath = Join-Path $repoRoot 'NginxUpdater\NginxUpdater.psd1'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest not found: $manifestPath" }
$version = (Import-PowerShellDataFile -LiteralPath $manifestPath).ModuleVersion
Write-Host "Building windows-nginx-updater v$version" -ForegroundColor Cyan

# The minimal set an install needs to run and self-update.
$items = 'runAsAdmin.cmd', 'Update-Nginx.ps1', 'NginxUpdater'
foreach ($i in $items) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $i))) { throw "Missing expected item: $i" }
}

# Stage a clean copy so the zip contains exactly these items (and no dev/state cruft).
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "wnu-build-$suffix"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    foreach ($i in $items) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $i) -Destination $stage -Recurse -Force
    }
    # Drop any per-install state that must never ship in a release.
    foreach ($junk in '.update', '.nginx-updater-selfupdate.json', '.nginx-updater.json') {
        $p = Join-Path $stage $junk
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $zipPath = Join-Path $OutputDir "windows-nginx-updater-$version.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force
    $size = (Get-Item -LiteralPath $zipPath).Length
    Write-Host ('Wrote {0} ({1:N0} bytes)' -f $zipPath, $size) -ForegroundColor Green

    # Emit the version for CI (e.g. GitHub Actions) to consume.
    if ($env:GITHUB_OUTPUT) {
        "version=$version" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        "zip=$zipPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
    return $zipPath
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
