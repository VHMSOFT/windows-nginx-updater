function Get-ToolDir {
    <#
    .SYNOPSIS
        Returns the tool's own folder (where the launcher and NginxUpdater\ live).
    #>
    $inv = $script:Invocation
    if ($inv.ContainsKey('LauncherPath') -and $inv['LauncherPath']) {
        return (Split-Path -Parent $inv['LauncherPath'])
    }
    return (Split-Path -Parent $script:ModuleRoot)
}

function Get-ToolVersion {
    <#
    .SYNOPSIS
        Returns the installed tool version (ModuleVersion from the manifest), or 0.0.0 on failure.
    #>
    try {
        $manifest = Join-Path $script:ModuleRoot 'NginxUpdater.psd1'
        $data = Import-PowerShellDataFile -LiteralPath $manifest
        return [version]$data.ModuleVersion
    } catch {
        Write-Verbose 'Could not read ModuleVersion from the manifest.'
        return [version]'0.0.0'
    }
}

function Get-SelfUpdateStatePath {
    <#
    .SYNOPSIS
        Returns the path to this install's self-update state file (in the tool folder).
    #>
    param([string]$ToolDir)
    return (Join-Path $ToolDir '.nginx-updater-selfupdate.json')
}

function Import-SelfUpdateState {
    <#
    .SYNOPSIS
        Loads this install's self-update state (per-mirror health + staged update) as a hashtable.
    #>
    param([string]$ToolDir)
    $state = @{ Mirrors = @{}; StagedVersion = $null; StagedPath = $null }
    $path = Get-SelfUpdateStatePath $ToolDir
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($saved.PSObject.Properties.Name -contains 'Mirrors' -and $saved.Mirrors) {
                foreach ($p in $saved.Mirrors.PSObject.Properties) { $state.Mirrors[$p.Name] = [string]$p.Value }
            }
            foreach ($k in 'StagedVersion', 'StagedPath') {
                if ($saved.PSObject.Properties.Name -contains $k) { $state[$k] = $saved.$k }
            }
        } catch {
            Write-Verbose 'Could not read self-update state; using defaults.'
        }
    }
    return $state
}

function Save-SelfUpdateState {
    <#
    .SYNOPSIS
        Persists this install's self-update state to the tool folder.
    #>
    param([string]$ToolDir, [hashtable]$State)
    $path = Get-SelfUpdateStatePath $ToolDir
    try {
        [pscustomobject]@{
            Mirrors       = $State.Mirrors
            StagedVersion = $State.StagedVersion
            StagedPath    = $State.StagedPath
            UpdatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {
        Write-Verbose 'Could not save self-update state.'
    }
}

function Get-OrderedMirror {
    <#
    .SYNOPSIS
        Orders the configured mirrors by recorded health: last-ok, then unknown, then last-failed.
    .DESCRIPTION
        A previously-failed mirror is kept only as a last resort, so a transient failure cannot
        permanently disable updates while still honouring "prefer the mirror that worked".
    #>
    param([hashtable]$State)
    $good = @(); $unknown = @(); $bad = @()
    foreach ($m in $script:Mirrors) {
        $health = if ($State.Mirrors.ContainsKey($m.Name)) { $State.Mirrors[$m.Name] } else { $null }
        if ($health -eq 'ok') { $good += $m }
        elseif ($health -eq 'fail') { $bad += $m }
        else { $unknown += $m }
    }
    return @($good + $unknown + $bad)
}

function Get-LatestRelease {
    <#
    .SYNOPSIS
        Queries one mirror's releases/latest endpoint and returns version + .zip asset URL.
    #>
    param([pscustomobject]$Mirror)
    $headers = @{ 'User-Agent' = 'windows-nginx-updater'; 'Accept' = 'application/json' }
    $resp = Invoke-RestMethod -Uri $Mirror.ReleaseApi -Headers $headers -TimeoutSec 15
    if (-not $resp -or -not $resp.tag_name) { throw 'no release found' }
    $verStr = ([string]$resp.tag_name) -replace '^v', ''
    if ($verStr -notmatch '^[0-9]+\.[0-9]+\.[0-9]+') { throw "unexpected tag '$($resp.tag_name)'" }
    $asset = $null
    if ($resp.PSObject.Properties.Name -contains 'assets' -and $resp.assets) {
        $asset = @($resp.assets | Where-Object { $_.name -match '\.zip$' })[0]
    }
    if (-not $asset -or -not $asset.browser_download_url) { throw 'release has no .zip asset' }
    return [pscustomobject]@{
        Mirror  = $Mirror.Name
        Version = [version]($verStr -replace '(\+.*|-.*)$', '')
        ZipUrl  = [string]$asset.browser_download_url
        ZipName = [string]$asset.name
    }
}

function Test-ForUpdate {
    <#
    .SYNOPSIS
        Finds the latest release across mirrors (health-ordered) and whether it is newer than local.
    .DESCRIPTION
        Updates and saves per-mirror health. Returns $null if every mirror failed.
    #>
    param([string]$ToolDir, [hashtable]$State)
    $local = Get-ToolVersion
    $release = $null
    foreach ($m in (Get-OrderedMirror -State $State)) {
        try {
            $release = Get-LatestRelease -Mirror $m
            $State.Mirrors[$m.Name] = 'ok'
            break
        } catch {
            $State.Mirrors[$m.Name] = 'fail'
            Write-Verbose ('Mirror {0} failed: {1}' -f $m.Name, $_.Exception.Message)
        }
    }
    Save-SelfUpdateState -ToolDir $ToolDir -State $State
    if (-not $release) { return $null }
    return [pscustomobject]@{
        Local   = $local
        Release = $release
        IsNewer = ($release.Version -gt $local)
    }
}

function Save-UpdatePackage {
    <#
    .SYNOPSIS
        Downloads and extracts a release zip into the tool's .update\staged-<ver>\ folder.
    .DESCRIPTION
        Locates the folder inside the archive that holds Update-Nginx.ps1 + NginxUpdater\ (works
        whether the zip has a top folder or not) and returns the staged folder path.
    #>
    param([string]$ToolDir, [pscustomobject]$Release)
    $updRoot = Join-Path $ToolDir '.update'
    $download = Join-Path $updRoot 'download'
    $extract = Join-Path $updRoot 'extract'
    $staged = Join-Path $updRoot ('staged-' + $Release.Version.ToString())
    foreach ($d in $extract, $staged) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    foreach ($d in $download, $extract, $staged) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

    $zip = Join-Path $download $Release.ZipName
    Invoke-WebRequest -Uri $Release.ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

    $launcherHit = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'Update-Nginx.ps1' -File |
        Select-Object -First 1
    if (-not $launcherHit) { throw 'package does not contain Update-Nginx.ps1' }
    $srcDir = Split-Path -Parent $launcherHit.FullName
    if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'NginxUpdater'))) {
        throw 'package does not contain the NginxUpdater module'
    }
    Get-ChildItem -LiteralPath $srcDir -Force | Copy-Item -Destination $staged -Recurse -Force
    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    return $staged
}

function Invoke-SelfUpdateCheck {
    <#
    .SYNOPSIS
        Startup check: find a newer release, download/stage it, and flag it for the menu banner.
    .DESCRIPTION
        Best-effort - any failure warns and returns so the tool keeps working offline or when the
        repo is unreachable. Sets $script:PendingUpdate when an update is staged and ready to apply.
    #>
    $script:PendingUpdate = $null
    $toolDir = Get-ToolDir
    if (-not $toolDir -or -not (Test-Path -LiteralPath $toolDir)) { return }

    Write-Info 'Checking for tool updates...'
    $state = Import-SelfUpdateState -ToolDir $toolDir
    $check = $null
    try {
        $check = Test-ForUpdate -ToolDir $toolDir -State $state
    } catch {
        Write-Warn "Update check failed ($($_.Exception.Message)). Continuing."
        return
    }
    if (-not $check) {
        Write-Warn 'Update check failed on all mirrors. Continuing.'
        return
    }
    if (-not $check.IsNewer) {
        Write-Verbose ('Up to date (v{0}).' -f $check.Local)
        return
    }

    $rel = $check.Release
    Write-Info ('Update available: v{0} (installed v{1}) from the {2} mirror.' -f `
            $rel.Version, $check.Local, $rel.Mirror)

    $state = Import-SelfUpdateState -ToolDir $toolDir
    $alreadyStaged = ($state.StagedVersion -eq $rel.Version.ToString()) -and
    $state.StagedPath -and (Test-Path -LiteralPath $state.StagedPath)
    if ($alreadyStaged) {
        $staged = $state.StagedPath
    } else {
        try {
            Write-Info 'Downloading update...'
            $staged = Save-UpdatePackage -ToolDir $toolDir -Release $rel
            $state.StagedVersion = $rel.Version.ToString()
            $state.StagedPath = $staged
            Save-SelfUpdateState -ToolDir $toolDir -State $state
            Write-Good 'Update downloaded and staged.'
        } catch {
            Write-Warn "Could not download the update ($($_.Exception.Message)). Continuing."
            return
        }
    }
    $script:PendingUpdate = [pscustomobject]@{
        Version   = $rel.Version.ToString()
        Mirror    = $rel.Mirror
        StagedDir = $staged
        ToolDir   = $toolDir
    }
}

function Invoke-SelfUpdateApply {
    <#
    .SYNOPSIS
        Applies the staged update over the tool folder and relaunches the tool.
    .DESCRIPTION
        Backs up the current tool files, copies the staged files in, clears the staged marker, then
        starts a fresh launcher process. Returns $true when the caller should exit so the new
        process takes over.
    #>
    $pending = $script:PendingUpdate
    if (-not $pending) { Write-Warn 'No pending update.'; return $false }
    if (-not (Test-Path -LiteralPath $pending.StagedDir)) {
        Write-Warn 'Staged update is missing; re-run the tool to download it again.'
        return $false
    }
    $toolDir = $pending.ToolDir
    Write-Head ('Apply update to v{0}' -f $pending.Version)
    if (-not (Confirm-YesNo 'Copy the new files over the tool and relaunch it now?' $true)) {
        return $false
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path (Join-Path $toolDir '.update') "backup-$stamp"
    try {
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        foreach ($name in 'Update-Nginx.ps1', 'NginxUpdater', 'runAsAdmin.cmd') {
            $cur = Join-Path $toolDir $name
            if (Test-Path -LiteralPath $cur) { Copy-Item -LiteralPath $cur -Destination $backup -Recurse -Force }
        }
    } catch {
        Write-Verbose 'Could not back up current tool files before update.'
    }

    try {
        Get-ChildItem -LiteralPath $pending.StagedDir -Force | ForEach-Object {
            $dest = Join-Path $toolDir $_.Name
            if ($_.PSIsContainer) {
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }
    } catch {
        Write-Err "Update failed while copying files: $($_.Exception.Message)"
        Write-Warn "Your previous files are backed up at: $backup"
        return $false
    }

    $state = Import-SelfUpdateState -ToolDir $toolDir
    $state.StagedVersion = $null
    $state.StagedPath = $null
    Save-SelfUpdateState -ToolDir $toolDir -State $state

    Write-Good ('Updated to v{0}. Relaunching the tool...' -f $pending.Version)
    $launcher = Join-Path $toolDir 'Update-Nginx.ps1'
    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher)
    $inv = $script:Invocation
    foreach ($name in 'Root', 'NssmPath', 'ServiceName', 'Channel') {
        $val = if ($inv.ContainsKey($name)) { $inv[$name] } else { $null }
        if ($val) { $argList += @("-$name", $val) }
    }
    try {
        Start-Process -FilePath $exe -ArgumentList $argList | Out-Null
    } catch {
        Write-Err "Relaunch failed: $($_.Exception.Message). Start the tool again manually."
    }
    return $true
}
