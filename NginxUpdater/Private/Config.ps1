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
