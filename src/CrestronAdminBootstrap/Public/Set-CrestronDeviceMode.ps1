function Set-CrestronDeviceMode {
    <#
    .SYNOPSIS
        Sets a DM-NVX device's encoder/decoder operating mode.

    .DESCRIPTION
        POSTs Device.DeviceSpecific.DeviceMode to the device. Valid values
        are "Transmitter" (encoder) and "Receiver" (decoder). Only DM-NVX
        models with dual-mode capability accept this; fixed-purpose units
        will return StatusId=3 (unsupported property).

        The device reports StatusId=1 ("reboot needed") on success, since
        the mode change does not take effect until the next boot.

        Schema reference:
          https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/DeviceSpecific.htm

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER Mode
        "Transmitter" or "Receiver".

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 30.

    .OUTPUTS
        PSCustomObject: IP, Status, Success, Mode, NeedsReboot,
        SectionResults, Response, Timestamp.

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 192.168.20.10 -Credential $cred
        Set-CrestronDeviceMode -Session $session -Mode Transmitter
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][ValidateSet('Transmitter','Receiver')][string]$Mode,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    $payload = @{
        Device = @{
            DeviceSpecific = @{
                DeviceMode = $Mode
            }
        }
    }

    $api = Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST `
                              -Body $payload -TimeoutSec $TimeoutSec

    $sectionResults = @()
    $overallSuccess = $true
    $needsReboot    = $false

    if ($api.BodyJson -and $api.BodyJson.Actions) {
        foreach ($action in $api.BodyJson.Actions) {
            foreach ($r in @($action.Results)) {
                $rPath = "$($r.Path)$(if ($r.Property) { '.' + $r.Property } else { '' })"
                $sid   = [int]$r.StatusId
                $rOk   = $sid -in 0,1,5,-4
                if (-not $rOk) { $overallSuccess = $false }
                if ($sid -eq 1) { $needsReboot = $true }
                $sectionResults += [pscustomobject]@{
                    Path       = $rPath
                    StatusId   = $sid
                    StatusInfo = $r.StatusInfo
                    Ok         = $rOk
                }
            }
        }
    } else {
        $overallSuccess = $api.Success
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
        Mode           = $Mode
        NeedsReboot    = $needsReboot
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}