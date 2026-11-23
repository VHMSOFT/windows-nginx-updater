function Get-InstanceInfo {
    <#
    .SYNOPSIS
        Gathers display/decision facts about one registered install (read-only).
    #>
    param([pscustomobject]$Instance)
    $info = [pscustomobject]@{
        Instance      = $Instance
        Exists        = (Test-Path -LiteralPath $Instance.Root)
        State         = 'Missing'
        Active        = $null
        Service       = $null
        ServiceStatus = $null
        Channel       = $null
        ToolVersion   = $null
    }
    if ($Instance.ToolDir -and (Test-Path -LiteralPath $Instance.ToolDir)) {
        $info.ToolVersion = Get-InstalledToolVersion -ToolDir $Instance.ToolDir
    }
    if (-not $info.Exists) { return $info }
    $cfg = Import-Config -RootPath $Instance.Root -Defaults @{}
    if (-not $cfg.ServiceName) {
        $found = Find-ServiceForRoot $Instance.Root
        if ($found) { $cfg.ServiceName = $found }
    }
    $st = Get-RootState $Instance.Root
    $info.State = $st.State
    if ($st.State -eq 'Managed') { $info.Active = Get-ActiveVersion $cfg $st }
    $info.Service = $cfg.ServiceName
    $info.ServiceStatus = Get-ServiceStatus $cfg.ServiceName
    $info.Channel = $cfg.Channel
    return $info
}

function Show-Instance {
    <#
    .SYNOPSIS
        Prints the registered installs with their nginx and tool versions.
    #>
    $instances = @(Import-Instance)
    Write-Head ('Managed installs ({0})  -  registry: {1}' -f $instances.Count, (Get-RegistryPath))
    if ($instances.Count -eq 0) {
        Write-Host '  (none registered yet - use "a" to add one)'
        return
    }
    $n = 0
    foreach ($inst in $instances) {
        $n++
        $i = Get-InstanceInfo $inst
        Write-Host ('  {0}) {1}' -f $n, $inst.Root) -ForegroundColor White
        if (-not $i.Exists) { Write-Warn '       folder not found'; continue }
        $nginxLabel = Coalesce $i.Active '-'
        Write-Host ('       nginx: {0}   state: {1}   channel: {2}' -f $nginxLabel, $i.State, $i.Channel)
        Write-Host ('       service: {0} [{1}]' -f (Coalesce $i.Service '-'), $i.ServiceStatus)
        $toolLabel = if ($inst.ToolDir) {
            '{0}  ({1})' -f (Coalesce $i.ToolVersion 'unknown'), $inst.ToolDir
        } else {
            'not tracked (no tool folder registered)'
        }
        Write-Host ('       tool : {0}' -f $toolLabel)
    }
}

function Find-ToolDirForRoot {
    <#
    .SYNOPSIS
        Looks for an updater install (Update-Nginx.ps1 + NginxUpdater\) in a root or one folder below it.
    #>
    param([string]$Root)
    foreach ($c in @($Root) + @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName)) {
        if ((Test-Path -LiteralPath (Join-Path $c 'Update-Nginx.ps1')) -and
            (Test-Path -LiteralPath (Join-Path $c 'NginxUpdater'))) { return $c }
    }
    return $null
}

function Add-ManagedInstance {
    <#
    .SYNOPSIS
        Registers a managed install by nginx root (and, optionally, its updater tool folder).
    #>
    param([string]$Root, [string]$ToolDir)
    if (-not $Root) { $Root = (Read-Host 'nginx root of the install to add').Trim().Trim('"') }
    if (-not $Root) { return }
    if (-not (Test-Path -LiteralPath $Root)) { Write-Err "Folder not found: $Root"; return }
    $Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

    $instances = @(Import-Instance)
    if (@($instances | Where-Object { Test-SamePath $_.Root $Root }).Count -gt 0) {
        Write-Warn 'That root is already registered.'; return
    }
    if (-not $ToolDir) {
        $guess = Find-ToolDirForRoot $Root
        $prompt = if ($guess) { "Updater tool folder [$guess] (type - for none)" } else {
            'Updater tool folder (blank = none; tool code then is not updated for this install)'
        }
        $ToolDir = (Read-Host $prompt).Trim().Trim('"')
        if (-not $ToolDir -and $guess) { $ToolDir = $guess }
        if ($ToolDir -eq '-') { $ToolDir = $null }
    }
    if ($ToolDir) {
        if (-not ((Test-Path -LiteralPath (Join-Path $ToolDir 'Update-Nginx.ps1')) -and
                (Test-Path -LiteralPath (Join-Path $ToolDir 'NginxUpdater')))) {
            Write-Err "'$ToolDir' does not contain Update-Nginx.ps1 and NginxUpdater\; not added."; return
        }
        $ToolDir = (Resolve-Path -LiteralPath $ToolDir).ProviderPath.TrimEnd('\', '/')
    }
    $instances += [pscustomobject]@{ Root = $Root; ToolDir = $ToolDir }
    Save-Instance $instances
    Write-Good "Added $Root"
}

function Remove-ManagedInstance {
    <#
    .SYNOPSIS
        Unregisters an install by list number. The install itself is not touched.
    #>
    $instances = @(Import-Instance)
    if ($instances.Count -eq 0) { Write-Warn 'Nothing to remove.'; return }
    Show-Instance
    $sel = Read-Menu 'Number to remove (blank to cancel)'
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $instances.Count) { return }
    $gone = $instances[[int]$sel - 1]
    if (-not (Confirm-YesNo "Stop tracking $($gone.Root)? (files are not deleted)" $false)) { return }
    Save-Instance @($instances | Where-Object { $_ -ne $gone })
    Write-Good 'Removed.'
}

function Write-ResultSummary {
    <#
    .SYNOPSIS
        Prints per-install results and returns how many failed.
    #>
    param([object[]]$Results, [string]$Title)
    Write-Head $Title
    $failed = 0
    foreach ($r in $Results) {
        $color = switch ($r.Status) {
            'Failed' { $failed++; 'Red' }
            'Updated' { 'Green' }
            'Skipped' { 'Yellow' }
            default { 'Gray' }
        }
        $ver = ''
        if ($r.From -or $r.To) { $ver = '  {0} -> {1}' -f (Coalesce $r.From '?'), (Coalesce $r.To '?') }
        Write-Host ('  [{0,-8}] {1}{2}' -f $r.Status, $r.Root, $ver) -ForegroundColor $color
        if ($r.Message) { Write-Host ('             {0}' -f $r.Message) -ForegroundColor $color }
    }
    return $failed
}

function Get-ManagerRelease {
    <#
    .SYNOPSIS
        Latest published tool release as seen from the manager (cached for the run), or $null.
    #>
    if ($script:ManagerRelease) { return $script:ManagerRelease }
    $toolDir = Get-ToolDir
    $state = Import-SelfUpdateState -ToolDir $toolDir
    try {
        $o = Get-LatestReleaseAcrossMirrors -ToolDir $toolDir -State $state
    } catch {
        Write-Warn "Release lookup failed ($($_.Exception.Message))."; return $null
    }
    if (-not $o.Release) {
        Write-Warn 'No tool release is available (unreachable or none published).'
        foreach ($f in $o.Failures) { Write-Warn ('  {0}: {1}' -f $f.Mirror, $f.Reason) }
    }
    $script:ManagerRelease = $o.Release
    return $o.Release
}

function Get-InstanceBehind {
    <#
    .SYNOPSIS
        Registered installs that have a tool folder (other than the manager's own) and are not on -Release.
    #>
    param([pscustomobject]$Release)
    $own = Get-ToolDir
    $out = @()
    foreach ($inst in (Import-Instance)) {
        if (-not $inst.ToolDir -or (Test-SamePath $inst.ToolDir $own)) { continue }
        $local = if (Test-Path -LiteralPath $inst.ToolDir) { Get-InstalledToolVersion -ToolDir $inst.ToolDir }
        if (-not $local -or $local -lt $Release.Version) { $out += $inst }
    }
    return $out
}

function Invoke-UpdateAllTool {
    <#
    .SYNOPSIS
        Pushes the latest tool release into every registered install's tool folder. Returns failure count.
    #>
    $instances = @(Import-Instance)
    if ($instances.Count -eq 0) { Write-Info 'No installs registered.'; return 0 }
    $release = Get-ManagerRelease
    if (-not $release) { return 1 }
    $targets = @(Get-InstanceBehind $release)
    if ($targets.Count -eq 0) {
        Write-Good ('All tracked installs are already on v{0}.' -f $release.Version)
        return 0
    }
    $results = @()
    try {
        Write-Info ('Downloading v{0} from the {1} mirror...' -f $release.Version, $release.Mirror)
        $staged = Save-UpdatePackage -ToolDir (Get-ToolDir) -Release $release
    } catch {
        Write-Err "Could not download the release: $($_.Exception.Message)"
        return 1
    }
    try {
        $stagedHash = $null
        foreach ($inst in $targets) {
            $r = [pscustomobject]@{
                Root = $inst.Root; Status = 'Updated'; From = $null; To = $release.Version.ToString(); Message = ''
            }
            if (-not (Test-Path -LiteralPath $inst.ToolDir)) {
                $r.Status = 'Failed'; $r.Message = "tool folder not found: $($inst.ToolDir)"
                $results += $r; continue
            }
            $local = Get-InstalledToolVersion -ToolDir $inst.ToolDir
            $r.From = if ($local) { $local.ToString() } else { $null }
            try {
                if (-not $local) {
                    # No recorded version: if the files are already identical, just record the baseline.
                    if (-not $stagedHash) { $stagedHash = Get-ShippedContentHash -Dir $staged }
                    if ($stagedHash -eq (Get-ShippedContentHash -Dir $inst.ToolDir)) {
                        Set-InstalledToolVersion -ToolDir $inst.ToolDir -Version $release.Version.ToString()
                        $r.Status = 'UpToDate'; $r.Message = 'identical files; version recorded'
                        $results += $r; continue
                    }
                }
                Install-ToolUpdate -ToolDir $inst.ToolDir -StagedDir $staged `
                    -Version $release.Version.ToString() | Out-Null
            } catch {
                $r.Status = 'Failed'; $r.Message = $_.Exception.Message
            }
            $results += $r
        }
    } finally {
        Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
    }
    return (Write-ResultSummary $results 'Tool update results')
}

function Invoke-UpdateAllNginx {
    <#
    .SYNOPSIS
        Runs the nginx update on every registered install. Returns failure count.
    .DESCRIPTION
        Each install is staged, config-tested and relinked, then left to activate on its next natural
        restart - unless -Restart is given, which restarts each service (config tested first).
    #>
    param([string]$Channel, [string]$FallbackChannel, [switch]$Restart)
    $instances = @(Import-Instance)
    if ($instances.Count -eq 0) { Write-Info 'No installs registered.'; return 0 }
    try {
        $avail = Get-AvailableVersions
    } catch {
        Write-Err $_.Exception.Message; return 1
    }
    $results = @()
    foreach ($inst in $instances) {
        Write-Head "nginx update: $($inst.Root)"
        if (-not (Test-Path -LiteralPath $inst.Root)) {
            $results += [pscustomobject]@{
                Root = $inst.Root; Status = 'Failed'; From = $null; To = $null; Message = 'folder not found'
            }
            continue
        }
        try {
            $cfg = Import-Config -RootPath $inst.Root -Defaults @{}
            if (-not $cfg.ServiceName) {
                $found = Find-ServiceForRoot $inst.Root
                if ($found) { $cfg.ServiceName = $found }
            }
            $results += Invoke-UpdateUnattended -Config $cfg -Available $avail -Channel $Channel `
                -FallbackChannel $FallbackChannel -Restart:$Restart
        } catch {
            $results += [pscustomobject]@{
                Root = $inst.Root; Status = 'Failed'; From = $null; To = $null; Message = $_.Exception.Message
            }
        }
    }
    return (Write-ResultSummary $results 'nginx update results')
}

function Invoke-RestartAll {
    <#
    .SYNOPSIS
        Restarts every registered install's service (config tested first). Returns failure count.
    #>
    $results = @()
    foreach ($inst in (Import-Instance)) {
        Write-Head "Restart: $($inst.Root)"
        $r = [pscustomobject]@{ Root = $inst.Root; Status = 'Failed'; From = $null; To = $null; Message = '' }
        if (-not (Test-Path -LiteralPath $inst.Root)) { $r.Message = 'folder not found'; $results += $r; continue }
        $cfg = Import-Config -RootPath $inst.Root -Defaults @{}
        if (-not $cfg.ServiceName) {
            $found = Find-ServiceForRoot $inst.Root
            if ($found) { $cfg.ServiceName = $found }
        }
        $rs = Invoke-RestartUnattended $cfg
        $r.Message = $rs.Message
        if ($rs.Ok) { $r.Status = 'Updated' }
        $results += $r
    }
    if ($results.Count -eq 0) { Write-Info 'No installs registered.'; return 0 }
    return (Write-ResultSummary $results 'Restart results')
}

function Read-FallbackChannel {
    <#
    .SYNOPSIS
        If any registered install has no concrete channel, asks which to use for those. Returns it or $null.
    #>
    $needs = @()
    foreach ($inst in @(Import-Instance)) {
        if (-not (Test-Path -LiteralPath $inst.Root)) { continue }
        $cfg = Import-Config -RootPath $inst.Root -Defaults @{}
        if ($cfg.Channel -in 'stable', 'mainline') { continue }
        $st = Get-RootState $inst.Root
        # Installs whose running version reveals the channel need no question.
        if ($st.State -eq 'Managed' -and (Get-ChannelOfVersion (Get-ActiveVersion $cfg $st))) { continue }
        $needs += $inst
    }
    if ($needs.Count -eq 0) { return $null }
    Write-Warn ('{0} install(s) have no saved channel and an unknown running version:' -f $needs.Count)
    foreach ($n in $needs) { Write-Host "  - $($n.Root)" }
    Write-Host '  1) Use stable for them'
    Write-Host '  2) Use mainline for them'
    Write-Host '  3) Skip them'
    switch (Read-Menu 'Choice') {
        '1' { return 'stable' }
        '2' { return 'mainline' }
        default { return $null }
    }
}

function Invoke-ManagerMode {
    <#
    .SYNOPSIS
        Manager mode: tracks managed installs and updates/restarts them all from one place.
    .DESCRIPTION
        With -Action Menu (default) shows the interactive manager menu. Other actions run once without
        prompting - suitable for a scheduled task - and set $global:NginxUpdaterExitCode (0 ok, 1 failures).
    #>
    param(
        [ValidateSet('Menu', 'Status', 'UpdateTools', 'UpdateNginx', 'Restart')]
        [string]$Action = 'Menu',
        [string]$Channel,
        [switch]$Restart,
        [switch]$SkipUpdateCheck
    )
    $script:ManagerRelease = $null

    if ($Action -ne 'Menu') {
        $failed = 0
        try {
            switch ($Action) {
                'Status' { Show-Instance }
                'UpdateTools' { $failed = Invoke-UpdateAllTool }
                'UpdateNginx' {
                    if (-not (Test-Admin)) { Write-Err 'Updating nginx needs Administrator.'; $failed = 1; break }
                    $failed = Invoke-UpdateAllNginx -Channel $Channel -Restart:$Restart
                }
                'Restart' {
                    if (-not (Test-Admin)) {
                        Write-Err 'Restarting services needs Administrator.'; $failed = 1; break
                    }
                    $failed = Invoke-RestartAll
                }
            }
        } catch {
            Write-Err "Unattended $Action failed: $($_.Exception.Message)"
            $failed = 1
        }
        $global:NginxUpdaterExitCode = if ($failed) { 1 } else { 0 }
        return
    }

    if (-not $SkipUpdateCheck) {
        Invoke-SelfUpdateCheck
        $release = Get-ManagerRelease
        if ($release) {
            $behind = @(Get-InstanceBehind $release)
            if ($behind.Count -gt 0) {
                Write-Warn ('{0} tracked install(s) are behind tool v{1} - choose 2 to update them.' -f `
                        $behind.Count, $release.Version)
            }
        }
    }

    while ($true) {
        Write-Host ''
        Write-Host ('-' * 70) -ForegroundColor DarkGray
        Write-Host (' nginx updater - MANAGER  |  {0} install(s) tracked' -f @(Import-Instance).Count) `
            -ForegroundColor White
        Write-Host ('-' * 70) -ForegroundColor DarkGray
        if ($script:PendingUpdate) {
            Write-Host (' ** Manager update v{0} downloaded - press u to apply and restart ** ' -f `
                    $script:PendingUpdate.Version) -ForegroundColor Black -BackgroundColor Yellow
        }
        Write-Host '  1) List installs / status'
        Write-Host '  2) Update tool code on all installs'
        Write-Host '  3) Update nginx on all installs (activates on each next natural restart)'
        Write-Host '  4) Update nginx on all installs AND restart them now'
        Write-Host '  5) Restart all installs now (config tested first)'
        Write-Host '  a) Add an install     d) Remove an install'
        if ($script:PendingUpdate) { Write-Host '  u) Apply manager update and restart' }
        Write-Host '  q) Quit'
        $sel = (Read-Menu 'Select').ToLowerInvariant()
        try {
            switch ($sel) {
                '1' { Show-Instance }
                '2' { Invoke-UpdateAllTool | Out-Null }
                '3' {
                    if (Assert-Admin 'updating nginx on all installs') {
                        Invoke-UpdateAllNginx -FallbackChannel (Read-FallbackChannel) | Out-Null
                    }
                }
                '4' {
                    if ((Assert-Admin 'updating and restarting nginx on all installs') -and
                        (Confirm-YesNo 'Restart every tracked nginx service after updating?' $false)) {
                        Invoke-UpdateAllNginx -FallbackChannel (Read-FallbackChannel) -Restart | Out-Null
                    }
                }
                '5' {
                    if ((Assert-Admin 'restarting services') -and
                        (Confirm-YesNo 'Restart every tracked nginx service now?' $false)) {
                        Invoke-RestartAll | Out-Null
                    }
                }
                'a' { Add-ManagedInstance }
                'd' { Remove-ManagedInstance }
                'u' { if ($script:PendingUpdate -and (Invoke-SelfUpdateApply)) { return } }
                'q' { Write-Info 'Bye.'; return }
                default { Write-Warn 'Unknown option.' }
            }
        } catch {
            Write-Err "Error: $($_.Exception.Message)"
        }
    }
}
