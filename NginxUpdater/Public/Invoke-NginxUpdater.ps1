function Invoke-NginxUpdater {
    <#
    .SYNOPSIS
        Entry point: resolves the root, loads config, and runs the interactive menu loop.
    .DESCRIPTION
        The one public command of the NginxUpdater module. Normally invoked through the
        Update-Nginx.ps1 launcher, which passes its own path as -LauncherPath so the elevation
        relaunch can re-run the correct script.
    .PARAMETER Root
        nginx root folder to manage. Prompts if omitted.
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
        [string]$LauncherPath
    )

    # Record the invocation for a possible elevation relaunch (module functions cannot read the
    # caller's locals, so we stash what Assert-Admin needs in module scope).
    $script:Invocation = @{
        Root         = $Root
        NssmPath     = $NssmPath
        ServiceName  = $ServiceName
        Channel      = $Channel
        LauncherPath = $LauncherPath
    }

    if (-not $script:OnWindows) {
        $plat = [System.Environment]::OSVersion.Platform
        Write-Warn "This tool targets Windows. On $plat it runs read-only for inspection;"
        Write-Warn 'symlink/service actions are disabled.'
    }

    $seed = @{ ServiceName = $ServiceName; NssmPath = $NssmPath; Channel = $Channel }
    $rootPath = Get-RootInteractively $Root
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

    while ($true) {
        $st = Get-RootState $Config.Root
        $action = Show-Menu $Config $st
        try {
            switch ($action) {
                'scaffold' { Invoke-Scaffold $Config }
                'migrate' { Invoke-Migrate $Config $st }
                'update' { Invoke-Update $Config $st }
                'switch' { Invoke-SwitchVersion $Config $st }
                'restart' { Restart-NginxService $Config.ServiceName }
                'reload' { Invoke-ReloadConfig $Config }
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
