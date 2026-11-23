function Test-Admin {
    <#
    .SYNOPSIS
        Returns $true when the current process is elevated (Administrator) on Windows.
    #>
    if (-not $script:OnWindows) { return $false }
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-Admin {
    <#
    .SYNOPSIS
        Ensures the process is elevated, offering to relaunch elevated when it is not.
    .DESCRIPTION
        Relaunch details come from $script:Invocation, populated by Invoke-NginxUpdater, because a
        module function cannot see the caller's local parameters the way a plain script scope could.
    #>
    param([string]$ForAction = 'this operation')
    if (Test-Admin) { return $true }
    Write-Warn "Administrator rights are required for $ForAction (symlinks + service control)."
    if (-not $script:OnWindows) {
        Write-Err 'Not running on Windows - cannot elevate here.'
        return $false
    }
    if (-not (Confirm-YesNo 'Relaunch this tool in an elevated window now?' $true)) { return $false }

    $inv = $script:Invocation
    $launcher = $PSCommandPath
    if ($inv.ContainsKey('LauncherPath') -and $inv['LauncherPath']) { $launcher = $inv['LauncherPath'] }
    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$launcher`"")
    foreach ($name in 'Root', 'NssmPath', 'ServiceName', 'Channel', 'Mode') {
        $value = if ($inv.ContainsKey($name)) { $inv[$name] } else { $null }
        if ($value) { $argList += @("-$name", "`"$value`"") }
    }
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList | Out-Null
    Write-Info 'An elevated window has been opened. You can close this one.'
    return $false
}
