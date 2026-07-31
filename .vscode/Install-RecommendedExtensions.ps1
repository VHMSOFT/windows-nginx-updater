$extensions = Get-Content "$PSScriptRoot/extensions.json" |
    ConvertFrom-Json |
        Select-Object -ExpandProperty recommendations

for ($i = 0; $i -lt $extensions.count; $i++) {
    $percent = ((($i + 1) / ($extensions.count)) * 100)
    Write-Progress -PercentComplete $percent -Activity "installing Extensions ($percent%)" -Status $extensions[$i]
    code --install-extension $extensions[$i] | Out-Null
}
