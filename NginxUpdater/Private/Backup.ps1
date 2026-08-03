function Get-BackupRoot {
    <#
    .SYNOPSIS
        Returns the backups folder for a root (<root>\backups).
    #>
    param([string]$RootPath)
    return (Join-Path $RootPath 'backups')
}

function Copy-TreeContents {
    <#
    .SYNOPSIS
        Copies the contents of a source folder into a destination folder (created if needed).
    #>
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $items = @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)
    if ($items.Count -gt 0) {
        Copy-Item -LiteralPath $items.FullName -Destination $Destination -Recurse -Force
    }
}

function Backup-ConfHtml {
    <#
    .SYNOPSIS
        Snapshots both conf\ and html\ into <root>\backups\<timestamp>\ and returns the snapshot path.
    .DESCRIPTION
        Both folders are captured together in one timestamped snapshot. An optional label is appended
        to the folder name (e.g. '-pre-restore'). Returns $null if there is nothing to back up.
    #>
    param([string]$RootPath, [string]$Label)

    $backupRoot = Get-BackupRoot $RootPath
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = if ($Label) { "$stamp-$Label" } else { $stamp }
    $dest = Join-Path $backupRoot $name
    $i = 1
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $backupRoot "$name-$i"
        $i++
    }

    $copied = @()
    foreach ($sub in 'conf', 'html') {
        $src = Join-Path $RootPath $sub
        if (Test-Path -LiteralPath $src) {
            Copy-TreeContents -Source $src -Destination (Join-Path $dest $sub)
            $copied += $sub
        }
    }
    if ($copied.Count -eq 0) {
        Write-Warn 'Nothing to back up (no conf\ or html\ found under the root).'
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }
    Write-Good ('Backed up {0} -> backups\{1}' -f ($copied -join ' + '), (Split-Path -Leaf $dest))
    return $dest
}

function Get-ConfHtmlBackup {
    <#
    .SYNOPSIS
        Lists existing conf/html backup snapshots, newest first, with what each contains.
    #>
    param([string]$RootPath)
    $backupRoot = Get-BackupRoot $RootPath
    $snapshots = @()
    if (Test-Path -LiteralPath $backupRoot) {
        $snapshots = @(
            Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                    ForEach-Object {
                        [pscustomobject]@{
                            Name    = $_.Name
                            Path    = $_.FullName
                            HasConf = Test-Path -LiteralPath (Join-Path $_.FullName 'conf')
                            HasHtml = Test-Path -LiteralPath (Join-Path $_.FullName 'html')
                        }
                    }
        )
    }
    # Leading comma keeps this an array at the call site. Without it, a 0/1-element result unwraps
    # to $null/scalar, and Windows PowerShell 5.1 scalars have no .Count under StrictMode. Do NOT
    # "simplify" to `return $snapshots`.
    return , $snapshots
}

function Restore-ConfHtml {
    <#
    .SYNOPSIS
        Restores conf and/or html from a snapshot, after auto-backing up the current state.
    .DESCRIPTION
        Always takes a fresh '-pre-restore' backup first, then replaces the requested root folders
        with the snapshot's copies. Returns the list of folders actually restored.
    #>
    param(
        [string]$RootPath,
        [string]$BackupPath,
        [switch]$Conf,
        [switch]$Html
    )
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw "Backup not found: $BackupPath" }

    # Safety net: snapshot the current conf/html before we overwrite anything.
    Write-Info 'Backing up current conf/html before the restore...'
    Backup-ConfHtml -RootPath $RootPath -Label 'pre-restore' | Out-Null

    $restored = @()
    foreach ($sub in 'conf', 'html') {
        $want = if ($sub -eq 'conf') { $Conf } else { $Html }
        if (-not $want) { continue }
        $src = Join-Path $BackupPath $sub
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warn "Snapshot has no $sub\ - skipping."
            continue
        }
        $dst = Join-Path $RootPath $sub
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-TreeContents -Source $src -Destination $dst
        $restored += $sub
        Write-Good "Restored $sub\ from $(Split-Path -Leaf $BackupPath)"
    }
    return $restored
}

function Invoke-Restore {
    <#
    .SYNOPSIS
        Interactive restore: pick a snapshot, confirm, restore the requested folders, offer a reload.
    #>
    param([hashtable]$Config, [switch]$Conf, [switch]$Html)
    $root = $Config.Root
    $backups = Get-ConfHtmlBackup $root
    if ($backups.Count -eq 0) { Write-Warn 'No backups found under backups\.'; return }

    $targets = @()
    if ($Conf) { $targets += 'conf' }
    if ($Html) { $targets += 'html' }
    $targetLabel = $targets -join ' + '

    Write-Head "Restore $targetLabel"
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $b = $backups[$i]
        $has = @()
        if ($b.HasConf) { $has += 'conf' }
        if ($b.HasHtml) { $has += 'html' }
        Write-Host ('  {0}) {1}   [{2}]' -f ($i + 1), $b.Name, ($has -join ', '))
    }
    $sel = Read-Menu 'Choose a backup (or blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $backups.Count) {
        Write-Warn 'Invalid selection.'; return
    }
    $chosen = $backups[[int]$sel - 1]

    if ($Conf -and -not $chosen.HasConf) { Write-Warn 'That snapshot has no conf\.' }
    if ($Html -and -not $chosen.HasHtml) { Write-Warn 'That snapshot has no html\.' }
    $canConf = $Conf -and $chosen.HasConf
    $canHtml = $Html -and $chosen.HasHtml
    if (-not $canConf -and -not $canHtml) { Write-Warn 'Nothing in that snapshot to restore.'; return }

    $prompt = "Restore $targetLabel from '$($chosen.Name)'? Current conf/html are backed up first."
    if (-not (Confirm-YesNo $prompt $false)) { return }

    $restored = Restore-ConfHtml -RootPath $root -BackupPath $chosen.Path -Conf:$canConf -Html:$canHtml
    if ($restored -contains 'conf') {
        Write-Info 'conf was restored - nginx must reload/restart for it to take effect.'
        if ($Config.ServiceName -and (Confirm-YesNo 'Reload nginx config now (nginx -s reload)?' $false)) {
            Invoke-ReloadConfig $Config
        }
    }
}

function Invoke-BackupMenu {
    <#
    .SYNOPSIS
        Sub-menu to back up conf & html, or restore conf, html, or both from a snapshot.
    #>
    param([hashtable]$Config)
    Write-Head "Backup / restore conf & html: $($Config.Root)"
    $count = (Get-ConfHtmlBackup $Config.Root).Count
    Write-Host ('  Existing snapshots: {0}' -f $count)
    Write-Host ''
    Write-Host '  1) Back up conf and html now'
    Write-Host '  2) Restore conf'
    Write-Host '  3) Restore html'
    Write-Host '  4) Restore both conf and html'
    Write-Host '  b) Back to main menu'
    $c = Read-Menu 'Choice'
    switch ($c) {
        '1' { Backup-ConfHtml -RootPath $Config.Root | Out-Null }
        '2' { Invoke-Restore $Config -Conf }
        '3' { Invoke-Restore $Config -Html }
        '4' { Invoke-Restore $Config -Conf -Html }
        default { }
    }
}
