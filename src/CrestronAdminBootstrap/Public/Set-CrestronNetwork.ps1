function Set-CrestronNetwork {
    <#
    .SYNOPSIS
        Changes network settings (DHCP/Static, IP, gateway, DNS) and optionally
        toggles adapters on a Crestron 4-Series device.

    .DESCRIPTION
        Builds a partial NetworkAdapters payload and POSTs it to /Device.
        Supports:
          - Switching the EthernetLan adapter to DHCP or to Static
          - Setting static IP, subnet mask, default gateway, DNS servers
          - Disabling the WiFi adapter (sets Wifi.IsAdapterEnabled = false)

        IMPORTANT: When the IP changes, the device drops the current TCP
        connection. This cmdlet is fire-and-forget — a successful HTTP 200
        response means the device acknowledged the request, not that the new
        IP is reachable. The caller should not attempt to reuse $Session
        after a successful IP change.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER IPMode
        'DHCP' or 'Static'. Required.

    .PARAMETER NewIP
        Required when IPMode is 'Static'.

    .PARAMETER SubnetMask
        Required when IPMode is 'Static'. e.g. '255.255.255.0'.

    .PARAMETER Gateway
        Required when IPMode is 'Static'.

    .PARAMETER PrimaryDns
        Optional. Single string, e.g. '8.8.8.8'.

    .PARAMETER SecondaryDns
        Optional. Single string, e.g. '8.8.4.4'.

    .PARAMETER DisableWifi
        When set, additionally disables the WiFi adapter.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 30.

    .OUTPUTS
        PSCustomObject: IP, IPMode, NewIP, Status, Success, SectionResults,
        Response, ConnectionLost (always $true when IPMode=Static and NewIP
        differs from current), Timestamp.

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 172.22.0.21 -Credential $cred
        Set-CrestronNetwork -Session $session `
            -IPMode Static -NewIP 10.10.20.21 -SubnetMask 255.255.255.0 `
            -Gateway 10.10.20.1 -PrimaryDns 8.8.8.8 -DisableWifi
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][ValidateSet('DHCP','Static')][string]$IPMode,
        [string]$NewIP,
        [string]$SubnetMask,
        [string]$Gateway,
        [string]$PrimaryDns,
        [string]$SecondaryDns,
        [switch]$DisableWifi,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    # Validation
    if ($IPMode -eq 'Static') {
        foreach ($f in 'NewIP','SubnetMask','Gateway') {
            if (-not (Get-Variable $f).Value) {
                throw "$f is required when IPMode is Static."
            }
        }
        $ipPattern = '^(\d{1,3}\.){3}\d{1,3}$'
        foreach ($pair in @(@('NewIP',$NewIP),@('SubnetMask',$SubnetMask),@('Gateway',$Gateway))) {
            if ($pair[1] -notmatch $ipPattern) {
                throw "$($pair[0]) '$($pair[1])' is not a valid IPv4 address."
            }
        }
        foreach ($pair in @(@('PrimaryDns',$PrimaryDns),@('SecondaryDns',$SecondaryDns))) {
            if ($pair[1] -and $pair[1] -notmatch $ipPattern) {
                throw "$($pair[0]) '$($pair[1])' is not a valid IPv4 address."
            }
        }
    }

    # Build EthernetLan IPv4 block
    $ipv4 = @{
        IsDhcpEnabled = ($IPMode -eq 'DHCP')
    }
    if ($IPMode -eq 'Static') {
        $ipv4.StaticAddresses = @(@{
            Address    = $NewIP
            SubnetMask = $SubnetMask
        })
        $ipv4.StaticDefaultGateway = $Gateway
    }

    $eth = @{
        IPv4             = $ipv4
        IsAdapterEnabled = $true
    }

    $adapters = @{ EthernetLan = $eth }
    if ($DisableWifi) {
        $adapters.Wifi = @{ IsAdapterEnabled = $false }
    }

    $na = @{
        Adapters = $adapters
    }

    # DNS block (only included when at least one server supplied)
    if ($PrimaryDns -or $SecondaryDns) {
        $dnsList = @()
        $dnsList += if ($PrimaryDns)   { $PrimaryDns }   else { '' }
        $dnsList += if ($SecondaryDns) { $SecondaryDns } else { '' }
        $na.DnsSettings = @{ IPv4 = @{ StaticDns = $dnsList } }
    }

    $payload = @{
        Device = @{
            NetworkAdapters = $na
        }
    }

    $api = Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST `
                              -Body $payload -TimeoutSec $TimeoutSec

    # Parse StatusId per result
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

    # Connection lost flag — IP change means we can't reuse the session
    $connectionLost = $false
    if ($IPMode -eq 'Static' -and $NewIP -and $NewIP -ne $Session.IP) {
        $connectionLost = $true
    } elseif ($IPMode -eq 'DHCP') {
        # DHCP-assigned IP may or may not match — we can't know. Assume yes.
        $connectionLost = $true
    }

    [pscustomobject]@{
        IP             = $Session.IP
        IPMode         = $IPMode
        NewIP          = if ($IPMode -eq 'Static') { $NewIP } else { '<DHCP>' }
        Status         = $api.Status
        Success        = $overallSuccess
        WifiDisabled   = [bool]$DisableWifi
        ConnectionLost = $connectionLost
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}
