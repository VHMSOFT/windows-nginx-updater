function Show-Status {
    <#
    .SYNOPSIS
        Prints the managed-install state and diagnostics for a root folder.
    #>
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    Write-Head "Status: $($Config.Root)"
    Write-Host ('  State          : {0}' -f $StateInfo.State)
    if ($StateInfo.ExeExists) {
        Write-Host ('  nginx.exe      : {0}' -f $StateInfo.ExePath)
        Write-Host ('  Is symlink     : {0}' -f $StateInfo.IsSymlink)
        if ($StateInfo.IsSymlink) {
            Write-Host ('  -> target      : {0}' -f (Coalesce $StateInfo.LinkTarget '(unresolved on PS5.1)'))
        }
        $active = Get-ActiveVersion $Config $StateInfo
        if ($active) { Write-Host ('  Active version : {0}' -f $active) }
        $running = Get-ExeVersionString $StateInfo.ExePath
        if ($running) { Write-Host ('  Binary reports : {0}' -f $running) }
    }
    $installed = Get-InstalledVersions $Config.Root
    Write-Host ('  Staged versions: {0}' -f (($installed -join ', ') -replace '^$', '(none)'))
    Write-Host ('  Backups        : {0}' -f (Get-ConfHtmlBackup $Config.Root).Count)
    $svcName = Coalesce $Config.ServiceName '(none)'
    $svcState = Get-ServiceStatus $Config.ServiceName
    Write-Host ('  Service        : {0}  (status: {1})' -f $svcName, $svcState)
    $nssm = Find-NssmPath $Config.NssmPath
    Write-Host ('  nssm.exe       : {0}' -f (Coalesce $nssm '(not found)'))
    Write-Host ('  Channel default: {0}' -f $Config.Channel)
    Write-Host ('  Admin          : {0}' -f (Test-Admin))
}

function Invoke-Configure {
    <#
    .SYNOPSIS
        Interactively updates and saves the root, service name, nssm path and channel.
    #>
    param([hashtable]$Config)
    Write-Head 'Configure'
    Write-Host 'Leave blank to keep the current value shown in [brackets].'
    $r = (Read-Host "nginx root [$($Config.Root)]").Trim(); if ($r) { $Config.Root = $r }
    $s = (Read-Host "Service name [$($Config.ServiceName)]").Trim(); if ($s) { $Config.ServiceName = $s }
    $n = (Read-Host "nssm.exe path [$($Config.NssmPath)]").Trim(); if ($n) { $Config.NssmPath = $n }
    $c = (Read-Host "Default channel stable/mainline/ask [$($Config.Channel)]").Trim().ToLowerInvariant()
    if ($c -in 'stable', 'mainline', 'ask') {
        $Config.Channel = $c
    } elseif ($c) {
        Write-Warn "Ignored invalid channel '$c'."
    }
    Save-Config $Config
    Write-Good 'Saved.'
}

function Resolve-RootPath {
    <#
    .SYNOPSIS
        Determines the nginx root: the -Root value, else auto-detected from ..\nginx.exe, else asked.
    .DESCRIPTION
        With no -Root, looks for nginx.exe one level above the launcher - the tool deployed as a
        subfolder of the nginx root (so ..\nginx.exe is the running binary). If found, that parent
        folder is the root. If not, asks whether this is a new install that should be rooted there;
        otherwise prompts for the path to an nginx root elsewhere. No parameter is ever required.
    #>
    param([string]$Provided)
    if ($Provided) { return $Provided }

    # Base the ..\nginx.exe lookup on the launcher's folder (falls back to the working directory).
    $baseDir = $null
    $inv = $script:Invocation
    if ($inv.ContainsKey('LauncherPath') -and $inv['LauncherPath']) {
        $baseDir = Split-Path -Parent $inv['LauncherPath']
    }
    if (-not $baseDir) { $baseDir = (Get-Location).Path }

    $candidateRoot = Split-Path -Parent $baseDir
    if ($candidateRoot -and (Test-Path -LiteralPath (Join-Path $candidateRoot 'nginx.exe'))) {
        Write-Info "Auto-detected nginx root: $candidateRoot (found ..\nginx.exe next to the tool)."
        return $candidateRoot
    }

    Write-Host ''
    Write-Warn 'No nginx.exe found at ..\nginx.exe (one level above the tool).'
    if ($candidateRoot -and
        (Confirm-YesNo "Is this a new install whose root should be '$candidateRoot'?" $false)) {
        return $candidateRoot
    }
    Write-Info 'Enter the path to the existing nginx root folder.'
    Write-Host '  Examples: C:\nginx   D:\services\nginx'
    $r = (Read-Host 'nginx root').Trim().Trim('"')
    if (-not $r) { throw 'A root folder is required.' }
    return $r
}

function Show-Menu {
    <#
    .SYNOPSIS
        Renders the state-aware numbered menu and returns the chosen action name.
    #>
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    $active = if ($StateInfo.IsSymlink) { Get-ActiveVersion $Config $StateInfo } else { $null }
    $svcStatus = Get-ServiceStatus $Config.ServiceName

    Write-Host ''
    Write-Host ('-' * 70) -ForegroundColor DarkGray
    Write-Host (' nginx updater  |  root: {0}' -f $Config.Root) -ForegroundColor White
    $activeLabel = Coalesce $active '-'
    $svcLabel = Coalesce $Config.ServiceName '-'
    $fmt = ' state: {0}   active: {1}   service: {2} [{3}]'
    $line = $fmt -f $StateInfo.State, $activeLabel, $svcLabel, $svcStatus
    Write-Host $line -ForegroundColor Gray
    Write-Host ('-' * 70) -ForegroundColor DarkGray

    if ($script:PendingUpdate) {
        $banner = ' ** Tool update v{0} downloaded (from {1}) - press u to apply and restart ** ' -f `
            $script:PendingUpdate.Version, $script:PendingUpdate.Mirror
        Write-Host $banner -ForegroundColor Black -BackgroundColor Yellow
        Write-Host ('-' * 70) -ForegroundColor DarkGray
    }

    $items = [ordered]@{}
    switch ($StateInfo.State) {
        'Empty' { $items['1'] = @{ Text = 'Scaffold a new managed install here'; Action = 'scaffold' } }
        'Manual' { $items['1'] = @{ Text = 'Migrate this manual install -> managed'; Action = 'migrate' } }
        'Managed' {
            $items['1'] = @{ Text = 'Check for updates / install a version'; Action = 'update' }
            $items['2'] = @{ Text = 'Switch active version (rollback/forward)'; Action = 'switch' }
            $items['3'] = @{ Text = 'Restart nginx now (tests config first)'; Action = 'restart' }
            $items['4'] = @{ Text = 'Test config (nginx -t)'; Action = 'test' }
            $items['5'] = @{ Text = 'Reload config (nginx -s reload)'; Action = 'reload' }
        }
        default { $items['1'] = @{ Text = 'Scaffold a new managed install here'; Action = 'scaffold' } }
    }
    $items['b'] = @{ Text = 'Backup / restore conf & html'; Action = 'backup' }
    if ($script:PendingUpdate) {
        $items['u'] = @{
            Text   = ('Apply tool update to v{0} and restart' -f $script:PendingUpdate.Version)
            Action = 'selfupdate'
        }
    }
    $items['s'] = @{ Text = 'Show status / diagnostics'; Action = 'status' }
    $items['c'] = @{ Text = 'Configure (root, service, nssm, channel)'; Action = 'configure' }
    $items['r'] = @{ Text = 'Change managed root folder'; Action = 'changeroot' }
    $items['q'] = @{ Text = 'Quit'; Action = 'quit' }

    foreach ($k in $items.Keys) { Write-Host ('  {0}) {1}' -f $k, $items[$k].Text) }
    $sel = (Read-Menu 'Select').ToLowerInvariant()
    if ($items.Contains($sel)) { return $items[$sel].Action }
    Write-Warn 'Unknown option.'
    return 'noop'
}
