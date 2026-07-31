function Get-NginxExePath {
    <#
    .SYNOPSIS
        Returns the path to the root nginx.exe (the symlink, on a managed install).
    #>
    param([string]$RootPath)
    return (Join-Path $RootPath 'nginx.exe')
}

function Test-IsSymlink {
    <#
    .SYNOPSIS
        Returns $true when the given path is a symbolic link or junction (reparse point).
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSObject.Properties.Name -contains 'LinkType' -and $item.LinkType) {
            return $item.LinkType -in 'SymbolicLink', 'Junction'
        }
        # Fallback: reparse-point attribute
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Get-SymlinkTarget {
    <#
    .SYNOPSIS
        Resolves a symlink's target path (native on PS7, via fsutil on Windows PowerShell 5.1).
    #>
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSObject.Properties.Name -contains 'Target' -and $item.Target) {
            return @($item.Target)[0]
        }
    } catch {
        Write-Verbose 'Could not read link target via Get-Item; trying fsutil.'
    }
    if ($script:OnWindows) {
        try {
            $out = & cmd.exe /c "fsutil reparsepoint query `"$Path`"" 2>$null
            foreach ($ln in $out) {
                if ($ln -match 'Print Name:\s*(.+?)\s*$' -and $Matches[1]) { return $Matches[1].Trim() }
            }
            foreach ($ln in $out) {
                if ($ln -match 'Substitute Name:\s*(.+?)\s*$' -and $Matches[1]) {
                    return ($Matches[1].Trim() -replace '^\\\?\?\\', '')
                }
            }
        } catch {
            Write-Verbose 'fsutil reparsepoint query failed; target left unresolved.'
        }
    }
    return $null
}

function Get-RootState {
    <#
    .SYNOPSIS
        Classifies a root folder as Empty, Manual, Managed or Unknown and returns details.
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
    <#
    .SYNOPSIS
        Returns the version folder names staged under <root>\versions\, sorted ascending.
    #>
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
    <#
    .SYNOPSIS
        Determines the active nginx version for a managed install (config first, then fallbacks).
    #>
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
        } catch {
            Write-Verbose 'Could not parse a version from the link target.'
        }
    }
    # Last resort: a single staged version must be the active one.
    $installed = Get-InstalledVersions $Config.Root
    if ($installed.Count -eq 1) { return $installed[0] }
    return $null
}

function Get-ExeVersionString {
    <#
    .SYNOPSIS
        Runs "<exe> -v" and returns the parsed nginx version string, or $null.
    #>
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $out = & $ExePath -v 2>&1 | Out-String
        if ($out -match 'nginx/([0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
    } catch {
        Write-Verbose "Could not run '$ExePath -v'."
    }
    return $null
}
