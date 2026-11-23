function Invoke-NginxUpdater {
    <#
    .SYNOPSIS
        Entry point: resolves the root, loads config, and runs the interactive menu loop.
    .DESCRIPTION
        The one public command of the NginxUpdater module. Normally invoked through the
        Update-Nginx.ps1 launcher, which passes its own path as -LauncherPath so the elevation
        relaunch can re-run the correct script.
    .PARAMETER Root
        nginx root folder to manage. Optional: auto-detected from ..\nginx.exe (or asked) if omitted.
    .PARAMETER NssmPath
        Path to nssm.exe (only needed to create a service). Auto-detected if omitted.
    .PARAMETER ServiceName
        Windows service name to manage. Auto-detected / created if omitted.
    .PARAMETER Channel
        Default release channel: 'stable', 'mainline', or 'ask'.
    .PARAMETER Status
        Print state and diagnostics, then exit (no interactive menu).
    .PARAMETER LauncherPath
        Path to the launcher script, used when relaunching elevated.
    .PARAMETER SkipUpdateCheck
        Skip the startup self-update check (for offline or locked-down servers).
    .PARAMETER Mode
        'managed' (this install manages one nginx root) or 'manager' (tracks many managed installs and
        updates them all). Default: the mode saved for this install, else 'managed'.
    .PARAMETER Action
        Manager mode only. 'Menu' (default) is interactive; 'Status', 'UpdateTools', 'UpdateNginx' and
        'Restart' run once without prompting (for scheduled tasks).
    .PARAMETER Restart
        Manager mode, -Action UpdateNginx: also restart each service (config tested first). Without it
        the new nginx activates on each install's next natural restart.
    .EXAMPLE
        Invoke-NginxUpdater -Root C:\nginx
    #>
    [CmdletBinding()]
    param(
        [string]$Root,
        [string]$NssmPath,
        [string]$ServiceName,
        [ValidateSet('stable', 'mainline', 'ask')]
        [string]$Channel = 'ask',
        [switch]$Status,
        [string]$LauncherPath,
        [switch]$SkipUpdateCheck,
        [ValidateSet('managed', 'manager')]
        [string]$Mode,
        [ValidateSet('Menu', 'Status', 'UpdateTools', 'UpdateNginx', 'Restart')]
        [string]$Action = 'Menu',
        [switch]$Restart
    )

    # Record the invocation for a possible elevation relaunch (module functions cannot read the
    # caller's locals, so we stash what Assert-Admin needs in module scope).
    $script:Invocation = @{
        Root         = $Root
        NssmPath     = $NssmPath
        ServiceName  = $ServiceName
        Channel      = $Channel
        LauncherPath = $LauncherPath
        Mode         = $Mode
    }

    if (-not $script:OnWindows) {
        $plat = [System.Environment]::OSVersion.Platform
        Write-Warn "This tool targets Windows. On $plat it runs read-only for inspection;"
        Write-Warn 'symlink/service actions are disabled.'
    }

    # Manager mode: explicit -Mode, else this install's saved mode. No nginx root is involved.
    # A non-Menu -Action is an unattended manager run: it implies manager mode and must never prompt.
    $script:NonInteractive = ($Action -ne 'Menu')
    if ($script:NonInteractive -and $Mode -eq 'managed') {
        throw '-Action is only valid in manager mode (omit -Mode managed).'
    }
    $toolMode = if ($script:NonInteractive) { 'manager' } else { Resolve-ToolMode $Mode }
    if ($toolMode -eq 'manager') {
        $mgr = @{ Action = $(if ($Status) { 'Status' } else { $Action }); Restart = $Restart }
        if ($PSBoundParameters.ContainsKey('Channel')) { $mgr.Channel = $Channel }
        Invoke-ManagerMode @mgr -SkipUpdateCheck:$SkipUpdateCheck
        return
    }

    $seed = @{ ServiceName = $ServiceName; NssmPath = $NssmPath; Channel = $Channel }
    $rootPath = Resolve-RootPath $Root
    if (-not $rootPath) {
        # The user chose "run as the manager" at the first-run prompt: remember it and switch.
        Set-ToolMode 'manager'
        Write-Info 'Manager mode saved for this install.'
        Write-Info '(To undo: delete .nginx-updater-mode, or pass -Mode managed.)'
        Invoke-ManagerMode -SkipUpdateCheck:$SkipUpdateCheck
        return
    }
    $Config = Import-Config -RootPath $rootPath -Defaults $seed
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

    # Best-effort self-update check (warns and continues on any failure).
    if (-not $SkipUpdateCheck) { Invoke-SelfUpdateCheck }

    while ($true) {
        $st = Get-RootState $Config.Root
        $action = Show-Menu $Config $st
        try {
            switch ($action) {
                'scaffold' { Invoke-Scaffold $Config }
                'migrate' { Invoke-Migrate $Config $st }
                'update' { Invoke-Update $Config $st }
                'switch' { Invoke-SwitchVersion $Config $st }
                'restart' { Invoke-CheckedRestart $Config | Out-Null }
                'test' { Invoke-TestConfig $Config }
                'reload' { Invoke-ReloadConfig $Config }
                'backup' { Invoke-BackupMenu $Config }
                'selfupdate' { if (Invoke-SelfUpdateApply) { return } }
                'status' { Show-Status $Config $st }
                'configure' { Invoke-Configure $Config }
                'changeroot' {
                    $new = (Read-Host 'New nginx root').Trim().Trim('"')
                    if ($new) {
                        $Config = Import-Config -RootPath $new -Defaults $seed
                        if (-not $Config.ServiceName) {
                            $f = Find-ServiceForRoot $new
                            if ($f) { $Config.ServiceName = $f }
                        }
                    }
                }
                'quit' { Write-Info 'Bye.'; return }
                'noop' { }
                default { }
            }
        } catch {
            Write-Err "Error: $($_.Exception.Message)"
        }
    }
}
