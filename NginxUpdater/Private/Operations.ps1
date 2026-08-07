function Invoke-Scaffold {
    <#
    .SYNOPSIS
        Empty folder -> full managed install (versions, conf/html seed, symlink, optional service).
    #>
    param([hashtable]$Config)
    if (-not (Assert-Admin 'scaffolding a managed install')) { return }

    $root = $Config.Root
    Write-Head "Scaffold managed install at: $root"
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    $version = Resolve-TargetVersion $Config.Channel
    if (-not $version) { Write-Err 'No version resolved.'; return }
    $zip = Get-NginxZip $version
    try {
        $verDir = Install-VersionFiles -RootPath $root -Version $version -ZipPath $zip

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
                Write-Warn 'nssm.exe not found. Set its path via Configure, then re-run this step.'
            } else {
                $Config.NssmPath = $nssm
                New-NginxNssmService -RootPath $root -Name $Config.ServiceName -NssmExe $nssm
            }
        }
        Save-Config $Config
        Write-Good "`nScaffold complete. nginx $version is active."
    } finally {
        Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
    }
}

function Invoke-Migrate {
    <#
    .SYNOPSIS
        Manual install -> managed: moves the existing nginx.exe into versions\<ver>\ and links it.
    #>
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    if (-not (Assert-Admin 'migrating to a managed install')) { return }

    $root = $Config.Root
    Write-Head "Migrate manual install -> managed: $root"

    $exe = $StateInfo.ExePath
    $detected = Get-ExeVersionString $exe
    if (-not $detected) {
        $detected = (Read-Host 'Could not auto-detect the installed version. Enter it (e.g. 1.28.0)').Trim()
        if ($detected -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Write-Err 'Invalid version.'; return }
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
    Write-Info 'The running nginx is still on the old binary handle; it now matches the managed layout.'
    Write-Info 'Future upgrades will repoint the symlink and activate on restart.'
}

function Invoke-Update {
    <#
    .SYNOPSIS
        Managed install -> download and stage a version, repoint the link, then prompt to restart.
    #>
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    if (-not (Assert-Admin 'updating the managed install')) { return }

    $root = $Config.Root
    Write-Head "Update / install a version: $root"
    $active = Get-ActiveVersion $Config $StateInfo
    if ($active) { Write-Info "Currently active: $active" }

    $version = Resolve-TargetVersion $Config.Channel
    if (-not $version) { Write-Err 'No version resolved.'; return }
    if ($version -eq $active) {
        if (-not (Confirm-YesNo "Version $version is already active. Re-stage it anyway?" $false)) { return }
    }

    $installed = Get-InstalledVersions $root
    if ($installed -contains $version) {
        Write-Info "Version $version is already staged under versions\."
    } else {
        $zip = Get-NginxZip $version
        try { Install-VersionFiles -RootPath $root -Version $version -ZipPath $zip | Out-Null }
        finally { Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue }
    }

    # Validate the live config against the NEW binary before switching.
    if (-not (Test-NginxConfig $root $version)) {
        if (-not (Confirm-YesNo 'Config test was not clean. Repoint the symlink anyway?' $false)) {
            Write-Warn "Aborted; symlink unchanged. Staged binary remains under versions\$version."
            return
        }
    }

    Set-ActiveVersionLink $root $version
    $Config.ActiveVersion = $version
    Save-Config $Config
    Write-Good "`nStaged and linked nginx $version. The running process is still on $active."
    Invoke-RestartPrompt $Config
}

function Invoke-SwitchVersion {
    <#
    .SYNOPSIS
        Rolls the active version back or forward to any already-staged build.
    #>
    param([hashtable]$Config, [pscustomobject]$StateInfo)
    if (-not (Assert-Admin 'switching the active version')) { return }
    $root = $Config.Root
    $versions = Get-InstalledVersions $root
    if ($versions.Count -eq 0) { Write-Warn 'No staged versions found under versions\.'; return }
    $active = Get-ActiveVersion $Config $StateInfo

    Write-Head 'Switch active version'
    for ($i = 0; $i -lt $versions.Count; $i++) {
        $mark = if ($versions[$i] -eq $active) { '  (active)' } else { '' }
        Write-Host ('  {0}) {1}{2}' -f ($i + 1), $versions[$i], $mark)
    }
    $sel = Read-Menu 'Choose a version (or blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $versions.Count) {
        Write-Warn 'Invalid selection.'; return
    }
    $chosen = $versions[[int]$sel - 1]
    if ($chosen -eq $active) { Write-Info 'Already active.'; return }

    Test-NginxConfig $root $chosen | Out-Null
    Set-ActiveVersionLink $root $chosen
    $Config.ActiveVersion = $chosen
    Save-Config $Config
    Write-Good "Switched active binary to $chosen (running process unchanged until restart)."
    Invoke-RestartPrompt $Config
}

function Invoke-RestartPrompt {
    <#
    .SYNOPSIS
        Asks whether to restart nginx now, wait for the next natural restart, or reload config.
    #>
    param([hashtable]$Config)
    $svc = $Config.ServiceName
    $status = Get-ServiceStatus $svc
    Write-Host ''
    Write-Info 'The new binary is linked but will only run after nginx restarts.'
    Write-Host "  Service : $svc  (status: $status)"
    Write-Host ''
    Write-Host '  1) Restart nginx now (brief blip; activates the new binary immediately)'
    Write-Host '  2) Wait for the next natural restart (activates then; zero action now)'
    Write-Host '  3) Reload config only (nginx -s reload - does NOT swap the binary)'
    $c = Read-Menu 'Choice'
    switch ($c) {
        '1' { if (Invoke-CheckedRestart $Config) { Write-Good 'New binary is now live.' } }
        '2' { Write-Info 'OK - the new binary will activate on the next service restart / reboot.' }
        '3' { Invoke-ReloadConfig $Config }
        default { Write-Info 'No action taken; new binary activates on next restart.' }
    }
}

function Invoke-TestConfig {
    <#
    .SYNOPSIS
        Tests the live config against the active nginx.exe (nginx -t) and reports the result.
    #>
    param([hashtable]$Config)
    Write-Head "Test config: $($Config.Root)"
    Test-NginxConfig -RootPath $Config.Root | Out-Null
}

function Invoke-CheckedRestart {
    <#
    .SYNOPSIS
        Restarts nginx, but only after a passing config test - or an explicit forced override.
    .DESCRIPTION
        Runs nginx -t against the active binary first. On failure it warns and asks whether to force
        the restart anyway (default No); refusing leaves the service untouched. Returns $true only if
        a restart actually happened.
    #>
    param([hashtable]$Config)
    $svc = $Config.ServiceName
    if (-not $svc) { Write-Err 'No service name configured.'; return $false }

    if (-not (Test-NginxConfig -RootPath $Config.Root)) {
        Write-Warn 'Config test FAILED - restarting now risks nginx failing to come back up.'
        if (-not (Confirm-YesNo 'Force restart anyway despite the failed config test?' $false)) {
            Write-Info 'Restart cancelled. Fix the config (or restore a backup), then retry.'
            return $false
        }
    }
    try {
        Restart-NginxService $svc
        return $true
    } catch {
        Write-Err "Restart failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-ReloadConfig {
    <#
    .SYNOPSIS
        Sends "nginx -s reload" to re-read config without swapping the binary.
    #>
    param([hashtable]$Config)
    $exe = Get-NginxExePath $Config.Root
    if (-not (Test-Path -LiteralPath $exe)) { Write-Warn 'No active nginx.exe.'; return }
    Write-Info 'Reloading config (nginx -s reload)...'
    try { & $exe -s reload -p $Config.Root 2>&1 | Out-String | Write-Host; Write-Good 'Reload signal sent.' }
    catch { Write-Err "Reload failed: $($_.Exception.Message)" }
}
