function Get-CrestronDeviceState {
    <#
    .SYNOPSIS
        Retrieves the current device state from a connected Crestron device.

    .DESCRIPTION
        GETs /Device/NetworkAdapters using the authenticated session and returns
        a flattened state object covering hostname, Ethernet adapter IPv4 config,
        DNS, WiFi state, IP table state, and DM-NVX TX/RX mode support when
        available.

        Device mode support is intentionally limited to known dual-mode DM-NVX
        models. Fixed-purpose receiver-only/decoder models such as DM-NVX-D30 may
        expose DeviceSpecific.DeviceMode but should not be treated as switchable.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 15.

    .OUTPUTS
        PSCustomObject with device state fields used by the GUI.

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

    # Best-effort fetch DeviceSpecific to detect DM-NVX TX/RX mode state.
    $deviceSpecificJson = $null

    try {
        $dsApi = Invoke-CrestronApi -Session $Session -Path '/Device/DeviceSpecific' `
                                    -Method GET -TimeoutSec $TimeoutSec

        if ($dsApi.Success -and $dsApi.BodyJson) {
            $deviceSpecificJson = $dsApi.BodyJson.Device.DeviceSpecific
        }
    } catch { }

    # Best-effort fetch IpTableV2 / IpTable for Control System binding.
    $ipTableJson = $null

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

    # The Adapters dictionary is keyed by device/firmware-specific adapter names
    # such as EthernetLan, Vlan00, Wifi, Wlan, etc.
    $eth = $null
    $wifi = $null

    if ($na.Adapters) {
        $adapterProps = @($na.Adapters | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue)

        foreach ($p in $adapterProps) {
            $a = $na.Adapters.$($p.Name)
            $isWifi = $p.Name -match 'Wifi|Wireless|Wlan'

            if ($isWifi -and -not $wifi) {
                $wifi = $a
            }
            elseif (-not $isWifi -and -not $eth -and $a.IPv4) {
                if (($a.IsActive -and $a.IsAdapterEnabled) -or -not $eth) {
                    $eth = $a
                }
            }
        }
    }

    # Current Ethernet IP.
    $ethCurrentIp = $null

    if ($eth -and $eth.IPv4 -and $eth.IPv4.Addresses) {
        $first = @($eth.IPv4.Addresses)[0]

        if ($first -and $first.Address) {
            $ethCurrentIp = $first.Address
        }
    }

    # Current WiFi IP.
    $wifiCurrentIp = $null

    if ($wifi -and $wifi.IPv4 -and $wifi.IPv4.Addresses) {
        $first = @($wifi.IPv4.Addresses)[0]

        if ($first -and $first.Address) {
            $wifiCurrentIp = $first.Address
        }
    }

    # Configured static Ethernet IP/subnet.
    $ethStaticIp = $null
    $ethStaticMask = $null

    if ($eth -and $eth.IPv4 -and $eth.IPv4.StaticAddresses) {
        $sa = @($eth.IPv4.StaticAddresses)[0]

        if ($sa) {
            $ethStaticIp = $sa.Address
            $ethStaticMask = $sa.SubnetMask
        }
    }

    # DNS.
    $dnsServers = @()

    if ($na.DnsSettings -and $na.DnsSettings.IPv4 -and $na.DnsSettings.IPv4.StaticDns) {
        $dnsServers = @($na.DnsSettings.IPv4.StaticDns | Where-Object {
            $_ -and $_.Trim() -ne ''
        })
    }

    # Whether the device actually has a WiFi adapter.
    $hasWifi = [bool]$wifi

    # Extract first IP-table entry for GUI prefill.
    $currentIpId = $null
    $currentCsAddr = $null
    $currentRoomId = $null
    $currentEncrypt = $false

    if ($ipTableJson) {
        $currentEncrypt = [bool]$ipTableJson.EncryptConnection
        $keys = @($ipTableJson.EntriesCurrentKeyList)

        if ($keys.Count -gt 0) {
            $firstKey = "$($keys[0])"
            $currentIpId = $firstKey

            if ($ipTableJson.Entries) {
                $e = $ipTableJson.Entries.$firstKey

                if ($e) {
                    if ($e.IpId) {
                        $currentIpId = "$($e.IpId)"
                    }

                    if ($e.Address) {
                        $currentCsAddr = $e.Address
                    }

                    $currentRoomId = if ($e.Description) {
                        $e.Description
                    }
                    elseif ($e.Name) {
                        $e.Name
                    }
                    else {
                        ''
                    }
                }
            }
        }
    }

    # DM-NVX mode state/capability.
    $currentDeviceMode = if ($deviceSpecificJson -and $deviceSpecificJson.DeviceMode) {
        "$($deviceSpecificJson.DeviceMode)"
    }
    else {
        ''
    }

    $modelName = "$($Session.Model)".ToUpperInvariant()

    $knownDualModeModels = @(
        'DM-NVX-350',
        'DM-NVX-351',
        'DM-NVX-360',
        'DM-NVX-360C',
        'DM-NVX-363',
        'DM-NVX-363C',
        'DM-NVX-384',
        'DM-NVX-384C',
        'DM-NVX-385',
        'DM-NVX-385C'
    )

    $supportsModeChange = [bool]$currentDeviceMode

    if ($knownDualModeModels -notcontains $modelName) {
        $supportsModeChange = $false
    }

    [pscustomobject]@{
        IP                       = $Session.IP
        Model                    = $Session.Model
        Hostname                 = $na.HostName
        DomainName               = if ($eth) { $eth.DomainName } else { '' }

        EthernetLanEnabled       = if ($eth) { [bool]$eth.IsAdapterEnabled } else { $false }
        EthernetLanDhcp          = if ($eth -and $eth.IPv4) { [bool]$eth.IPv4.IsDhcpEnabled } else { $false }
        EthernetLanIP            = $ethCurrentIp
        EthernetLanStaticIP      = $ethStaticIp
        EthernetLanSubnet        = $ethStaticMask
        EthernetLanGateway       = if ($eth -and $eth.IPv4 -and $eth.IPv4.DefaultGateway) {
            $eth.IPv4.DefaultGateway
        }
        elseif ($eth -and $eth.IPv4) {
            $eth.IPv4.StaticDefaultGateway
        }
        else {
            ''
        }

        DnsServers               = $dnsServers

        HasWifi                  = $hasWifi
        WifiEnabled              = if ($wifi) { [bool]$wifi.IsAdapterEnabled } else { $false }
        WifiIP                   = $wifiCurrentIp

        CurrentIpId              = $currentIpId
        CurrentControlSystemAddr = $currentCsAddr
        CurrentRoomId            = $currentRoomId
        CurrentEncryptConnection = $currentEncrypt

        CurrentDeviceMode        = $currentDeviceMode
        SupportsModeChange       = $supportsModeChange
        SupportsNetwork          = $true
        SupportsIpTable          = [bool]$ipTableJson
        SupportsWifi             = $hasWifi

        RawJson                  = $api.BodyJson
        FetchedAt                = (Get-Date).ToString('s')
    }
}
