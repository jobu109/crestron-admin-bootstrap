function Get-CrestronDeviceState {
    <#
    .SYNOPSIS
        Retrieves the current device state (hostname, network, adapters) from a
        connected Crestron 4-Series device.

    .DESCRIPTION
        GETs /Device/NetworkAdapters using the authenticated session and returns
        a flattened state object covering hostname, the EthernetLan adapter IPv4
        config, DNS, and adapter-enabled flags for both EthernetLan and Wifi.

        Used by the GUI's Per-Device tab to pre-fill the grid and by the WiFi
        safety check before disabling an adapter.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 15.

    .OUTPUTS
        PSCustomObject with:
          IP, Hostname, EthernetLanEnabled, EthernetLanDhcp, EthernetLanIP,
          EthernetLanSubnet, EthernetLanGateway, DomainName, DnsServers,
          WifiEnabled, WifiIP, RawJson

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 172.22.0.21 -Credential $cred
        Get-CrestronDeviceState -Session $session
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    $api = Invoke-CrestronApi -Session $Session -Path '/Device/NetworkAdapters' `
                              -Method GET -TimeoutSec $TimeoutSec

    if (-not $api.Success) {
        throw "GET /Device/NetworkAdapters on $($Session.IP) failed with HTTP $($api.Status)."
    }
    if (-not $api.BodyJson) {
        throw "GET /Device/NetworkAdapters on $($Session.IP) returned no parseable JSON."
    }

    $na   = $api.BodyJson.Device.NetworkAdapters
    $eth  = $na.Adapters.EthernetLan
    $wifi = $na.Adapters.Wifi

    # Pull the first IPv4 address reported as 'current' (vs configured static)
    $ethCurrentIp = $null
    if ($eth -and $eth.IPv4 -and $eth.IPv4.Addresses) {
        $first = @($eth.IPv4.Addresses)[0]
        if ($first -and $first.Address) { $ethCurrentIp = $first.Address }
    }
    $wifiCurrentIp = $null
    if ($wifi -and $wifi.IPv4 -and $wifi.IPv4.Addresses) {
        $first = @($wifi.IPv4.Addresses)[0]
        if ($first -and $first.Address) { $wifiCurrentIp = $first.Address }
    }

    # Static IP / subnet (configured, not necessarily currently active)
    $ethStaticIp = $null; $ethStaticMask = $null
    if ($eth -and $eth.IPv4 -and $eth.IPv4.StaticAddresses) {
        $sa = @($eth.IPv4.StaticAddresses)[0]
        if ($sa) {
            $ethStaticIp   = $sa.Address
            $ethStaticMask = $sa.SubnetMask
        }
    }

    $dnsServers = @()
    if ($na.DnsSettings -and $na.DnsSettings.IPv4 -and $na.DnsSettings.IPv4.StaticDns) {
        $dnsServers = @($na.DnsSettings.IPv4.StaticDns | Where-Object { $_ -and $_.Trim() -ne '' })
    }

# Whether the device actually has a WiFi adapter at all. NetworkAdapters
    # devices like DM-NVX-360C don't, and trying to set Wifi.IsAdapterEnabled
    # on them produces an "unsupported property" failure.
    $hasWifi = [bool]$wifi

    [pscustomobject]@{
        IP                  = $Session.IP
        Hostname            = $na.HostName
        DomainName          = $eth.DomainName
        EthernetLanEnabled  = [bool]$eth.IsAdapterEnabled
        EthernetLanDhcp     = [bool]$eth.IPv4.IsDhcpEnabled
        EthernetLanIP       = $ethCurrentIp
        EthernetLanStaticIP = $ethStaticIp
        EthernetLanSubnet   = $ethStaticMask
        EthernetLanGateway  = $eth.IPv4.StaticDefaultGateway
        DnsServers          = $dnsServers
        HasWifi             = $hasWifi
        WifiEnabled         = [bool]$wifi.IsAdapterEnabled
        WifiIP              = $wifiCurrentIp
        RawJson             = $api.BodyJson
        FetchedAt           = (Get-Date).ToString('s')
    }
}