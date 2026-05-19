function Get-CrestronControlSubnetSettings {
    <#
    .SYNOPSIS
        Retrieves 4-Series processor Control Subnet settings.

    .DESCRIPTION
        Reads /Device/NetworkAdapters and, when available, /Device/Router to
        flatten ControlSubnet adapter, IPv4, IGMP version, and router settings
        for the GUI. Devices without a ControlSubnet adapter return
        SupportsControlSubnet = $false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    function Get-CabsPropertyName {
        param(
            $Object,
            [string[]]$Names,
            [string]$Pattern
        )

        if (-not $Object) { return '' }

        $props = @($Object.PSObject.Properties)

        foreach ($name in @($Names)) {
            $match = $props | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($match) { return "$($match.Name)" }
        }

        if (-not [string]::IsNullOrWhiteSpace($Pattern)) {
            $match = $props | Where-Object { $_.Name -match $Pattern } | Select-Object -First 1
            if ($match) { return "$($match.Name)" }
        }

        return ''
    }

    function Get-CabsPropertyValue {
        param(
            $Object,
            [string[]]$Names,
            [string]$Pattern
        )

        $name = Get-CabsPropertyName -Object $Object -Names $Names -Pattern $Pattern
        if (-not $name) { return $null }

        return $Object.$name
    }

    function Get-CabsFirstAddress {
        param($Addresses)

        $items = @($Addresses)
        if ($items.Count -gt 0) { return $items[0] }
        return $null
    }

    function ConvertTo-CabsBoolText {
        param($Value)

        if ($null -eq $Value) { return $null }
        if ($Value -is [bool]) { return [bool]$Value }

        switch -Regex ("$Value".Trim()) {
            '^(true|yes|on|enabled|enable|1)$'    { return $true }
            '^(false|no|off|disabled|disable|0)$' { return $false }
            default                               { return $null }
        }
    }

    $networkApi = Invoke-CrestronApi -Session $Session -Path '/Device/NetworkAdapters' -Method GET -TimeoutSec $TimeoutSec

    if (-not $networkApi.Success) {
        throw "GET /Device/NetworkAdapters on $($Session.IP) failed with HTTP $($networkApi.Status)."
    }

    if (-not $networkApi.BodyJson -or -not $networkApi.BodyJson.Device -or -not $networkApi.BodyJson.Device.NetworkAdapters) {
        throw "GET /Device/NetworkAdapters on $($Session.IP) returned no parseable NetworkAdapters JSON."
    }

    $na = $networkApi.BodyJson.Device.NetworkAdapters
    $adapterName = ''
    $controlSubnet = $null

    if ($na.Adapters) {
        $adapterName = Get-CabsPropertyName `
            -Object $na.Adapters `
            -Names @('ControlSubnet') `
            -Pattern '(?i)control.*subnet'

        if ($adapterName) {
            $controlSubnet = $na.Adapters.$adapterName
        }
    }

    $router = $null

    try {
        $routerApi = Invoke-CrestronApi -Session $Session -Path '/Device/Router' -Method GET -TimeoutSec $TimeoutSec

        if ($routerApi.Success -and $routerApi.BodyJson -and $routerApi.BodyJson.Device) {
            $router = $routerApi.BodyJson.Device.Router
        }
    }
    catch { }

    if (-not $router) {
        try {
            $deviceApi = Invoke-CrestronApi -Session $Session -Path '/Device' -Method GET -TimeoutSec $TimeoutSec

            if ($deviceApi.Success -and $deviceApi.BodyJson -and $deviceApi.BodyJson.Device) {
                $router = $deviceApi.BodyJson.Device.Router
            }
        }
        catch { }
    }

    if (-not $controlSubnet) {
        return [pscustomobject]@{
            IP                       = $Session.IP
            Model                    = $Session.Model
            Hostname                 = if ($na.HostName) { "$($na.HostName)" } else { "$($Session.Hostname)" }
            SupportsControlSubnet    = $false
            SupportsRouter           = [bool]$router
            SupportsIgmpProxy        = $false
            ControlSubnetAdapterName = ''
            FetchedAt                = (Get-Date).ToString('s')
        }
    }

    $ipv4 = Get-CabsPropertyValue -Object $controlSubnet -Names @('IPv4','Ipv4') -Pattern '(?i)^ipv4$'
    $currentAddress = if ($ipv4) { Get-CabsFirstAddress $ipv4.Addresses } else { $null }
    $staticAddress = if ($ipv4) { Get-CabsFirstAddress $ipv4.StaticAddresses } else { $null }

    $igmpVersion = Get-CabsPropertyValue -Object $na -Names @('IgmpVersion','IGMPVersion') -Pattern '(?i)^igmp.*version$'

    $igmpProxyProperty = ''
    $igmpProxyValue = $null

    if ($router) {
        $igmpProxyProperty = Get-CabsPropertyName `
            -Object $router `
            -Names @('IgmpProxy','IGMPProxy','IgmpProxyEnabled','IsIgmpProxyEnabled','IsIGMPProxyEnabled') `
            -Pattern '(?i)igmp.*proxy'

        if ($igmpProxyProperty) {
            $rawProxy = $router.$igmpProxyProperty

            if ($rawProxy -and $rawProxy.PSObject.Properties.Name -contains 'IsEnabled') {
                $igmpProxyValue = ConvertTo-CabsBoolText $rawProxy.IsEnabled
            }
            elseif ($rawProxy -and $rawProxy.PSObject.Properties.Name -contains 'Enabled') {
                $igmpProxyValue = ConvertTo-CabsBoolText $rawProxy.Enabled
            }
            else {
                $igmpProxyValue = ConvertTo-CabsBoolText $rawProxy
            }
        }
    }

    [pscustomobject]@{
        IP                       = $Session.IP
        Model                    = $Session.Model
        Hostname                 = if ($na.HostName) { "$($na.HostName)" } else { "$($Session.Hostname)" }

        SupportsControlSubnet    = $true
        SupportsRouter           = [bool]$router
        SupportsIgmpProxy        = [bool]$igmpProxyProperty
        ControlSubnetAdapterName = $adapterName
        IsReadOnly               = if ($controlSubnet.PSObject.Properties.Name -contains 'IsAdapterReadOnly') { [bool]$controlSubnet.IsAdapterReadOnly } else { $false }
        IsActive                 = if ($controlSubnet.PSObject.Properties.Name -contains 'IsActive') { [bool]$controlSubnet.IsActive } else { $false }
        IsEnabled                = if ($controlSubnet.PSObject.Properties.Name -contains 'IsAdapterEnabled') { [bool]$controlSubnet.IsAdapterEnabled } else { $null }
        IsDhcpEnabled            = if ($ipv4 -and $ipv4.PSObject.Properties.Name -contains 'IsDhcpEnabled') { [bool]$ipv4.IsDhcpEnabled } else { $null }
        CurrentIPAddress         = if ($currentAddress) { "$($currentAddress.Address)" } else { '' }
        CurrentSubnetMask        = if ($currentAddress) { "$($currentAddress.SubnetMask)" } else { '' }
        StaticIPAddress          = if ($staticAddress) { "$($staticAddress.Address)" } else { '' }
        StaticSubnetMask         = if ($staticAddress) { "$($staticAddress.SubnetMask)" } else { '' }
        DefaultGateway           = if ($ipv4 -and $ipv4.DefaultGateway) { "$($ipv4.DefaultGateway)" } else { '' }
        StaticDefaultGateway     = if ($ipv4 -and $ipv4.StaticDefaultGateway) { "$($ipv4.StaticDefaultGateway)" } else { '' }
        IgmpVersion              = if ($igmpVersion) { "$igmpVersion" } else { '' }

        RouterAutomaticMode      = if ($router -and $router.PSObject.Properties.Name -contains 'AutomaticMode') { ConvertTo-CabsBoolText $router.AutomaticMode } else { $null }
        RouterPrefix             = if ($router -and $router.PSObject.Properties.Name -contains 'RouterPrefix') { "$($router.RouterPrefix)" } else { '' }
        RouterOnlineDelay        = if ($router -and $router.PSObject.Properties.Name -contains 'RouterOnlineDelay') { "$($router.RouterOnlineDelay)" } else { '' }
        RouterIsolationMode      = if ($router -and $router.PSObject.Properties.Name -contains 'IsIsolationModeEnabled') { ConvertTo-CabsBoolText $router.IsIsolationModeEnabled } else { $null }
        IgmpProxyPropertyName    = $igmpProxyProperty
        IgmpProxyEnabled         = $igmpProxyValue

        RawNetworkAdapters       = $networkApi.BodyJson
        RawRouter                = $router
        FetchedAt                = (Get-Date).ToString('s')
    }
}
