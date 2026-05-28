function Set-CrestronAvFrameworkSettings {
    <#
    .SYNOPSIS
        Enables or disables AV Framework when the device exposes that setting.

    .DESCRIPTION
        Detects the device's AV Framework object and builds a partial /Device
        payload using the property names already exposed by the device whenever
        possible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][bool]$Enabled,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    $avFramework = Get-CrestronAvFrameworkObject -Session $Session -TimeoutSec $TimeoutSec
    if (-not $avFramework) {
        throw "Device $($Session.IP) does not expose supported AV Framework settings."
    }

    $allowGeneric = @((Get-CrestronAvFrameworkSectionNames) | Where-Object { $_ -ieq "$($avFramework.PathName)" }).Count -gt 0
    $current = Get-CrestronAvFrameworkBoolValue -Object $avFramework.Object -AllowGeneric:$allowGeneric
    if ($null -eq $current) {
        throw "Device $($Session.IP) exposes an AV Framework object, but no readable enablement value was found."
    }

    $deviceBody = @{}
    $appliedSections = @()

    if ([bool]$avFramework.IsDirectProperty) {
        Set-CrestronDisplayBooleanMember `
            -Target $deviceBody `
            -Existing $avFramework.Object `
            -Names (Get-CrestronAvFrameworkPropertyNames) `
            -DefaultName 'AVFrameworkEnabled' `
            -Value ([bool]$Enabled)
        $appliedSections += $avFramework.PathName
    }
    else {
        $sectionBody = @{}
        Set-CrestronDisplayBooleanMemberDeep `
            -Target $sectionBody `
            -Existing $avFramework.Object `
            -SectionNames (Get-CrestronAvFrameworkSectionNames) `
            -Names @((Get-CrestronAvFrameworkPropertyNames) + @('IsEnabled','Enabled','Enable')) `
            -DefaultName 'AVFrameworkEnabled' `
            -Value ([bool]$Enabled)

        $deviceBody[$avFramework.PathName] = $sectionBody
        $appliedSections += $avFramework.PathName
    }

    $payload = @{ Device = $deviceBody }
    $requestPayload = try {
        $payload | ConvertTo-Json -Depth 12 -Compress
    }
    catch {
        ''
    }

    $api = Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST -Body $payload -TimeoutSec $TimeoutSec

    $sectionResults = @()
    $overallSuccess = $api.Success
    $needsReboot = $false

    if ($api.BodyJson -and $api.BodyJson.Actions) {
        foreach ($action in @($api.BodyJson.Actions)) {
            foreach ($r in @($action.Results)) {
                $path = "$($r.Path)"
                if ($r.Property -and $path -notmatch "\.$([regex]::Escape("$($r.Property)"))$") {
                    $path = "$path.$($r.Property)"
                }

                $sid = [int]$r.StatusId
                $ok = $sid -in 0,1,5,-4
                if (-not $ok) {
                    $overallSuccess = $false
                }

                if ($sid -eq 1 -or "$($r.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
                    $needsReboot = $true
                }

                $sectionResults += [pscustomobject]@{
                    Path       = $path
                    StatusId   = $sid
                    StatusInfo = "$($r.StatusInfo)"
                    Ok         = $ok
                }
            }
        }
    }

    if (-not $api.Success) {
        $overallSuccess = $false
    }

    $bodyPreview = if ($api.Body) {
        $clean = ($api.Body -replace '\s+', ' ').Trim()
        $clean.Substring(0, [Math]::Min(300, $clean.Length))
    }
    else {
        ''
    }

    [pscustomobject]@{
        IP             = $Session.IP
        Status         = $api.Status
        Success        = $overallSuccess
        Setting        = 'AVFramework'
        Enabled        = [bool]$Enabled
        CurrentEnabled = [bool]$current
        Path           = "$($avFramework.Path)"
        AppliedSections = @($appliedSections | Select-Object -Unique)
        NeedsReboot    = $needsReboot
        SectionResults = $sectionResults
        Response       = $bodyPreview
        RequestPath    = '/Device'
        RequestPayload = $requestPayload
        Timestamp      = (Get-Date).ToString('s')
    }
}
