function Get-ConfigPath {
    <#
    .SYNOPSIS
        Returns the path to the per-root config JSON file.
    #>
    param([string]$RootPath)
    return (Join-Path $RootPath $script:ConfigFileName)
}

function Import-Config {
    <#
    .SYNOPSIS
        Loads (or initialises) the per-root config as a hashtable, merging any saved values.
    .DESCRIPTION
        Seed defaults (ServiceName / NssmPath / Channel) are passed in explicitly rather than read
        from an outer scope, so the function is self-contained inside the module.
    #>
    param(
        [string]$RootPath,
        [hashtable]$Defaults = @{}
    )
    # Plain hashtable (not [ordered]) so it passes by reference to [hashtable] params -
    # mutations inside operations propagate back to the caller instead of hitting a copy.
    $cfg = @{
        Root          = $RootPath
        ServiceName   = if ($Defaults.ContainsKey('ServiceName')) { $Defaults['ServiceName'] } else { $null }
        NssmPath      = if ($Defaults.ContainsKey('NssmPath')) { $Defaults['NssmPath'] } else { $null }
        Channel       = if ($Defaults.ContainsKey('Channel')) { $Defaults['Channel'] } else { 'ask' }
        ActiveVersion = $null
    }
    $path = Get-ConfigPath $RootPath
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($k in @('ServiceName', 'NssmPath', 'Channel', 'ActiveVersion')) {
                if ($saved.PSObject.Properties.Name -contains $k -and $saved.$k -and -not $cfg[$k]) {
                    $cfg[$k] = $saved.$k
                }
            }
        } catch {
            Write-Warn "Could not read $path ($($_.Exception.Message)); using defaults."
        }
    }
    if (-not $cfg.Channel) { $cfg.Channel = 'ask' }
    return $cfg
}

function Get-NsnssmcmSettings {
    <#
    .SYNOPSIS
        Reads service settings from an nsnssmcm.json sitting next to the nginx root's nginx.exe.
    .DESCRIPTION
        NSNSSMCM (nsnssmcm.ps1) records each service in <folder>\nsnssmcm.json - a single service
        object, or an array of them. When that file exists in the nginx root, it is the source of
        truth for the service name and nssm.exe location, so the updater does not ask for them.
        Returns $null when there is no usable file, else a hashtable: Path, ServiceName, NssmPath
        (NssmPath is $null if no nssm.exe is found in the root or any parent folder).
    #>
    param([string]$RootPath)
    $file = Join-Path $RootPath 'nsnssmcm.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $entries = @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) | Where-Object { $_ -and $_.Name }
    } catch {
        Write-Warn "Could not read $file ($($_.Exception.Message)); ignoring it."
        return $null
    }
    if (-not $entries) { return $null }

    $rootNorm = $RootPath.TrimEnd('\', '/')
    $entry = @($entries | Where-Object { $_.Application -match '(^|[\\/])nginx(\.exe)?$' }) | Select-Object -First 1
    if (-not $entry) {
        $entry = @($entries | Where-Object { $_.AppDirectory -and $_.AppDirectory.TrimEnd('\', '/') -ieq $rootNorm }) | Select-Object -First 1
    }
    if (-not $entry -and @($entries).Count -eq 1) { $entry = @($entries)[0] }
    if (-not $entry) {
        Write-Warn "$file has no service entry for nginx; ignoring it."
        return $null
    }

    # nssm.exe lives in the install root above the service folders (e.g. C:\VHM_Install\nssm.exe).
    $nssm = $null
    $dir = $RootPath
    while ($dir) {
        $candidate = Join-Path $dir 'nssm.exe'
        if (Test-Path -LiteralPath $candidate) { $nssm = $candidate; break }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return @{ Path = $file; ServiceName = [string]$entry.Name; NssmPath = $nssm }
}

function Use-NsnssmcmSettings {
    <#
    .SYNOPSIS
        Overrides the config's service name / nssm path from nsnssmcm.json when present.
    .DESCRIPTION
        Sets $Config.ExternalConfig to the json path (which locks manual configuration) and
        returns $true; returns $false and leaves the config untouched if there is no file.
    #>
    param([hashtable]$Config)
    $s = Get-NsnssmcmSettings $Config.Root
    if (-not $s) { $Config.ExternalConfig = $null; return $false }
    $Config.ServiceName = $s.ServiceName
    if ($s.NssmPath) { $Config.NssmPath = $s.NssmPath }
    $Config.ExternalConfig = $s.Path
    return $true
}

function Save-Config {
    <#
    .SYNOPSIS
        Persists the config hashtable to the per-root config JSON file.
    #>
    param([hashtable]$Config)
    $path = Get-ConfigPath $Config.Root
    try {
        [pscustomobject]@{
            Root          = $Config.Root
            ServiceName   = $Config.ServiceName
            NssmPath      = $Config.NssmPath
            Channel       = $Config.Channel
            ActiveVersion = if ($Config.ContainsKey('ActiveVersion')) { $Config.ActiveVersion } else { $null }
            UpdatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {
        Write-Warn "Could not save config to $path ($($_.Exception.Message))."
    }
}
