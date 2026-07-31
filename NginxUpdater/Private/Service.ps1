function Find-NssmPath {
    <#
    .SYNOPSIS
        Locates nssm.exe from a hint, PATH, or common install locations.
    #>
    param([string]$Hint)
    if ($Hint -and (Test-Path -LiteralPath $Hint)) { return (Resolve-Path -LiteralPath $Hint).Path }
    $cmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    foreach ($p in @(
            "$env:ProgramFiles\nssm\win64\nssm.exe",
            "$env:ProgramFiles\nssm\nssm.exe",
            "${env:ProgramFiles(x86)}\nssm\win32\nssm.exe",
            'C:\nssm\nssm.exe')) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Find-ServiceForRoot {
    <#
    .SYNOPSIS
        Finds a Windows service whose binary path points into $RootPath; returns its name or $null.
    #>
    param([string]$RootPath)
    if (-not $script:OnWindows) { return $null }
    try {
        $rootNorm = (Resolve-Path -LiteralPath $RootPath).Path.TrimEnd('\')
        $svc = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            Where-Object {
                $_.PathName -and ($_.PathName -replace '"', '') -like "*$rootNorm*" -and $_.PathName -match 'nginx'
            } |
                Select-Object -First 1
        if ($svc) { return $svc.Name }
    } catch {
        Write-Verbose 'Service enumeration failed.'
    }
    return $null
}

function Get-ServiceStatus {
    <#
    .SYNOPSIS
        Returns the status string of a service, or 'None'/'NotFound'.
    #>
    param([string]$Name)
    if (-not $Name) { return 'None' }
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        return $svc.Status.ToString()   # Running / Stopped / etc.
    } catch {
        return 'NotFound'
    }
}

function Restart-NginxService {
    <#
    .SYNOPSIS
        Restarts the nginx Windows service and reports the resulting status.
    #>
    param([string]$Name)
    if (-not $Name) { throw 'No service name configured.' }
    Write-Info "Restarting service '$Name' ..."
    Restart-Service -Name $Name -Force -ErrorAction Stop
    Start-Sleep -Seconds 1
    $status = Get-ServiceStatus $Name
    if ($status -eq 'Running') { Write-Good "Service '$Name' is Running." }
    else { Write-Warn "Service '$Name' status after restart: $status" }
}

function New-NginxNssmService {
    <#
    .SYNOPSIS
        Creates an NSSM-wrapped nginx Windows service (requires nssm.exe).
    #>
    param([string]$RootPath, [string]$Name, [string]$NssmExe)
    if (-not $NssmExe) { throw 'nssm.exe not found - set it via the Configure menu to create a service.' }
    $exe = Get-NginxExePath $RootPath
    Write-Info "Creating NSSM service '$Name' ..."
    & $NssmExe install $Name $exe '-p' $RootPath | Write-Host
    & $NssmExe set $Name AppDirectory $RootPath | Write-Host
    & $NssmExe set $Name AppStdout (Join-Path $RootPath 'logs\service-stdout.log') | Write-Host
    & $NssmExe set $Name AppStderr (Join-Path $RootPath 'logs\service-stderr.log') | Write-Host
    & $NssmExe set $Name Start SERVICE_AUTO_START | Write-Host
    & $NssmExe set $Name AppStopMethodConsole 5000 | Write-Host
    Write-Good "Service '$Name' created. Start it from the menu when ready."
}
