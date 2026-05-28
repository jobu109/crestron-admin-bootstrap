function Restart-CrestronDevice {
    <#
    .SYNOPSIS
        Reboots a Crestron 4-Series device via the CresNext API.
    .DESCRIPTION
        POSTs {"Device":{"DeviceOperations":{"Reboot":true}}} to
        /Device/DeviceOperations using the authenticated session. The device
        responds quickly and then disconnects — the session is invalid after
        this call.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.
    .PARAMETER TimeoutSec
        Per-request timeout. Default 15.

    .OUTPUTS
        PSCustomObject: IP, Status, Success, Response, Timestamp.

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 172.22.0.21 -Credential $cred
        Restart-CrestronDevice -Session $session
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    $payload = @{
        Device = @{
            DeviceOperations = @{ Reboot = $true }
        }
    }

    $api = Invoke-CrestronApi -Session $Session -Path '/Device/DeviceOperations' `
                              -Method POST -Body $payload -TimeoutSec $TimeoutSec

    # We treat any HTTP 2xx as success because the device often returns before
    # actually finishing its response (it's shutting down).
    $bodyPreview = if ($api.Body) {
        $clean = ($api.Body -replace '\s+', ' ').Trim()
        $clean.Substring(0, [Math]::Min(300, $clean.Length))
    } else { '' }

    [pscustomobject]@{
        IP        = $Session.IP
        Status    = $api.Status
        Success   = $api.Success
        Response  = $bodyPreview
        Timestamp = (Get-Date).ToString('s')
    }
}