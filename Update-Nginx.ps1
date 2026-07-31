#Requires -Version 5.1
<#
.SYNOPSIS
    nginx lifecycle manager for Windows (managed installs via versioned folders + symlink).
    Runs on Windows PowerShell 5.1 (the built-in shell) as well as PowerShell 7+.

.DESCRIPTION
    A numbered-menu tool that installs, upgrades, migrates and rolls back nginx on Windows
    without disturbing conf/ and html/. The active nginx.exe is a symbolic link that points at
    a specific build under <root>\versions\<version>\. Upgrades are staged and the symlink is
    repointed live (Windows allows renaming/relinking a running .exe), so the new binary goes
    live on the NEXT restart. You are prompted to restart now or wait for the next natural restart.

    Handles three starting states for a given root folder:
      * Empty folder      -> Scaffold a fresh managed install (+ optional NSSM service).
      * Manual install     -> Migrate in place to the managed layout (config/html preserved).
      * Managed install    -> Update / roll back between versions.

    Service model assumed: NSSM (but restart/start/stop use the standard Service APIs, so any
    Windows-service wrapper works; only *creating* a service needs nssm.exe).

.NOTES
    Requires Administrator (symlink creation + service management). The tool will offer to relaunch
    elevated. nginx is always launched with an explicit prefix: nginx.exe -p "<root>".
#>

[CmdletBinding()]
param(
    # nginx root folder to manage (the folder that holds conf\, html\, logs\, nginx.exe).
    [string]$Root,

    # Path to nssm.exe (only needed to CREATE a service). Auto-detected if omitted.
    [string]$NssmPath,

    # Windows service name to manage. Auto-detected / created if omitted.
    [string]$ServiceName,

    # Release channel default: 'stable', 'mainline', or 'ask'.
    [ValidateSet('stable', 'mainline', 'ask')]
    [string]$Channel = 'ask',

    # Skip the interactive menu and just report state, then exit.
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not enable TLS 1.2 by default; nginx.org requires it.
# Also silence the progress bar so downloads on 5.1 aren't crippled by it.
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ----------------------------------------------------------------------------------------------
#region Constants / globals
# ----------------------------------------------------------------------------------------------
$script:DownloadPage = 'https://nginx.org/en/download.html'
$script:DownloadBase = 'https://nginx.org/download'          # /nginx-<ver>.zip
$script:ConfigFileName = '.nginx-updater.json'                # stored inside the root
$script:VersionsDir = 'versions'
# $IsWindows is a PS7 automatic variable that does NOT exist in Windows PowerShell 5.1
# (referencing it under StrictMode would throw). Detect it safely: absent => we are on 5.1,
# which only runs on Windows.
$script:OnWindows = $true
if (Test-Path Variable:\IsWindows) { $script:OnWindows = [bool](Get-Variable -Name IsWindows -ValueOnly) }

#endregion

# ----------------------------------------------------------------------------------------------
#region Console helpers
# ----------------------------------------------------------------------------------------------
function Write-Info { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Good { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host $Message -ForegroundColor Red }
function Write-Head {
    param([string]$Message)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host " $Message" -ForegroundColor White
    Write-Host ('=' * 70) -ForegroundColor DarkGray
}

function Coalesce {
    # First non-null, non-empty value; falls back to the last argument.
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Values)
    foreach ($v in $Values) { if ($null -ne $v -and "$v" -ne '') { return $v } }
    return $null
}

function Read-Menu {
    param([string]$Prompt = 'Select an option')
    return (Read-Host "`n$Prompt").Trim()
}

function Confirm-YesNo {
    param([string]$Question, [bool]$DefaultYes = $false)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $ans = (Read-Host "$Question $suffix").Trim().ToLowerInvariant()
        if ([string]::IsNullOrEmpty($ans)) { return $DefaultYes }
        if ($ans -in 'y', 'yes') { return $true }
        if ($ans -in 'n', 'no')  { return $false }
        Write-Warn "Please answer y or n."
    }
}
#endregion

# ----------------------------------------------------------------------------------------------
#region Elevation
# ----------------------------------------------------------------------------------------------
function Test-Admin {
    if (-not $script:OnWindows) { return $false }
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Assert-Admin {
    param([string]$ForAction = 'this operation')
    if (Test-Admin) { return $true }
    Write-Warn "Administrator rights are required for $ForAction (symlinks + service control)."
    if (-not $script:OnWindows) {
        Write-Err "Not running on Windows — cannot elevate here."
        return $false
    }
    if (Confirm-YesNo "Relaunch this tool in an elevated window now?" $true) {
        $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($Root)        { $argList += @('-Root', "`"$Root`"") }
        if ($NssmPath)    { $argList += @('-NssmPath', "`"$NssmPath`"") }
        if ($ServiceName) { $argList += @('-ServiceName', "`"$ServiceName`"") }
        if ($Channel)     { $argList += @('-Channel', $Channel) }
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList | Out-Null
        Write-Info "An elevated window has been opened. You can close this one."
    }
    return $false
}
#endregion

# ----------------------------------------------------------------------------------------------
#region Config persistence  (per-root JSON at <root>\.nginx-updater.json)
# ----------------------------------------------------------------------------------------------
function Get-ConfigPath { param([string]$RootPath) return (Join-Path $RootPath $script:ConfigFileName) }

function Load-Config {
    param([string]$RootPath)
    # Plain hashtable (not [ordered]) so it passes by reference to [hashtable] params —
    # mutations inside operations propagate back to the caller instead of hitting a copy.
    $cfg = @{
        Root          = $RootPath
        ServiceName   = $ServiceName
        NssmPath      = $NssmPath
        Channel       = $Channel
        ActiveVersion = $null
    }
    $path = Get-ConfigPath $RootPath
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($k in @('ServiceName', 'NssmPath', 'Channel', 'ActiveVersion')) {
                if ($saved.PSObject.Properties.Name -contains $k -and $saved.$k -and -not $cfg[$k]) {
                    $cfg[$k] = $saved.$k
                }
            }
        } catch {
            Write-Warn "Could not read $path ($($_.Exception.Message)); using defaults."
        }
    }
    if (-not $cfg.Channel) { $cfg.Channel = 'ask' }
    return $cfg
}

function Save-Config {
    param([hashtable]$Config)
    $path = Get-ConfigPath $Config.Root
    try {
        [pscustomobject]@{
            Root          = $Config.Root
            ServiceName   = $Config.ServiceName
            NssmPath      = $Config.NssmPath
            Channel       = $Config.Channel
            ActiveVersion = if ($Config.ContainsKey('ActiveVersion')) { $Config.ActiveVersion } else { $null }
            UpdatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {
        Write-Warn "Could not save config to $path ($($_.Exception.Message))."
    }
}
#endregion

# ----------------------------------------------------------------------------------------------
#region State detection
# ----------------------------------------------------------------------------------------------
function Get-NginxExePath { param([string]$RootPath) return (Join-Path $RootPath 'nginx.exe') }

function Test-IsSymlink {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSObject.Properties.Name -contains 'LinkType' -and $item.LinkType) {
            return $item.LinkType -in 'SymbolicLink', 'Junction'
        }
        # Fallback: reparse-point attribute
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { return $false }
}

function Get-SymlinkTarget {
    param([string]$Path)
    # PS7 exposes .Target directly; Windows PowerShell 5.1 does not, so fall back to fsutil.
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSObject.Properties.Name -contains 'Target' -and $item.Target) {
            return @($item.Target)[0]
        }
    } catch {}
    if ($script:OnWindows) {
        try {
            $out = & cmd.exe /c "fsutil reparsepoint query `"$Path`"" 2>$null
            foreach ($ln in $out) {
                if ($ln -match 'Print Name:\s*(.+?)\s*$'      -and $Matches[1]) { return $Matches[1].Trim() }
            }
            foreach ($ln in $out) {
                if ($ln -match 'Substitute Name:\s*(.+?)\s*$' -and $Matches[1]) {
                    return ($Matches[1].Trim() -replace '^\\\?\?\\', '')
                }
            }
        } catch {}
    }
    return $null
}

function Get-RootState {
    <#
        Returns one of: 'Empty', 'Manual', 'Managed', 'Unknown'
        plus supporting details.
    #>
    param([string]$RootPath)

    $exe = Get-NginxExePath $RootPath
    $versionsPath = Join-Path $RootPath $script:VersionsDir
    $hasExe = Test-Path -LiteralPath $exe
    $isLink = $hasExe -and (Test-IsSymlink $exe)
    $hasVersions = Test-Path -LiteralPath $versionsPath

    $state = 'Unknown'
    if (-not (Test-Path -LiteralPath $RootPath)) {
        $state = 'Empty'
    } elseif (-not $hasExe -and -not $hasVersions) {
        # Folder exists but has no nginx at all -> treat as Empty (we scaffold).
        $state = 'Empty'
    } elseif ($isLink -and $hasVersions) {
        $state = 'Managed'
    } elseif ($hasExe -and -not $isLink) {
        $state = 'Manual'
    } elseif ($hasExe -and $isLink -and -not $hasVersions) {
        $state = 'Manual'   # dangling/foreign link; treat as needing migration
    }

    return [pscustomobject]@{
        Root         = $RootPath
        State        = $state
        ExePath      = $exe
        ExeExists    = $hasExe
        IsSymlink    = $isLink
        LinkTarget   = if ($isLink) { Get-SymlinkTarget $exe } else { $null }
        VersionsPath = $versionsPath
        HasVersions  = $hasVersions
    }
}

function Get-InstalledVersions {
    param([string]$RootPath)
    $versionsPath = Join-Path $RootPath $script:VersionsDir
    if (-not (Test-Path -LiteralPath $versionsPath)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $versionsPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'nginx.exe') } |
        Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name
    )
}

function Get-ActiveVersion {
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    if (-not $StateInfo.IsSymlink) { return $null }
    # Primary source of truth: our own config. Reliable on Windows PowerShell 5.1, where the
    # symlink target cannot be read from the FileInfo object.
    if ($Config -and $Config.ContainsKey('ActiveVersion') -and $Config.ActiveVersion) {
        $staged = Join-Path (Join-Path $Config.Root $script:VersionsDir) $Config.ActiveVersion
        if (Test-Path -LiteralPath (Join-Path $staged 'nginx.exe')) { return $Config.ActiveVersion }
    }
    # Fallback: parse the resolved link target (PS7 native, or fsutil on 5.1).
    if ($StateInfo.LinkTarget) {
        try {
            $v = Split-Path -Leaf (Split-Path -Parent $StateInfo.LinkTarget)
            if ($v -match '^[0-9]+\.[0-9]+\.[0-9]+') { return $v }
        } catch {}
    }
    # Last resort: a single staged version must be the active one.
    $installed = Get-InstalledVersions $Config.Root
    if ($installed.Count -eq 1) { return $installed[0] }
    return $null
}

function Get-ExeVersionString {
    <# Runs "<exe> -v" and parses "nginx version: nginx/1.28.0". Returns the version or $null. #>
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $out = & $ExePath -v 2>&1 | Out-String
        if ($out -match 'nginx/([0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
    } catch {}
    return $null
}
#endregion

# ----------------------------------------------------------------------------------------------
#region Version discovery / download
# ----------------------------------------------------------------------------------------------
function Get-AvailableVersions {
    <#
        Parses nginx.org/en/download.html and returns @{ Stable = '1.30.4'; Mainline = '1.31.3' }.
        Rule: stable = highest version with an EVEN minor; mainline = highest with an ODD minor.
    #>
    Write-Info "Querying $script:DownloadPage ..."
    try {
        $resp = Invoke-WebRequest -Uri $script:DownloadPage -UseBasicParsing -TimeoutSec 30
        $html = $resp.Content
    } catch {
        throw "Could not fetch the nginx download page: $($_.Exception.Message)"
    }

    $matches = [regex]::Matches($html, 'nginx-([0-9]+)\.([0-9]+)\.([0-9]+)\.zip')
    if ($matches.Count -eq 0) { throw "No nginx Windows builds found on the download page (page format may have changed)." }

    $versions = @{}
    foreach ($m in $matches) {
        $v = [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
        $versions[$v.ToString()] = $v
    }
    $all = $versions.Values | Sort-Object

    $stable   = ($all | Where-Object { ($_.Minor % 2) -eq 0 } | Select-Object -Last 1)
    $mainline = ($all | Where-Object { ($_.Minor % 2) -eq 1 } | Select-Object -Last 1)

    return [pscustomobject]@{
        Stable   = if ($stable)   { $stable.ToString() }   else { $null }
        Mainline = if ($mainline) { $mainline.ToString() } else { $null }
        All      = ($all | ForEach-Object { $_.ToString() })
    }
}

function Resolve-TargetVersion {
    <# Decides which version to install based on channel; returns a version string. #>
    param([string]$ChannelPref)
    $avail = Get-AvailableVersions
    Write-Host ""
    Write-Host ("  Stable   : {0}" -f (Coalesce $avail.Stable   'n/a')) -ForegroundColor Green
    Write-Host ("  Mainline : {0}" -f (Coalesce $avail.Mainline 'n/a')) -ForegroundColor Green

    $pick = $ChannelPref
    if ($pick -eq 'ask' -or [string]::IsNullOrEmpty($pick)) {
        Write-Host ""
        Write-Host "  1) Stable   ($($avail.Stable))"
        Write-Host "  2) Mainline ($($avail.Mainline))"
        Write-Host "  3) Enter a specific version"
        $c = Read-Menu "Channel"
        switch ($c) {
            '1' { return $avail.Stable }
            '2' { return $avail.Mainline }
            '3' {
                $v = (Read-Host "Version (e.g. 1.30.4)").Trim()
                if ($v -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Invalid version format: '$v'." }
                return $v
            }
            default { throw "Cancelled." }
        }
    }
    if ($pick -eq 'stable')   { return $avail.Stable }
    if ($pick -eq 'mainline') { return $avail.Mainline }
    throw "Unknown channel '$ChannelPref'."
}

function Get-NginxZip {
    <# Downloads nginx-<ver>.zip to a temp path and returns the file path. Verifies PGP if gpg present. #>
    param([string]$Version)
    $url = "$script:DownloadBase/nginx-$Version.zip"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("nginx-$Version-{0}.zip" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    Write-Info "Downloading $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
    } catch {
        throw "Download failed for $url : $($_.Exception.Message)"
    }
    $size = (Get-Item -LiteralPath $tmp).Length
    if ($size -lt 100KB) { throw "Downloaded file is suspiciously small ($size bytes)." }
    Write-Good ("Downloaded {0:N1} MB." -f ($size / 1MB))

    # Best-effort PGP signature verification (nginx publishes nginx-<ver>.zip.asc).
    $gpg = Get-Command gpg -ErrorAction SilentlyContinue
    if ($gpg) {
        try {
            $asc = "$tmp.asc"
            Invoke-WebRequest -Uri "$url.asc" -OutFile $asc -UseBasicParsing -TimeoutSec 30
            $verify = & $gpg.Path --verify $asc $tmp 2>&1 | Out-String
            if ($verify -match 'Good signature') {
                Write-Good "PGP signature verified."
            } else {
                Write-Warn "PGP signature NOT verified (import the nginx signing key to enable this). Continuing."
            }
            Remove-Item -LiteralPath $asc -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Could not verify PGP signature ($($_.Exception.Message)). Continuing over HTTPS."
        }
    } else {
        Write-Warn "gpg not found — skipping signature verification (download was over HTTPS)."
    }
    return $tmp
}

function Install-VersionFiles {
    <#
        Extracts the zip and lays the distribution down at <root>\versions\<ver>\ (nginx.exe at its top).
        Does NOT touch the root conf/ or html/. Returns the version folder path.
    #>
    param([string]$RootPath, [string]$Version, [string]$ZipPath)

    $versionsRoot = Join-Path $RootPath $script:VersionsDir
    $target = Join-Path $versionsRoot $Version
    if (Test-Path -LiteralPath (Join-Path $target 'nginx.exe')) {
        Write-Warn "Version $Version already present at $target — reusing it."
        return $target
    }

    New-Item -ItemType Directory -Path $versionsRoot -Force | Out-Null
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("nginx-extract-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $staging -Force
        # Zip contains a single top folder "nginx-<ver>".
        $top = Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1
        if (-not $top) { throw "Unexpected archive layout — no top-level folder found." }
        if (-not (Test-Path -LiteralPath (Join-Path $top.FullName 'nginx.exe'))) {
            throw "Archive does not contain nginx.exe."
        }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        # Copy the full distribution for this version (binary + its default conf/html/docs for reference).
        Copy-Item -Path (Join-Path $top.FullName '*') -Destination $target -Recurse -Force
        Write-Good "Staged nginx $Version -> $target"
        return $target
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
#endregion

# ----------------------------------------------------------------------------------------------
#region Symlink management
# ----------------------------------------------------------------------------------------------
function Set-ActiveVersionLink {
    <#
        Points <root>\nginx.exe at <root>\versions\<ver>\nginx.exe.
        Recreating the link is safe while nginx is running (the link object is not the locked file).
    #>
    param([string]$RootPath, [string]$Version)

    $link = Get-NginxExePath $RootPath
    $targetExe = Join-Path (Join-Path (Join-Path $RootPath $script:VersionsDir) $Version) 'nginx.exe'
    if (-not (Test-Path -LiteralPath $targetExe)) { throw "Target binary not found: $targetExe" }

    if (Test-Path -LiteralPath $link) {
        if (Test-IsSymlink $link) {
            Remove-Item -LiteralPath $link -Force
        } else {
            throw "$link exists and is NOT a symlink. Refusing to overwrite a real file — migrate first."
        }
    }
    # Prefer New-Item (works on PS7 and modern 5.1); fall back to cmd mklink, which is available
    # on every Windows version and PowerShell edition. Both need admin or Developer Mode.
    $made = $false
    try {
        New-Item -ItemType SymbolicLink -Path $link -Target $targetExe -ErrorAction Stop | Out-Null
        $made = $true
    } catch {
        Write-Warn "New-Item symlink failed ($($_.Exception.Message)); trying mklink."
    }
    if (-not $made) {
        if (-not $script:OnWindows) { throw "Cannot create a symlink off-Windows." }
        $out = & cmd.exe /c "mklink `"$link`" `"$targetExe`"" 2>&1 | Out-String
        if (-not (Test-Path -LiteralPath $link)) { throw "mklink failed: $($out.Trim())" }
    }
    Write-Good "Active nginx.exe -> versions\$Version\nginx.exe"
}
#endregion

# ----------------------------------------------------------------------------------------------
#region Service (NSSM / Windows service) management
# ----------------------------------------------------------------------------------------------
function Find-NssmPath {
    param([string]$Hint)
    if ($Hint -and (Test-Path -LiteralPath $Hint)) { return (Resolve-Path -LiteralPath $Hint).Path }
    $cmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    foreach ($p in @(
            "$env:ProgramFiles\nssm\win64\nssm.exe",
            "$env:ProgramFiles\nssm\nssm.exe",
            "${env:ProgramFiles(x86)}\nssm\win32\nssm.exe",
            "C:\nssm\nssm.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Find-ServiceForRoot {
    <# Finds a Windows service whose binary path points into $RootPath. Returns service name or $null. #>
    param([string]$RootPath)
    if (-not $script:OnWindows) { return $null }
    try {
        $rootNorm = (Resolve-Path -LiteralPath $RootPath).Path.TrimEnd('\')
        $svc = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            Where-Object { $_.PathName -and ($_.PathName -replace '"', '') -like "*$rootNorm*" -and $_.PathName -match 'nginx' } |
            Select-Object -First 1
        if ($svc) { return $svc.Name }
    } catch {}
    return $null
}

function Get-ServiceStatus {
    param([string]$Name)
    if (-not $Name) { return 'None' }
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        return $svc.Status.ToString()   # Running / Stopped / etc.
    } catch { return 'NotFound' }
}

function Restart-NginxService {
    param([string]$Name)
    if (-not $Name) { throw "No service name configured." }
    Write-Info "Restarting service '$Name' ..."
    Restart-Service -Name $Name -Force -ErrorAction Stop
    Start-Sleep -Seconds 1
    $status = Get-ServiceStatus $Name
    if ($status -eq 'Running') { Write-Good "Service '$Name' is Running." }
    else { Write-Warn "Service '$Name' status after restart: $status" }
}

function New-NginxNssmService {
    <# Creates an NSSM-wrapped nginx service. Requires nssm.exe. #>
    param([string]$RootPath, [string]$Name, [string]$NssmExe)
    if (-not $NssmExe) { throw "nssm.exe not found — set it via the Configure menu to create a service." }
    $exe = Get-NginxExePath $RootPath
    Write-Info "Creating NSSM service '$Name' ..."
    & $NssmExe install $Name $exe '-p' $RootPath | Write-Host
    & $NssmExe set $Name AppDirectory $RootPath | Write-Host
    & $NssmExe set $Name AppStdout (Join-Path $RootPath 'logs\service-stdout.log') | Write-Host
    & $NssmExe set $Name AppStderr (Join-Path $RootPath 'logs\service-stderr.log') | Write-Host
    & $NssmExe set $Name Start SERVICE_AUTO_START | Write-Host
    & $NssmExe set $Name AppStopMethodConsole 5000 | Write-Host
    Write-Good "Service '$Name' created. Start it from the menu when ready."
}
#endregion

# ----------------------------------------------------------------------------------------------
#region Validation
# ----------------------------------------------------------------------------------------------
function Test-NginxConfig {
    <# Runs "<versionExe> -t -p <root>" to validate the live config against a given binary. #>
    param([string]$RootPath, [string]$Version)
    $exe = Join-Path (Join-Path (Join-Path $RootPath $script:VersionsDir) $Version) 'nginx.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Write-Warn "Binary for $Version not found; skipping config test."; return $true }
    Write-Info "Testing config with nginx $Version ..."
    $out = & $exe -t -p $RootPath 2>&1 | Out-String
    Write-Host $out.Trim()
    if ($out -match 'test is successful') { Write-Good "Config OK with $Version."; return $true }
    Write-Warn "Config test did not report success — review the output above."
    return $false
}
#endregion

# ----------------------------------------------------------------------------------------------
#region High-level operations
# ----------------------------------------------------------------------------------------------
function Invoke-Scaffold {
    <# Empty folder -> full managed install. Creates root, versions, conf/html from the download. #>
    param([hashtable]$Config)
    if (-not (Assert-Admin 'scaffolding a managed install')) { return }

    $root = $Config.Root
    Write-Head "Scaffold managed install at: $root"
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    $version = Resolve-TargetVersion $Config.Channel
    if (-not $version) { Write-Err "No version resolved."; return }
    $zip = Get-NginxZip $version
    try {
        $verDir = Install-VersionFiles $root $version $zip

        # Seed root conf/ and html/ from this version's defaults (only if absent).
        foreach ($sub in 'conf', 'html', 'logs', 'temp') {
            $dst = Join-Path $root $sub
            if (-not (Test-Path -LiteralPath $dst)) {
                $src = Join-Path $verDir $sub
                if (Test-Path -LiteralPath $src) {
                    Copy-Item -Path $src -Destination $dst -Recurse -Force
                } else {
                    New-Item -ItemType Directory -Path $dst -Force | Out-Null
                }
                Write-Good "Created $sub\"
            }
        }
        Set-ActiveVersionLink $root $version
        $Config.ActiveVersion = $version
        Test-NginxConfig $root $version | Out-Null

        # Offer to create the service.
        if (-not $Config.ServiceName) { $Config.ServiceName = 'nginx' }
        if (Confirm-YesNo "Create NSSM service '$($Config.ServiceName)' for this install?" $true) {
            $nssm = Find-NssmPath $Config.NssmPath
            if (-not $nssm) {
                Write-Warn "nssm.exe not found. Set its path via Configure, then re-run this step."
            } else {
                $Config.NssmPath = $nssm
                New-NginxNssmService $root $Config.ServiceName $nssm
            }
        }
        Save-Config $Config
        Write-Good "`nScaffold complete. nginx $version is active."
    } finally {
        Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
    }
}

function Invoke-Migrate {
    <# Manual install -> managed. Moves the existing nginx.exe into versions\<ver>\ and links it. #>
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    if (-not (Assert-Admin 'migrating to a managed install')) { return }

    $root = $Config.Root
    Write-Head "Migrate manual install -> managed: $root"

    $exe = $StateInfo.ExePath
    $detected = Get-ExeVersionString $exe
    if (-not $detected) {
        $detected = (Read-Host "Could not auto-detect the installed version. Enter it (e.g. 1.28.0)").Trim()
        if ($detected -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Write-Err "Invalid version."; return }
    }
    Write-Info "Detected installed version: $detected"

    $verDir = Join-Path (Join-Path $root $script:VersionsDir) $detected
    $stagedExe = Join-Path $verDir 'nginx.exe'
    if (Test-Path -LiteralPath $stagedExe) {
        # Already staged from a prior run. Free the root path so we can drop the symlink there.
        Write-Warn "versions\$detected already exists; relinking to it."
        if ((Test-Path -LiteralPath $exe) -and -not (Test-IsSymlink $exe)) {
            $aside = "$exe.pre-migrate-$detected"
            Write-Info "Setting existing root nginx.exe aside -> $(Split-Path -Leaf $aside)"
            Move-Item -LiteralPath $exe -Destination $aside -Force   # rename works even while running
        }
    } else {
        New-Item -ItemType Directory -Path $verDir -Force | Out-Null
        # Move the running binary (rename works even while locked, same volume). conf/html/logs stay put.
        Write-Info "Moving current nginx.exe -> versions\$detected\nginx.exe"
        Move-Item -LiteralPath $exe -Destination $stagedExe -Force
    }

    Set-ActiveVersionLink $root $detected
    $Config.ActiveVersion = $detected
    Test-NginxConfig $root $detected | Out-Null

    # Adopt or create the service.
    if (-not $Config.ServiceName) {
        $found = Find-ServiceForRoot $root
        if ($found) { $Config.ServiceName = $found; Write-Good "Adopted existing service '$found'." }
        else { $Config.ServiceName = 'nginx' }
    }
    Save-Config $Config
    Write-Good "`nMigration complete. Config and html were left untouched."
    Write-Info "The running nginx is still on the old binary handle; it now matches the managed layout."
    Write-Info "Future upgrades will repoint the symlink and activate on restart."
}

function Invoke-Update {
    <# Managed install -> download & stage a version, repoint link, prompt restart. #>
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    if (-not (Assert-Admin 'updating the managed install')) { return }

    $root = $Config.Root
    Write-Head "Update / install a version: $root"
    $active = Get-ActiveVersion $Config $StateInfo
    if ($active) { Write-Info "Currently active: $active" }

    $version = Resolve-TargetVersion $Config.Channel
    if (-not $version) { Write-Err "No version resolved."; return }
    if ($version -eq $active) {
        if (-not (Confirm-YesNo "Version $version is already active. Re-stage it anyway?" $false)) { return }
    }

    $installed = Get-InstalledVersions $root
    if ($installed -contains $version) {
        Write-Info "Version $version is already staged under versions\."
    } else {
        $zip = Get-NginxZip $version
        try { Install-VersionFiles $root $version $zip | Out-Null }
        finally { Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue }
    }

    # Validate the live config against the NEW binary before switching.
    if (-not (Test-NginxConfig $root $version)) {
        if (-not (Confirm-YesNo "Config test was not clean. Repoint the symlink anyway?" $false)) {
            Write-Warn "Aborted; symlink unchanged. Staged binary remains under versions\$version."
            return
        }
    }

    Set-ActiveVersionLink $root $version
    $Config.ActiveVersion = $version
    Save-Config $Config
    Write-Good "`nStaged and linked nginx $version. The running process is still on $active."
    Prompt-Restart $Config
}

function Invoke-SwitchVersion {
    <# Roll back / forward to any already-staged version. #>
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    if (-not (Assert-Admin 'switching the active version')) { return }
    $root = $Config.Root
    $versions = Get-InstalledVersions $root
    if ($versions.Count -eq 0) { Write-Warn "No staged versions found under versions\."; return }
    $active = Get-ActiveVersion $Config $StateInfo

    Write-Head "Switch active version"
    for ($i = 0; $i -lt $versions.Count; $i++) {
        $mark = if ($versions[$i] -eq $active) { '  (active)' } else { '' }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), $versions[$i], $mark)
    }
    $sel = Read-Menu "Choose a version (or blank to cancel)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $versions.Count) { Write-Warn "Invalid selection."; return }
    $chosen = $versions[[int]$sel - 1]
    if ($chosen -eq $active) { Write-Info "Already active."; return }

    Test-NginxConfig $root $chosen | Out-Null
    Set-ActiveVersionLink $root $chosen
    $Config.ActiveVersion = $chosen
    Save-Config $Config
    Write-Good "Switched active binary to $chosen (running process unchanged until restart)."
    Prompt-Restart $Config
}

function Prompt-Restart {
    <# The key UX: restart now to activate, or wait for the next natural restart. #>
    param([hashtable]$Config)
    $svc = $Config.ServiceName
    $status = Get-ServiceStatus $svc
    Write-Host ""
    Write-Info "The new binary is linked but will only run after nginx restarts."
    Write-Host "  Service : $svc  (status: $status)"
    Write-Host ""
    Write-Host "  1) Restart nginx now (brief blip; activates the new binary immediately)"
    Write-Host "  2) Wait for the next natural restart (activates then; zero action now)"
    Write-Host "  3) Reload config only (nginx -s reload — does NOT swap the binary)"
    $c = Read-Menu "Choice"
    switch ($c) {
        '1' {
            try { Restart-NginxService $svc; Write-Good "New binary is now live." }
            catch { Write-Err "Restart failed: $($_.Exception.Message)" }
        }
        '2' { Write-Info "OK — the new binary will activate on the next service restart / reboot." }
        '3' { Invoke-ReloadConfig $Config }
        default { Write-Info "No action taken; new binary activates on next restart." }
    }
}

function Invoke-ReloadConfig {
    param([hashtable]$Config)
    $exe = Get-NginxExePath $Config.Root
    if (-not (Test-Path -LiteralPath $exe)) { Write-Warn "No active nginx.exe."; return }
    Write-Info "Reloading config (nginx -s reload)..."
    try { & $exe -s reload -p $Config.Root 2>&1 | Out-String | Write-Host; Write-Good "Reload signal sent." }
    catch { Write-Err "Reload failed: $($_.Exception.Message)" }
}
#endregion

# ----------------------------------------------------------------------------------------------
#region Status / diagnostics
# ----------------------------------------------------------------------------------------------
function Show-Status {
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    Write-Head "Status: $($Config.Root)"
    Write-Host ("  State          : {0}" -f $StateInfo.State)
    if ($StateInfo.ExeExists) {
        Write-Host ("  nginx.exe      : {0}" -f $StateInfo.ExePath)
        Write-Host ("  Is symlink     : {0}" -f $StateInfo.IsSymlink)
        if ($StateInfo.IsSymlink) { Write-Host ("  -> target      : {0}" -f (Coalesce $StateInfo.LinkTarget '(unresolved on PS5.1)')) }
        $active = Get-ActiveVersion $Config $StateInfo
        if ($active) { Write-Host ("  Active version : {0}" -f $active) }
        $running = Get-ExeVersionString $StateInfo.ExePath
        if ($running) { Write-Host ("  Binary reports : {0}" -f $running) }
    }
    $installed = Get-InstalledVersions $Config.Root
    Write-Host ("  Staged versions: {0}" -f (($installed -join ', ') -replace '^$', '(none)'))
    Write-Host ("  Service        : {0}  (status: {1})" -f (Coalesce $Config.ServiceName '(none)'), (Get-ServiceStatus $Config.ServiceName))
    $nssm = Find-NssmPath $Config.NssmPath
    Write-Host ("  nssm.exe       : {0}" -f (Coalesce $nssm '(not found)'))
    Write-Host ("  Channel default: {0}" -f $Config.Channel)
    Write-Host ("  Admin          : {0}" -f (Test-Admin))
}

function Invoke-Configure {
    param([hashtable]$Config)
    Write-Head "Configure"
    Write-Host "Leave blank to keep the current value shown in [brackets]."
    $r = (Read-Host "nginx root [$($Config.Root)]").Trim();        if ($r) { $Config.Root = $r }
    $s = (Read-Host "Service name [$($Config.ServiceName)]").Trim(); if ($s) { $Config.ServiceName = $s }
    $n = (Read-Host "nssm.exe path [$($Config.NssmPath)]").Trim();   if ($n) { $Config.NssmPath = $n }
    $c = (Read-Host "Default channel stable/mainline/ask [$($Config.Channel)]").Trim().ToLowerInvariant()
    if ($c -in 'stable', 'mainline', 'ask') { $Config.Channel = $c } elseif ($c) { Write-Warn "Ignored invalid channel '$c'." }
    Save-Config $Config
    Write-Good "Saved."
}
#endregion

# ----------------------------------------------------------------------------------------------
#region Main menu loop
# ----------------------------------------------------------------------------------------------
function Get-RootInteractively {
    param([string]$Provided)
    if ($Provided) { return $Provided }
    Write-Host ""
    Write-Info "No -Root supplied. Enter the nginx root folder to manage."
    Write-Host "  Examples: C:\nginx   D:\services\nginx"
    $r = (Read-Host "nginx root").Trim().Trim('"')
    if (-not $r) { throw "A root folder is required." }
    return $r
}

function Show-Menu {
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    $active = if ($StateInfo.IsSymlink) { Get-ActiveVersion $Config $StateInfo } else { $null }
    $svcStatus = Get-ServiceStatus $Config.ServiceName

    Write-Host ""
    Write-Host ('-' * 70) -ForegroundColor DarkGray
    Write-Host (" nginx updater  |  root: {0}" -f $Config.Root) -ForegroundColor White
    Write-Host (" state: {0}   active: {1}   service: {2} [{3}]" -f `
            $StateInfo.State, (Coalesce $active '-'), (Coalesce $Config.ServiceName '-'), $svcStatus) -ForegroundColor Gray
    Write-Host ('-' * 70) -ForegroundColor DarkGray

    $items = [ordered]@{}
    switch ($StateInfo.State) {
        'Empty'   { $items['1'] = @{ Text = 'Scaffold a new managed install here'; Action = 'scaffold' } }
        'Manual'  { $items['1'] = @{ Text = 'Migrate this manual install -> managed'; Action = 'migrate' } }
        'Managed' {
            $items['1'] = @{ Text = 'Check for updates / install a version'; Action = 'update' }
            $items['2'] = @{ Text = 'Switch active version (rollback/forward)'; Action = 'switch' }
            $items['3'] = @{ Text = 'Restart nginx now'; Action = 'restart' }
            $items['4'] = @{ Text = 'Reload config (nginx -s reload)'; Action = 'reload' }
        }
        default   { $items['1'] = @{ Text = 'Scaffold a new managed install here'; Action = 'scaffold' } }
    }
    $items['s'] = @{ Text = 'Show status / diagnostics'; Action = 'status' }
    $items['c'] = @{ Text = 'Configure (root, service, nssm, channel)'; Action = 'configure' }
    $items['r'] = @{ Text = 'Change managed root folder'; Action = 'changeroot' }
    $items['q'] = @{ Text = 'Quit'; Action = 'quit' }

    foreach ($k in $items.Keys) { Write-Host ("  {0}) {1}" -f $k, $items[$k].Text) }
    $sel = (Read-Menu "Select").ToLowerInvariant()
    if ($items.Contains($sel)) { return $items[$sel].Action }
    Write-Warn "Unknown option."
    return 'noop'
}

function Main {
    if (-not $script:OnWindows) {
        Write-Warn "This tool targets Windows. On $([System.Environment]::OSVersion.Platform) it runs read-only for inspection; symlink/service actions are disabled."
    }

    $rootPath = Get-RootInteractively $Root
    $Config = Load-Config $rootPath
    # Attempt service auto-detect once if not set.
    if (-not $Config.ServiceName) {
        $found = Find-ServiceForRoot $rootPath
        if ($found) { $Config.ServiceName = $found }
    }

    if ($Status) {
        $st = Get-RootState $Config.Root
        Show-Status $Config $st
        return
    }

    while ($true) {
        $st = Get-RootState $Config.Root
        $action = Show-Menu $Config $st
        try {
            switch ($action) {
                'scaffold'   { Invoke-Scaffold $Config }
                'migrate'    { Invoke-Migrate $Config $st }
                'update'     { Invoke-Update $Config $st }
                'switch'     { Invoke-SwitchVersion $Config $st }
                'restart'    { Restart-NginxService $Config.ServiceName }
                'reload'     { Invoke-ReloadConfig $Config }
                'status'     { Show-Status $Config $st }
                'configure'  { Invoke-Configure $Config }
                'changeroot' {
                    $new = (Read-Host "New nginx root").Trim().Trim('"')
                    if ($new) { $Config = Load-Config $new; if (-not $Config.ServiceName) { $f = Find-ServiceForRoot $new; if ($f) { $Config.ServiceName = $f } } }
                }
                'quit'       { Write-Info "Bye."; return }
                'noop'       { }
                default      { }
            }
        } catch {
            Write-Err "Error: $($_.Exception.Message)"
        }
    }
}
#endregion

Main
