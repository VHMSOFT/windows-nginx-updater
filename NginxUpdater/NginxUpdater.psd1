@{
    RootModule        = 'NginxUpdater.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'c6f40699-0ab9-4fe4-9223-887c238c2f1e'
    Author            = 'J-F'
    Description       = 'Windows nginx lifecycle manager: versioned installs via a nginx.exe symlink, with scaffold / migrate / update / rollback and an NSSM-aware restart prompt. Windows PowerShell 5.1 compatible.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-NginxUpdater')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('nginx', 'Windows', 'NSSM', 'symlink', 'deployment')
        }
    }
}
