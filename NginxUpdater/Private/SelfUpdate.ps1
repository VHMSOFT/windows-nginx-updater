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

function Get-VersionFilePath {
    <#
    .SYNOPSIS
        Path to this install's version marker - the release tag it is currently running.
    #>
    param([string]$ToolDir)
    return (Join-Path $ToolDir 'version.txt')
}

function Get-InstalledToolVersion {
    <#
    .SYNOPSIS
        Reads the installed version from version.txt, or $null when unknown (a first run).
    .DESCRIPTION
        The installed version is tracked locally here rather than read from the manifest, so
        releases never need the version committed to source and both mirrors stay consistent.
    #>
    param([string]$ToolDir)
    $path = Get-VersionFilePath $ToolDir
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = ((Get-Content -LiteralPath $path -Raw) -replace '^\s*v', '').Trim()
        if ($raw -match '^[0-9]+\.[0-9]+') { return [version]($raw -replace '(\+.*|-.*)$', '') }
    } catch {
        Write-Verbose 'Could not read version.txt.'
    }
    return $null
}

function Set-InstalledToolVersion {
    <#
    .SYNOPSIS
        Records the installed version (release tag) to version.txt.
    #>
    param([string]$ToolDir, [string]$Version)
    try {
        Set-Content -LiteralPath (Get-VersionFilePath $ToolDir) -Value $Version -Encoding UTF8
    } catch {
        Write-Verbose 'Could not write version.txt.'
    }
}

function Get-ShippedContentHash {
    <#
    .SYNOPSIS
        Stable SHA-256 over the shipped items in a folder, to tell whether two installs are identical.
    #>
    param([string]$Dir)
    $parts = @()
    foreach ($name in 'Update-Nginx.ps1', 'NginxUpdater', 'runAsAdmin.cmd') {
        $path = Join-Path $Dir $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object FullName)
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($Dir.Length).TrimStart('\', '/')
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $parts += "$rel=$hash"
        }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($parts -join '|'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ( -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha.Dispose()
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

function Get-WebStatusCode {
    <#
    .SYNOPSIS
        Best-effort HTTP status code from a thrown web exception (works on PS 5.1 and 7), or $null.
    .DESCRIPTION
        PS 5.1 throws a WebException whose Response is an HttpWebResponse; PS 7 throws an
        HttpResponseException with a Response.StatusCode. Both expose Response.StatusCode as an enum
        that casts to the numeric code. Returns $null when there is no HTTP response (DNS, TLS, timeout).
    #>
    param($ErrorRecord)
    try {
        $ex = $ErrorRecord.Exception
        if ($ex -and ($ex.PSObject.Properties.Name -contains 'Response') -and $ex.Response) {
            $status = $ex.Response.StatusCode
            if ($null -ne $status) { return [int]$status }
        }
    } catch {
        Write-Verbose 'Could not read HTTP status from the error.'
    }
    return $null
}

function Get-LatestRelease {
    <#
    .SYNOPSIS
        Queries one mirror's releases/latest endpoint. Returns a status object, never throws.
    .DESCRIPTION
        Distinguishes "reached the mirror but no usable release" (a 404 when the repo has no
        releases yet, or a release lacking a .zip asset) from "could not reach the mirror" (DNS/TLS/
        timeout). Reachable is $true whenever the server answered at the HTTP level. Release holds the
        parsed release when one is usable, otherwise $null with a human-readable Reason.
    #>
    param([pscustomobject]$Mirror)
    $headers = @{ 'User-Agent' = 'windows-nginx-updater'; 'Accept' = 'application/json' }
    $out = [pscustomobject]@{ Mirror = $Mirror.Name; Reachable = $false; Release = $null; Reason = $null }
    try {
        $resp = Invoke-RestMethod -Uri $Mirror.ReleaseApi -Headers $headers -TimeoutSec 15
    } catch {
        $code = Get-WebStatusCode $_
        $out.Reachable = ($null -ne $code)
        $out.Reason = if ($code -eq 404) { 'no release published yet' } else { $_.Exception.Message }
        return $out
    }
    # The server answered - it is reachable regardless of whether a usable release is present.
    $out.Reachable = $true
    if (-not $resp -or -not $resp.tag_name) { $out.Reason = 'no release published yet'; return $out }
    $verStr = ([string]$resp.tag_name) -replace '^v', ''
    if ($verStr -notmatch '^[0-9]+\.[0-9]+\.[0-9]+') {
        $out.Reason = "unexpected tag '$($resp.tag_name)'"; return $out
    }
    $asset = $null
    if ($resp.PSObject.Properties.Name -contains 'assets' -and $resp.assets) {
        $asset = @($resp.assets | Where-Object { $_.name -match '\.zip$' })[0]
    }
    if (-not $asset -or -not $asset.browser_download_url) {
        $out.Reason = 'release has no .zip asset'; return $out
    }
    $out.Release = [pscustomobject]@{
        Mirror  = $Mirror.Name
        Version = [version]($verStr -replace '(\+.*|-.*)$', '')
        ZipUrl  = [string]$asset.browser_download_url
        ZipName = [string]$asset.name
    }
    return $out
}

function Get-LatestReleaseAcrossMirrors {
    <#
    .SYNOPSIS
        Tries each mirror (health-ordered) and reports the outcome. Updates and saves mirror health.
    .DESCRIPTION
        Returns an object with: Release (first usable release found, or $null); Reachable ($true if
        ANY mirror answered at the HTTP level, so "no release yet" is not mistaken for "offline");
        and Failures (per-mirror reasons for diagnosis). A mirror that answers is marked 'ok' even
        when it has no release, since it is healthy; only a true connection failure marks it 'fail'.
    #>
    param([string]$ToolDir, [hashtable]$State)
    $outcome = [pscustomobject]@{ Release = $null; Reachable = $false; Failures = @() }
    foreach ($m in (Get-OrderedMirror -State $State)) {
        $r = Get-LatestRelease -Mirror $m
        if ($r.Reachable) {
            $State.Mirrors[$m.Name] = 'ok'
            $outcome.Reachable = $true
            if ($r.Release) { $outcome.Release = $r.Release; break }
        } else {
            $State.Mirrors[$m.Name] = 'fail'
        }
        $outcome.Failures += [pscustomobject]@{ Mirror = $m.Name; Reason = $r.Reason }
        Write-Verbose ('Mirror {0}: {1}' -f $m.Name, $r.Reason)
    }
    Save-SelfUpdateState -ToolDir $ToolDir -State $State
    return $outcome
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
    $outcome = $null
    try {
        $outcome = Get-LatestReleaseAcrossMirrors -ToolDir $toolDir -State $state
    } catch {
        Write-Warn "Update check failed ($($_.Exception.Message)). Continuing."
        return
    }
    $release = $outcome.Release
    if (-not $release) {
        if ($outcome.Reachable) {
            # A mirror answered - there simply is no newer release to install. Not an error.
            Write-Verbose 'No tool release is published yet.'
        } else {
            Write-Warn 'Update check could not reach any mirror. Continuing.'
            foreach ($f in $outcome.Failures) { Write-Warn ('  {0}: {1}' -f $f.Mirror, $f.Reason) }
        }
        return
    }

    $latest = $release.Version
    $local = Get-InstalledToolVersion -ToolDir $toolDir
    if ($local -and $latest -le $local) {
        Write-Verbose ('Up to date (v{0}).' -f $local)
        return
    }

    # We need the package: it is newer than the recorded version, OR this is a first run with no
    # version.txt (force-download once to establish the baseline). Reuse a prior staged copy.
    $state = Import-SelfUpdateState -ToolDir $toolDir
    $reuse = ($state.StagedVersion -eq $latest.ToString()) -and
    $state.StagedPath -and (Test-Path -LiteralPath $state.StagedPath)
    if ($reuse) {
        $staged = $state.StagedPath
    } else {
        try {
            Write-Info ('Downloading v{0} from the {1} mirror...' -f $latest, $release.Mirror)
            $staged = Save-UpdatePackage -ToolDir $toolDir -Release $release
            $state.StagedVersion = $latest.ToString()
            $state.StagedPath = $staged
            Save-SelfUpdateState -ToolDir $toolDir -State $state
        } catch {
            Write-Warn "Could not download the update ($($_.Exception.Message)). Continuing."
            return
        }
    }

    if (-not $local) {
        # First run: if the downloaded release is byte-for-byte what is already installed, just record
        # the baseline silently; otherwise fall through and offer it as an update to apply.
        if ((Get-ShippedContentHash -Dir $staged) -eq (Get-ShippedContentHash -Dir $toolDir)) {
            Set-InstalledToolVersion -ToolDir $toolDir -Version $latest.ToString()
            $state.StagedVersion = $null
            $state.StagedPath = $null
            Save-SelfUpdateState -ToolDir $toolDir -State $state
            Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
            Write-Verbose ('Baseline recorded: v{0} (already current).' -f $latest)
            return
        }
    }

    Write-Info ('Update ready: v{0} (installed {1}) from the {2} mirror.' -f `
            $latest, (Coalesce $local 'unknown'), $release.Mirror)
    $script:PendingUpdate = [pscustomobject]@{
        Version   = $latest.ToString()
        Mirror    = $release.Mirror
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

    # Record the newly-installed version locally; this is the source of truth for future checks.
    Set-InstalledToolVersion -ToolDir $toolDir -Version $pending.Version
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
