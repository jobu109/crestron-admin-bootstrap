@{
    # Module identity
    RootModule        = 'CrestronAdminBootstrap.psm1'
    ModuleVersion     = '0.7.3'
    GUID              = 'b3f7c0d2-1e4a-4f5b-9c8d-7a2e1f0c4b6d'
    Author            = 'Michael Floyd'
    CompanyName       = ''
    Copyright         = '(c) Michael Floyd. MIT License.'
    Description       = 'Discover and provision the initial admin account on Crestron 4-Series devices stuck on the create-admin bootup page.'

    # Requirements
    PowerShellVersion = '7.0'

    # Exported commands
    FunctionsToExport = @(
        'Find-CrestronBootup',
        'Set-CrestronAdmin',
        'Test-CrestronAdmin',
        'Connect-CrestronDevice',
        'Disconnect-CrestronDevice',
        'Set-CrestronSettings',
        'Get-CrestronDeviceState',
        'Set-CrestronHostname',
        'Set-CrestronNetwork',
        'Restart-CrestronDevice',
        'Set-CrestronIpTable',
        'Set-CrestronDeviceMode'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # PowerShell Gallery metadata (used later if you ever publish)
    PrivateData = @{
        PSData = @{
            Tags         = @('Crestron', '4-Series', 'AV', 'Provisioning', 'Bootstrap')
            LicenseUri   = 'https://github.com/jobu109/crestron-admin-bootstrap/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/jobu109/crestron-admin-bootstrap'
            ReleaseNotes = 'Initial release.'
        }
    }
}