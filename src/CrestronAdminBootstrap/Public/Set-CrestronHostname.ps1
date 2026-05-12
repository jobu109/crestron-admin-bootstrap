function Set-CrestronHostname {
    <#
    .SYNOPSIS
        Changes the device hostname on a Crestron 4-Series device.

    .DESCRIPTION
        POSTs a partial NetworkAdapters payload to /Device with only the
        HostName field changed. Lighter than Set-CrestronNetwork when only
        hostname needs to change.

        Validates per RFC 1123 / standard hostname rules: 1-63 chars,
        letters/digits/hyphens, must not start or end with hyphen.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER Hostname
        New hostname. Will be sent verbatim; no domain suffix is appended.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 30.

    .OUTPUTS
        PSCustomObject: IP, Status, Success, SectionResults, Response, Timestamp.

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 172.22.0.21 -Credential $cred
        Set-CrestronHostname -Session $session -Hostname 'CR-101-TS1070'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Hostname,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    # Hostname validation
    if ($Hostname.Length -lt 1 -or $Hostname.Length -gt 63) {
        throw "Hostname must be 1-63 characters. Got $($Hostname.Length)."
    }
    if ($Hostname -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$') {
        throw "Hostname '$Hostname' is invalid. Allowed: letters, digits, hyphens. Must not start or end with a hyphen."
    }

    $payload = @{
        Device = @{
            NetworkAdapters = @{
                HostName = $Hostname
            }
        }
    }

    $api = Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST `
                              -Body $payload -TimeoutSec $TimeoutSec

    # Parse per-section StatusId (same pattern as Set-CrestronSettings)
    $sectionResults = @()
    $overallSuccess = $true

    if ($api.BodyJson -and $api.BodyJson.Actions) {
        foreach ($action in $api.BodyJson.Actions) {
            foreach ($r in @($action.Results)) {
                $rPath = "$($r.Path)$(if ($r.Property) { '.' + $r.Property } else { '' })"
                $sid   = [int]$r.StatusId
                $rOk   = $sid -in 0,1
                if (-not $rOk) { $overallSuccess = $false }
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
        Hostname       = $Hostname
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}