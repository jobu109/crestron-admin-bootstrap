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

    $displaySettings = $null
    try {
        $displaySettings = Get-CrestronDisplaySettings -Session $Session -TimeoutSec $TimeoutSec
    }
    catch {
        $displaySettings = $null
    }

    $avFrameworkSettings = $null
    try {
        $avFrameworkSettings = Get-CrestronAvFrameworkSettings -Session $Session -TimeoutSec $TimeoutSec
    }
    catch {
        $avFrameworkSettings = $null
    }

    $na = $api.BodyJson.Device.NetworkAdapters

    # The Adapters dictionary is keyed by device/firmware-specific adapter names
    # such as EthernetLan, Ethernet, Lan, Vlan00, Wifi, Wlan, etc.  Prefer the
    # adapter that contains the connected session IP, which keeps DM-NAX and
    # other non-NVX devices from being mistaken for a secondary/control adapter.
    $ethInfo = Get-CrestronNetworkAdapterInfo -NetworkAdapters $na -SessionIP $Session.IP
    $wifiInfo = Get-CrestronNetworkAdapterInfo -NetworkAdapters $na -SessionIP $Session.IP -Wifi
    $eth = if ($ethInfo) { $ethInfo.Adapter } else { $null }
    $wifi = if ($wifiInfo) { $wifiInfo.Adapter } else { $null }

    $ethCurrentIp = if ($ethInfo -and $ethInfo.CurrentIP) {
        $ethInfo.CurrentIP
    }
    elseif ($ethInfo) {
        $ethInfo.StaticIP
    }
    else {
        ''
    }

    $ethStaticIp = if ($ethInfo) { $ethInfo.StaticIP } else { '' }

    $ethSubnet = if ($ethInfo -and $ethInfo.IsDhcpEnabled -eq $true) {
        if ($ethInfo.CurrentSubnetMask) { $ethInfo.CurrentSubnetMask } else { $ethInfo.StaticSubnetMask }
    }
    elseif ($ethInfo) {
        if ($ethInfo.StaticSubnetMask) { $ethInfo.StaticSubnetMask } else { $ethInfo.CurrentSubnetMask }
    }
    else {
        ''
    }

    $ethGateway = if ($ethInfo -and $ethInfo.IsDhcpEnabled -eq $true) {
        if ($ethInfo.DefaultGateway) { $ethInfo.DefaultGateway } else { $ethInfo.StaticDefaultGateway }
    }
    elseif ($ethInfo) {
        if ($ethInfo.StaticDefaultGateway) { $ethInfo.StaticDefaultGateway } else { $ethInfo.DefaultGateway }
    }
    else {
        ''
    }

    $wifiCurrentIp = if ($wifiInfo -and $wifiInfo.CurrentIP) {
        $wifiInfo.CurrentIP
    }
    elseif ($wifiInfo) {
        $wifiInfo.StaticIP
    }
    else {
        ''
    }

    $dnsServers = Get-CrestronNetworkDnsServers -NetworkAdapters $na
    $hasWifi = [bool]$wifiInfo

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
        DomainName               = if ($ethInfo) { $ethInfo.DomainName } else { '' }

        EthernetAdapterName      = if ($ethInfo) { $ethInfo.Name } else { '' }
        EthernetLanEnabled       = if ($ethInfo -and $null -ne $ethInfo.IsAdapterEnabled) { [bool]$ethInfo.IsAdapterEnabled } else { [bool]$eth }
        EthernetLanDhcp          = if ($ethInfo -and $null -ne $ethInfo.IsDhcpEnabled) { [bool]$ethInfo.IsDhcpEnabled } else { $false }
        EthernetLanIP            = $ethCurrentIp
        EthernetLanStaticIP      = $ethStaticIp
        EthernetLanSubnet        = $ethSubnet
        EthernetLanGateway       = $ethGateway

        DnsServers               = $dnsServers

        HasWifi                  = $hasWifi
        WifiAdapterName          = if ($wifiInfo) { $wifiInfo.Name } else { '' }
        WifiEnabled              = if ($wifiInfo -and $null -ne $wifiInfo.IsAdapterEnabled) { [bool]$wifiInfo.IsAdapterEnabled } else { $false }
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
        SupportsDisplaySettings  = if ($displaySettings) { [bool]$displaySettings.SupportsDisplaySettings } else { $false }
        SupportsToolbarSettings  = if ($displaySettings) { [bool]$displaySettings.SupportsToolbarSettings } else { $false }
        SupportsAvFrameworkSettings = if ($avFrameworkSettings) { [bool]$avFrameworkSettings.SupportsAvFrameworkSettings } else { $false }
        DisplayPath              = if ($displaySettings) { "$($displaySettings.DisplayPath)" } else { '' }
        ToolbarPath              = if ($displaySettings) { "$($displaySettings.ToolbarPath)" } else { '' }
        AvFrameworkPath          = if ($avFrameworkSettings) { "$($avFrameworkSettings.Path)" } else { '' }
        CurrentAutoBrightness    = if ($displaySettings) { $displaySettings.AutoBrightness } else { $null }
        CurrentBrightness        = if ($displaySettings) { $displaySettings.Brightness } else { $null }
        CurrentScreensaverEnabled = if ($displaySettings) { $displaySettings.ScreensaverEnabled } else { $null }
        CurrentStandbyTimeout    = if ($displaySettings) { $displaySettings.StandbyTimeout } else { $null }
        CurrentToolbarEnabled    = if ($displaySettings) { $displaySettings.ToolbarEnabled } else { $null }
        CurrentAvFrameworkEnabled = if ($avFrameworkSettings) { $avFrameworkSettings.AvFrameworkEnabled } else { $null }

        RawJson                  = $api.BodyJson
        FetchedAt                = (Get-Date).ToString('s')
    }
}
