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

    # Also fetch IpTableV2 (Control System binding). Best-effort: some firmware
    # exposes only the older IpTable object; failures here don't break the call.
        $deviceSpecificJson = $null
    try {
        $dsApi = Invoke-CrestronApi -Session $Session -Path '/Device/DeviceSpecific' `
                                    -Method GET -TimeoutSec $TimeoutSec
        if ($dsApi.Success -and $dsApi.BodyJson) {
            $deviceSpecificJson = $dsApi.BodyJson.Device.DeviceSpecific
        }
    } catch { }
    try {
        $ipApi = Invoke-CrestronApi -Session $Session -Path '/Device/IpTableV2' `
                                    -Method GET -TimeoutSec $TimeoutSec
        if ($ipApi.Success -and $ipApi.BodyJson) {
            $ipTableJson = $ipApi.BodyJson.Device.IpTableV2
        }
    } catch { }
    if (-not $ipTableJson) {
        try {
            $ipApi = Invoke-CrestronApi -Session $Session -Path '/Device/IpTable' `
                                        -Method GET -TimeoutSec $TimeoutSec
            if ($ipApi.Success -and $ipApi.BodyJson) {
                $ipTableJson = $ipApi.BodyJson.Device.IpTable
            }
        } catch { }
    }

$na = $api.BodyJson.Device.NetworkAdapters

    # The Adapters dict is keyed by an arbitrary per-device adapter name
    # (e.g. "EthernetLan" on DM-NVX-D30, "Vlan00" on DM-NVX-360, etc.).
    # Find the first active+enabled IPv4 adapter to treat as "ethernet"
    # and (separately) any adapter with WiFi-flavored naming for the WiFi slot.
    $eth = $null
    $wifi = $null
    if ($na.Adapters) {
        $adapterProps = @($na.Adapters | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue)
        foreach ($p in $adapterProps) {
            $a = $na.Adapters.$($p.Name)
            $isWifi = $p.Name -match 'Wifi|Wireless|Wlan'
            if ($isWifi -and -not $wifi) {
                $wifi = $a
            } elseif (-not $isWifi -and -not $eth -and $a.IPv4) {
                # Prefer active+enabled, but accept any IPv4-capable adapter as fallback
                if (($a.IsActive -and $a.IsAdapterEnabled) -or -not $eth) {
                    $eth = $a
                }
            }
        }
        # If we didn't find a WiFi adapter by name pattern, leave $wifi null
    }

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

    # Extract first IP-table entry (if any) for the Per-Device tab pre-fill.
    $currentIpId   = $null
    $currentCsAddr = $null
    $currentRoomId = $null
    $currentEncrypt = $false
    if ($ipTableJson) {
        $currentEncrypt = [bool]$ipTableJson.EncryptConnection
        $keys = @($ipTableJson.EntriesCurrentKeyList)
        if ($keys.Count -gt 0) {
            # Report the first key even if entry detail isn't populated
            $firstKey = "$($keys[0])"
            $currentIpId = $firstKey
            if ($ipTableJson.Entries) {
                $e = $ipTableJson.Entries.$firstKey
                if ($e) {
                    if ($e.IpId)    { $currentIpId   = "$($e.IpId)" }
                    if ($e.Address) { $currentCsAddr = $e.Address }
                    $currentRoomId = if ($e.Description) { $e.Description } elseif ($e.Name) { $e.Name } else { '' }
                }
            }
        }
    }

    [pscustomobject]@{
        IP                       = $Session.IP
        Hostname                 = $na.HostName
        DomainName               = $eth.DomainName
        EthernetLanEnabled       = [bool]$eth.IsAdapterEnabled
        EthernetLanDhcp          = [bool]$eth.IPv4.IsDhcpEnabled
        EthernetLanIP            = $ethCurrentIp
        EthernetLanStaticIP      = $ethStaticIp
        EthernetLanSubnet        = $ethStaticMask
        EthernetLanGateway       = if ($eth.IPv4.DefaultGateway) { $eth.IPv4.DefaultGateway } else { $eth.IPv4.StaticDefaultGateway }
        DnsServers               = $dnsServers
        HasWifi                  = $hasWifi
        WifiEnabled              = [bool]$wifi.IsAdapterEnabled
        WifiIP                   = $wifiCurrentIp
        CurrentIpId              = $currentIpId
        CurrentControlSystemAddr = $currentCsAddr
        CurrentRoomId            = $currentRoomId
        CurrentEncryptConnection = $currentEncrypt
        CurrentDeviceMode        = if ($deviceSpecificJson) { $deviceSpecificJson.DeviceMode } else { '' }
        SupportsModeChange       = [bool]($deviceSpecificJson -and $deviceSpecificJson.DeviceMode)
        RawJson                  = $api.BodyJson
        FetchedAt                = (Get-Date).ToString('s')
    }
}