function Set-CrestronIpTable {
    <#
    .SYNOPSIS
        Sets the Control-System IP Table entry on a Crestron 4-Series device.

    .DESCRIPTION
        POSTs Device.IpTableV2 as a partial CresNext object. This is the
        slave-side IP table the device uses to find its master control system
        (see the "Control System" section of the device's web UI).

        v0.6.0 supports a single entry per device — the most common deployment
        case. The supplied entry REPLACES any existing entries (per the
        EntriesCurrentKeyList semantics in Crestron's SDK).

        Schema reference:
          https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/IpTableV2.htm

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER IpId
        IP-ID for this device on the control system, as hex (1..FE).
        Examples: "3", "0A", "1F". Case-insensitive.

    .PARAMETER ControlSystemAddress
        IPv4 address or hostname of the master control system (e.g.
        "10.10.20.1" or "cp4-rack1").

    .PARAMETER EncryptConnection
        Whether the CIP link to the control system is encrypted. Defaults to
        $false to match how most installs are commissioned. Set $true only
        if the control system is also configured for encrypted CIP.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 30.

    .OUTPUTS
        PSCustomObject: IP, Status, Success, IpId, ControlSystemAddress,
        SectionResults, Response, Timestamp.

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 172.22.0.50 -Credential $cred
        Set-CrestronIpTable -Session $session `
            -IpId 5 -ControlSystemAddress 10.10.20.1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$IpId,
        [Parameter(Mandatory)][string]$ControlSystemAddress,
        [bool]$EncryptConnection = $false,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    # Normalize and validate IpId. Crestron's API uses uppercase hex with NO
    # leading zero on single-byte values (e.g. "3" not "03", "F" not "0F"), and
    # bare hex like "10" or "1F" for higher values. Strip leading zeros after
    # validation so our Entries dict key matches the EntriesCurrentKeyList key
    # the device normalizes to internally.
    $ipIdNormalized = $IpId.Trim().ToUpperInvariant()
    if ($ipIdNormalized -notmatch '^[0-9A-F]{1,2}$') {
        throw "IpId '$IpId' must be 1-2 hex digits (1..FE)."
    }
    $ipIdInt = [Convert]::ToInt32($ipIdNormalized, 16)
    if ($ipIdInt -lt 1 -or $ipIdInt -gt 254) {
        throw "IpId '$IpId' decodes to $ipIdInt; allowed range is 1..FE (1..254)."
    }
    # Normalize to no-leading-zero hex
    $ipIdNormalized = '{0:X}' -f $ipIdInt

    # Validate address (IPv4 OR DNS-style hostname; we don't resolve)
    $addr = $ControlSystemAddress.Trim()
    if (-not $addr) { throw "ControlSystemAddress is required." }
    $isIpv4     = $addr -match '^(\d{1,3}\.){3}\d{1,3}$'
    $isHostname = $addr -match '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$'
    if (-not ($isIpv4 -or $isHostname)) {
        throw "ControlSystemAddress '$addr' is not a valid IPv4 address or hostname."
    }

    # Build the single-entry payload. Note: on DM-NVX firmware v2.0.0 the device
    # discards Type, Port, ConnectionType, Description and only persists IpId,
    # Address. Sending the full SDK shape anyway is safe on  # firmware that does accept it.
    $entry = @{
        IpId           = $ipIdNormalized
        Address        = $addr
        Type           = 'Peer'
        Port           = 50
        ConnectionType = 'Gateway'
    }

    $entries = @{}
    $entries[$ipIdNormalized] = $entry

    $payload = @{
        Device = @{
            IpTableV2 = @{
                EncryptConnection     = [bool]$EncryptConnection
                EntriesCurrentKeyList = @($ipIdNormalized)
                Entries               = $entries
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
                $rOk   = $sid -in 0,1,5,-4
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
        IP                   = $Session.IP
        Status               = $api.Status
        Success              = $overallSuccess
        IpId                 = $ipIdNormalized
        ControlSystemAddress = $addr
        EncryptConnection    = [bool]$EncryptConnection
        SectionResults       = $sectionResults
        Response             = $bodyPreview
        Timestamp            = (Get-Date).ToString('s')
    }
}
