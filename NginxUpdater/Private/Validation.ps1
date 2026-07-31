function Test-NginxConfig {
    <#
    .SYNOPSIS
        Runs "<versionExe> -t -p <root>" to validate the live config against a given binary.
    #>
    param([string]$RootPath, [string]$Version)
    $exe = Join-Path (Join-Path (Join-Path $RootPath $script:VersionsDir) $Version) 'nginx.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Warn "Binary for $Version not found; skipping config test."
        return $true
    }
    Write-Info "Testing config with nginx $Version ..."
    $out = & $exe -t -p $RootPath 2>&1 | Out-String
    Write-Host $out.Trim()
    if ($out -match 'test is successful') { Write-Good "Config OK with $Version."; return $true }
    Write-Warn 'Config test did not report success - review the output above.'
    return $false
}
