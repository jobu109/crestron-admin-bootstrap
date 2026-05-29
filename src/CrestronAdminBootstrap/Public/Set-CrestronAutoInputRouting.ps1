function Set-CrestronAutoInputRouting {
    <#
    .SYNOPSIS
        Enables or disables Automatic Input Routing on DM-NVX devices that support it.

    .DESCRIPTION
        POSTs Device.AvRouting.AutomaticInputRouting to the device. Only DM-NVX
        models that expose the AvRouting API with AutomaticInputRouting support this.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER Enabled
        True to enable automatic input routing; false to disable.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 30.
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

    # NVX-384 and similar: property is AutoInputRoutingEnabled under DeviceSpecific.
    # Older/other devices: AutomaticInputRouting under AvRouting.
    $payloadDeviceSpecific = @{ Device = @{ DeviceSpecific = @{ AutoInputRoutingEnabled = $Enabled } } }
    $payloadAvRouting      = @{ Device = @{ AvRouting      = @{ AutomaticInputRouting   = $Enabled } } }

    $api = Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST -Body $payloadDeviceSpecific -TimeoutSec $TimeoutSec
    if ($api.Status -eq 0) {
        $api = Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST -Body $payloadAvRouting -TimeoutSec $TimeoutSec
    }

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
                $ok = ($sid -in 0,1,5,-4)
                if (-not $ok) { $overallSuccess = $false }
                if ($sid -eq 1 -or "$($r.StatusInfo)" -match '(?i)reboot|restart|power cycle') { $needsReboot = $true }
                $sectionResults += [pscustomobject]@{
                    Path       = $path
                    StatusId   = $sid
                    StatusInfo = "$($r.StatusInfo)"
                    Ok         = $ok
                }
            }
        }
    }

    if (-not $api.Success) { $overallSuccess = $false }

    $bodyPreview = if ($api.Body) {
        $clean = ($api.Body -replace '\s+', ' ').Trim()
        $clean.Substring(0, [Math]::Min(300, $clean.Length))
    } else { '' }

    [pscustomobject]@{
        IP             = $Session.IP
        Status         = $api.Status
        Success        = $overallSuccess
        Setting        = 'AutomaticInputRouting'
        Enabled        = [bool]$Enabled
        NeedsReboot    = $needsReboot
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}
