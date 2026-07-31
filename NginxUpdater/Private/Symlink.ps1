function Set-ActiveVersionLink {
    <#
    .SYNOPSIS
        Points <root>\nginx.exe at <root>\versions\<ver>\nginx.exe.
    .DESCRIPTION
        Recreating the link is safe while nginx is running (the link object is not the locked file).
        Prefers New-Item and falls back to cmd mklink for maximum Windows/PowerShell coverage.
    #>
    param([string]$RootPath, [string]$Version)

    $link = Get-NginxExePath $RootPath
    $targetExe = Join-Path (Join-Path (Join-Path $RootPath $script:VersionsDir) $Version) 'nginx.exe'
    if (-not (Test-Path -LiteralPath $targetExe)) { throw "Target binary not found: $targetExe" }

    if (Test-Path -LiteralPath $link) {
        if (Test-IsSymlink $link) {
            Remove-Item -LiteralPath $link -Force
        } else {
            throw "$link exists and is NOT a symlink. Refusing to overwrite a real file - migrate first."
        }
    }
    # Prefer New-Item (works on PS7 and modern 5.1); fall back to cmd mklink, which is available
    # on every Windows version and PowerShell edition. Both need admin or Developer Mode.
    $made = $false
    try {
        New-Item -ItemType SymbolicLink -Path $link -Target $targetExe -ErrorAction Stop | Out-Null
        $made = $true
    } catch {
        Write-Warn "New-Item symlink failed ($($_.Exception.Message)); trying mklink."
    }
    if (-not $made) {
        if (-not $script:OnWindows) { throw 'Cannot create a symlink off-Windows.' }
        $out = & cmd.exe /c "mklink `"$link`" `"$targetExe`"" 2>&1 | Out-String
        if (-not (Test-Path -LiteralPath $link)) { throw "mklink failed: $($out.Trim())" }
    }
    Write-Good "Active nginx.exe -> versions\$Version\nginx.exe"
}
