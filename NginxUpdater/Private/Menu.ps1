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

function Get-RootInteractively {
    <#
    .SYNOPSIS
        Returns the provided root, or prompts the user for one.
    #>
    param([string]$Provided)
    if ($Provided) { return $Provided }
    Write-Host ''
    Write-Info 'No -Root supplied. Enter the nginx root folder to manage.'
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

    $items = [ordered]@{}
    switch ($StateInfo.State) {
        'Empty' { $items['1'] = @{ Text = 'Scaffold a new managed install here'; Action = 'scaffold' } }
        'Manual' { $items['1'] = @{ Text = 'Migrate this manual install -> managed'; Action = 'migrate' } }
        'Managed' {
            $items['1'] = @{ Text = 'Check for updates / install a version'; Action = 'update' }
            $items['2'] = @{ Text = 'Switch active version (rollback/forward)'; Action = 'switch' }
            $items['3'] = @{ Text = 'Restart nginx now'; Action = 'restart' }
            $items['4'] = @{ Text = 'Reload config (nginx -s reload)'; Action = 'reload' }
        }
        default { $items['1'] = @{ Text = 'Scaffold a new managed install here'; Action = 'scaffold' } }
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
