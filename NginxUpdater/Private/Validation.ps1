function Test-NginxConfig {
    <#
    .SYNOPSIS
        Runs "nginx -t -p <root>" to validate the live config against a chosen binary.
    .DESCRIPTION
        With -Version, tests that staged build's binary (used before activating an upgrade).
        Without -Version, tests the active root nginx.exe (the current symlink). Returns $true only
        when nginx reports the test successful; $false on any failure.
    #>
    param([string]$RootPath, [string]$Version)
    if ($Version) {
        $exe = Join-Path (Join-Path (Join-Path $RootPath $script:VersionsDir) $Version) 'nginx.exe'
        $label = "nginx $Version"
    } else {
        $exe = Get-NginxExePath $RootPath
        $label = 'the active nginx.exe'
    }
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Warn "Binary not found ($exe); skipping config test."
        return $true
    }
    Write-Info "Testing config with $label ..."
    # nginx -t is authoritative via its EXIT CODE (0 = ok). Do NOT parse the text: nginx prints
    # "syntax is ok" on the first line even when a later [emerg] makes the overall test fail.
    # nginx writes its normal output to stderr; under $ErrorActionPreference='Stop' (set by the
    # caller) `2>&1` would turn that into a terminating error, so relax it for this native call.
    $ErrorActionPreference = 'Continue'
    $out = & $exe -t -p $RootPath 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Host $out.Trim()
    if ($code -eq 0) {
        Write-Good "Config OK with $label."
        return $true
    }
    Write-Warn "Config test FAILED (nginx -t exit code $code) - review the output above."
    return $false
}
