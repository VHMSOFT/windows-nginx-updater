function Get-ModeMarkerPath {
    <#
    .SYNOPSIS
        Path to this install's mode marker (a one-word file: 'managed' or 'manager').
    #>
    param([string]$ToolDir)
    return (Join-Path $ToolDir '.nginx-updater-mode')
}

function Resolve-ToolMode {
    <#
    .SYNOPSIS
        Decides the run mode: an explicit -Mode wins, then this install's marker file, else 'managed'.
    #>
    param([string]$Requested)
    if ($Requested) { return $Requested }
    $marker = Get-ModeMarkerPath (Get-ToolDir)
    if (Test-Path -LiteralPath $marker) {
        try {
            $m = (Get-Content -LiteralPath $marker -Raw).Trim().ToLowerInvariant()
            if ($m -in 'managed', 'manager') { return $m }
        } catch {
            Write-Verbose 'Could not read the mode marker.'
        }
    }
    return 'managed'
}

function Set-ToolMode {
    <#
    .SYNOPSIS
        Persists the run mode for this install so later runs need no -Mode argument.
    #>
    param([ValidateSet('managed', 'manager')][string]$Mode)
    try {
        Set-Content -LiteralPath (Get-ModeMarkerPath (Get-ToolDir)) -Value $Mode -Encoding ASCII
    } catch {
        Write-Warn "Could not save the mode ($($_.Exception.Message)); pass -Mode $Mode next time."
    }
}

function Get-RegistryPath {
    <#
    .SYNOPSIS
        Fixed, per-server location of the manager's instance list.
    .DESCRIPTION
        %ProgramData%\NginxUpdater\instances.json, independent of where the manager's own files live,
        so it survives reinstalling or moving the manager.
    #>
    $base = $env:ProgramData
    if (-not $base) { $base = Join-Path $HOME '.nginx-updater' }
    return (Join-Path (Join-Path $base 'NginxUpdater') 'instances.json')
}

function Test-SamePath {
    <#
    .SYNOPSIS
        Case-insensitive comparison of two paths after normalisation.
    #>
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $na = [System.IO.Path]::GetFullPath($A).TrimEnd('\', '/')
    $nb = [System.IO.Path]::GetFullPath($B).TrimEnd('\', '/')
    return ($na -ieq $nb)
}

function Import-Instance {
    <#
    .SYNOPSIS
        Loads the registered managed installs (possibly none) as an array of Root/ToolDir objects.
    #>
    $path = Get-RegistryPath
    $list = @()
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($saved -and $saved.PSObject.Properties.Name -contains 'Instances') {
                foreach ($i in @($saved.Instances)) {
                    if ($i -and $i.Root) {
                        $tool = if ($i.PSObject.Properties.Name -contains 'ToolDir') { $i.ToolDir } else { $null }
                        $list += [pscustomobject]@{ Root = [string]$i.Root; ToolDir = $tool }
                    }
                }
            }
        } catch {
            Write-Warn "Could not read $path ($($_.Exception.Message)); treating the list as empty."
        }
    }
    # Callers wrap the call in @(...) so 0/1 results stay arrays on Windows PowerShell 5.1.
    return $list
}

function Save-Instance {
    <#
    .SYNOPSIS
        Writes the instance list to the registry file (creating its folder).
    #>
    param([object[]]$Instances)
    $path = Get-RegistryPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [pscustomobject]@{
        Instances  = @($Instances | ForEach-Object { [pscustomobject]@{ Root = $_.Root; ToolDir = $_.ToolDir } })
        UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
}
