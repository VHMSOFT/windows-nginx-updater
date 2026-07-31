function Get-AvailableVersions {
    <#
    .SYNOPSIS
        Parses nginx.org and returns the latest stable and mainline Windows versions.
    .DESCRIPTION
        Rule: stable = highest version with an EVEN minor; mainline = highest with an ODD minor.
    #>
    Write-Info "Querying $script:DownloadPage ..."
    try {
        $resp = Invoke-WebRequest -Uri $script:DownloadPage -UseBasicParsing -TimeoutSec 30
        $html = $resp.Content
    } catch {
        throw "Could not fetch the nginx download page: $($_.Exception.Message)"
    }

    $zipMatches = [regex]::Matches($html, 'nginx-([0-9]+)\.([0-9]+)\.([0-9]+)\.zip')
    if ($zipMatches.Count -eq 0) {
        throw 'No nginx Windows builds found on the download page (page format may have changed).'
    }

    $versions = @{}
    foreach ($m in $zipMatches) {
        $v = [version]('{0}.{1}.{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
        $versions[$v.ToString()] = $v
    }
    $all = $versions.Values | Sort-Object

    $stable = ($all | Where-Object { ($_.Minor % 2) -eq 0 } | Select-Object -Last 1)
    $mainline = ($all | Where-Object { ($_.Minor % 2) -eq 1 } | Select-Object -Last 1)

    return [pscustomobject]@{
        Stable   = if ($stable) { $stable.ToString() } else { $null }
        Mainline = if ($mainline) { $mainline.ToString() } else { $null }
        All      = ($all | ForEach-Object { $_.ToString() })
    }
}

function Resolve-TargetVersion {
    <#
    .SYNOPSIS
        Resolves the version to install from the channel preference (may prompt when 'ask').
    #>
    param([string]$ChannelPref)
    $avail = Get-AvailableVersions
    Write-Host ''
    Write-Host ('  Stable   : {0}' -f (Coalesce $avail.Stable 'n/a')) -ForegroundColor Green
    Write-Host ('  Mainline : {0}' -f (Coalesce $avail.Mainline 'n/a')) -ForegroundColor Green

    $pick = $ChannelPref
    if ($pick -eq 'ask' -or [string]::IsNullOrEmpty($pick)) {
        Write-Host ''
        Write-Host "  1) Stable   ($($avail.Stable))"
        Write-Host "  2) Mainline ($($avail.Mainline))"
        Write-Host '  3) Enter a specific version'
        $c = Read-Menu 'Channel'
        switch ($c) {
            '1' { return $avail.Stable }
            '2' { return $avail.Mainline }
            '3' {
                $v = (Read-Host 'Version (e.g. 1.30.4)').Trim()
                if ($v -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "Invalid version format: '$v'." }
                return $v
            }
            default { throw 'Cancelled.' }
        }
    }
    if ($pick -eq 'stable') { return $avail.Stable }
    if ($pick -eq 'mainline') { return $avail.Mainline }
    throw "Unknown channel '$ChannelPref'."
}

function Get-NginxZip {
    <#
    .SYNOPSIS
        Downloads nginx-<ver>.zip to a temp path (verifying the PGP signature if gpg is present).
    #>
    param([string]$Version)
    $url = "$script:DownloadBase/nginx-$Version.zip"
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "nginx-$Version-$suffix.zip"
    Write-Info "Downloading $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
    } catch {
        throw "Download failed for $url : $($_.Exception.Message)"
    }
    $size = (Get-Item -LiteralPath $tmp).Length
    if ($size -lt 100KB) { throw "Downloaded file is suspiciously small ($size bytes)." }
    Write-Good ('Downloaded {0:N1} MB.' -f ($size / 1MB))

    # Best-effort PGP signature verification (nginx publishes nginx-<ver>.zip.asc).
    $gpg = Get-Command gpg -ErrorAction SilentlyContinue
    if ($gpg) {
        try {
            $asc = "$tmp.asc"
            Invoke-WebRequest -Uri "$url.asc" -OutFile $asc -UseBasicParsing -TimeoutSec 30
            $verify = & $gpg.Path --verify $asc $tmp 2>&1 | Out-String
            if ($verify -match 'Good signature') {
                Write-Good 'PGP signature verified.'
            } else {
                Write-Warn 'PGP signature NOT verified (import the nginx signing key to enable this). Continuing.'
            }
            Remove-Item -LiteralPath $asc -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Could not verify PGP signature ($($_.Exception.Message)). Continuing over HTTPS."
        }
    } else {
        Write-Warn 'gpg not found - skipping signature verification (download was over HTTPS).'
    }
    return $tmp
}

function Install-VersionFiles {
    <#
    .SYNOPSIS
        Extracts a downloaded zip into <root>\versions\<ver>\ and returns that folder path.
    .DESCRIPTION
        Does NOT touch the root conf/ or html/.
    #>
    param([string]$RootPath, [string]$Version, [string]$ZipPath)

    $versionsRoot = Join-Path $RootPath $script:VersionsDir
    $target = Join-Path $versionsRoot $Version
    if (Test-Path -LiteralPath (Join-Path $target 'nginx.exe')) {
        Write-Warn "Version $Version already present at $target - reusing it."
        return $target
    }

    New-Item -ItemType Directory -Path $versionsRoot -Force | Out-Null
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "nginx-extract-$suffix"
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $staging -Force
        # Zip contains a single top folder "nginx-<ver>".
        $top = Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1
        if (-not $top) { throw 'Unexpected archive layout - no top-level folder found.' }
        if (-not (Test-Path -LiteralPath (Join-Path $top.FullName 'nginx.exe'))) {
            throw 'Archive does not contain nginx.exe.'
        }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        # Copy the full distribution for this version (binary + its default conf/html/docs for reference).
        Copy-Item -Path (Join-Path $top.FullName '*') -Destination $target -Recurse -Force
        Write-Good "Staged nginx $Version -> $target"
        return $target
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
