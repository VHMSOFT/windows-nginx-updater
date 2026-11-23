function Write-Info {
    <#
    .SYNOPSIS
        Writes an informational (cyan) console line.
    #>
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Good {
    <#
    .SYNOPSIS
        Writes a success (green) console line.
    #>
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-Warn {
    <#
    .SYNOPSIS
        Writes a warning (yellow) console line.
    #>
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Err {
    <#
    .SYNOPSIS
        Writes an error (red) console line.
    #>
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

function Write-Head {
    <#
    .SYNOPSIS
        Writes a boxed section header to the console.
    #>
    param([string]$Message)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host " $Message" -ForegroundColor White
    Write-Host ('=' * 70) -ForegroundColor DarkGray
}

function Coalesce {
    <#
    .SYNOPSIS
        Returns the first non-null, non-empty value from the supplied arguments.
    #>
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Values)
    foreach ($v in $Values) { if ($null -ne $v -and "$v" -ne '') { return $v } }
    return $null
}

function Assert-Interactive {
    <#
    .SYNOPSIS
        Throws instead of prompting when running unattended (manager -Action), so a scheduled run can
        never hang waiting for input.
    #>
    param([string]$What)
    if ($script:NonInteractive) { throw "Unattended run cannot prompt ($What)." }
}

function Read-Menu {
    <#
    .SYNOPSIS
        Prompts for and returns a trimmed line of menu input.
    #>
    param([string]$Prompt = 'Select an option')
    Assert-Interactive $Prompt
    return (Read-Host "`n$Prompt").Trim()
}

function Confirm-YesNo {
    <#
    .SYNOPSIS
        Asks a yes/no question and returns the boolean answer.
    #>
    param([string]$Question, [bool]$DefaultYes = $false)
    Assert-Interactive $Question
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $ans = (Read-Host "$Question $suffix").Trim().ToLowerInvariant()
        if ([string]::IsNullOrEmpty($ans)) { return $DefaultYes }
        if ($ans -in 'y', 'yes') { return $true }
        if ($ans -in 'n', 'no') { return $false }
        Write-Warn 'Please answer y or n.'
    }
}
