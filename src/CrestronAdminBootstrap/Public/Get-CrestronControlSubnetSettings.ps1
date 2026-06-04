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
        [pscredential]$Credential,
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
        foreach ($item in $items) {
            if ($item -and (Test-CabsUsableIpv4String $item.Address)) {
                return $item
            }
        }

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

    function Test-CabsUsableIpv4String {
        param($Value)

        $text = "$Value".Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }
        if ($text -eq '0.0.0.0') { return $false }
        if ($text -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { return $false }
        return $true
    }

    function Get-CabsUsableIpv4String {
        param($Value)

        if (Test-CabsUsableIpv4String $Value) {
            return "$Value".Trim()
        }

        return ''
    }

    function ConvertTo-CabsIgmpVersionText {
        param($Value)

        $text = "$Value".Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }

        switch -Regex ($text) {
            '^(V?2|IGMP\s*V?2|Version\s*2)$' { return 'V2' }
            '^(V?3|IGMP\s*V?3|Version\s*3)$' { return 'V3' }
            default                           { return '' }
        }
    }

    function ConvertTo-CabsNonNegativeIntText {
        param($Value)

        $text = "$Value".Trim()
        $number = 0
        if ([int]::TryParse($text, [ref]$number) -and $number -ge 0) {
            return "$number"
        }

        return ''
    }

    function ConvertTo-CabsSubnetMaskFromCidr {
        param($Value)

        $text = "$Value".Trim()
        if ($text -notmatch '/(\d{1,2})$') {
            return ''
        }

        $prefixLength = 0
        if (-not [int]::TryParse($matches[1], [ref]$prefixLength)) {
            return ''
        }

        if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
            return ''
        }

        $bits = ('1' * $prefixLength).PadRight(32, '0')
        $octets = for ($i = 0; $i -lt 4; $i++) {
            [Convert]::ToInt32($bits.Substring($i * 8, 8), 2)
        }

        $octets -join '.'
    }

    function ConvertFrom-CabsIgmpProxyOutput {
        param($Output)

        $text = "$Output"
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        if ($text -match '(?im)\b(igmp\s*proxy|igmpproxy)\b.{0,80}\b(on|enabled|enable|true|1)\b') {
            return $true
        }

        if ($text -match '(?im)\b(igmp\s*proxy|igmpproxy)\b.{0,80}\b(off|disabled|disable|false|0)\b') {
            return $false
        }

        if ($text -match '(?im)\b(on|enabled)\b') {
            return $true
        }

        if ($text -match '(?im)\b(off|disabled)\b') {
            return $false
        }

        return $null
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
            SupportsIgmpVersion      = $false
            SupportsIgmpProxy        = $false
            ControlSubnetAdapterName = ''
            FetchedAt                = (Get-Date).ToString('s')
        }
    }

    $ipv4 = Get-CabsPropertyValue -Object $controlSubnet -Names @('IPv4','Ipv4') -Pattern '(?i)^ipv4$'
    $currentAddress = if ($ipv4) { Get-CabsFirstAddress $ipv4.Addresses } else { $null }
    $staticAddress = if ($ipv4) { Get-CabsFirstAddress $ipv4.StaticAddresses } else { $null }
    $currentIpAddress = if ($currentAddress) { Get-CabsUsableIpv4String $currentAddress.Address } else { '' }
    $currentSubnetMask = if ($currentAddress) { Get-CabsUsableIpv4String $currentAddress.SubnetMask } else { '' }
    $staticIpAddress = if ($staticAddress) { Get-CabsUsableIpv4String $staticAddress.Address } else { '' }
    $staticSubnetMask = if ($staticAddress) { Get-CabsUsableIpv4String $staticAddress.SubnetMask } else { '' }
    $defaultGateway = if ($ipv4 -and $ipv4.DefaultGateway) { Get-CabsUsableIpv4String $ipv4.DefaultGateway } else { '' }
    $staticDefaultGateway = if ($ipv4 -and $ipv4.StaticDefaultGateway) { Get-CabsUsableIpv4String $ipv4.StaticDefaultGateway } else { '' }

    $routerPrefix = if ($router -and $router.PSObject.Properties.Name -contains 'RouterPrefix') { "$($router.RouterPrefix)" } else { '' }
    $routerAddress = if ($router) {
        Get-CabsUsableIpv4String (Get-CabsPropertyValue `
            -Object $router `
            -Names @('RouterAddress','RouterIPAddress','RouterIpAddress','RouterIP','RouterIp','ControlSubnetAddress','ControlSubnetIPAddress','ControlSubnetIpAddress','ControlSubnetIP','ControlSubnetIp','IPAddress','IpAddress','Address') `
            -Pattern '(?i)(^router.*address$|^router.*ip.*address$|^router.*ip$|^control.*subnet.*address$|^control.*subnet.*ip.*address$|^control.*subnet.*ip$|^ip.*address$)')
    }
    else {
        ''
    }
    $routerPrefixSubnetMask = ConvertTo-CabsSubnetMaskFromCidr $routerPrefix

    if ([string]::IsNullOrWhiteSpace($currentIpAddress) -and -not [string]::IsNullOrWhiteSpace($routerAddress)) {
        $currentIpAddress = $routerAddress
    }

    if ([string]::IsNullOrWhiteSpace($currentSubnetMask) -and -not [string]::IsNullOrWhiteSpace($routerPrefixSubnetMask)) {
        $currentSubnetMask = $routerPrefixSubnetMask
    }

    $igmpVersionPropertyName = Get-CabsPropertyName -Object $na -Names @('IgmpVersion','IGMPVersion') -Pattern '(?i)^igmp.*version$'
    $supportsIgmpVersion = -not [string]::IsNullOrWhiteSpace($igmpVersionPropertyName)
    $igmpVersion = if ($supportsIgmpVersion) { ConvertTo-CabsIgmpVersionText $na.$igmpVersionPropertyName } else { '' }

    $igmpProxyProperty = ''
    $igmpProxyValue = $null
    $igmpProxyTransport = ''

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

    if (-not $igmpProxyProperty -and $Credential) {
        $igmpProxyTransport = 'Telnet'

        try {
            $proxyCommand = Invoke-CrestronTelnetCommand `
                -IP $Session.IP `
                -Credential $Credential `
                -Command 'IGMPPROXY' `
                -TimeoutSec $TimeoutSec

            $telnetProxyValue = ConvertFrom-CabsIgmpProxyOutput $proxyCommand.Output
            if ($null -ne $telnetProxyValue) {
                $igmpProxyValue = $telnetProxyValue
            }
        }
        catch {
            # Command fallback may be unavailable if telnet is disabled. Keep the
            # GUI editable so apply can still attempt IGMPPROXY ON/OFF when asked.
        }
    }
    elseif ($igmpProxyProperty) {
        $igmpProxyTransport = 'WebApi'
    }

    [pscustomobject]@{
        IP                       = $Session.IP
        Model                    = $Session.Model
        Hostname                 = if ($na.HostName) { "$($na.HostName)" } else { "$($Session.Hostname)" }

        SupportsControlSubnet    = $true
        SupportsRouter           = [bool]$router
        SupportsIgmpVersion      = $supportsIgmpVersion
        SupportsIgmpProxy        = [bool]($igmpProxyProperty -or $Credential)
        ControlSubnetAdapterName = $adapterName
        IsReadOnly               = if ($controlSubnet.PSObject.Properties.Name -contains 'IsAdapterReadOnly') { [bool]$controlSubnet.IsAdapterReadOnly } else { $false }
        IsActive                 = if ($controlSubnet.PSObject.Properties.Name -contains 'IsActive') { [bool]$controlSubnet.IsActive } else { $false }
        IsEnabled                = if ($controlSubnet.PSObject.Properties.Name -contains 'IsAdapterEnabled') { [bool]$controlSubnet.IsAdapterEnabled } else { $null }
        IsDhcpEnabled            = if ($ipv4 -and $ipv4.PSObject.Properties.Name -contains 'IsDhcpEnabled') { [bool]$ipv4.IsDhcpEnabled } else { $null }
        CurrentIPAddress         = $currentIpAddress
        CurrentSubnetMask        = $currentSubnetMask
        StaticIPAddress          = $staticIpAddress
        StaticSubnetMask         = $staticSubnetMask
        DefaultGateway           = $defaultGateway
        StaticDefaultGateway     = $staticDefaultGateway
        IgmpVersion              = $igmpVersion

        RouterAutomaticMode      = if ($router -and $router.PSObject.Properties.Name -contains 'AutomaticMode') { ConvertTo-CabsBoolText $router.AutomaticMode } else { $null }
        RouterPrefix             = $routerPrefix
        RouterOnlineDelay        = if ($router -and $router.PSObject.Properties.Name -contains 'RouterOnlineDelay') { ConvertTo-CabsNonNegativeIntText $router.RouterOnlineDelay } else { '' }
        RouterIsolationMode      = if ($router -and $router.PSObject.Properties.Name -contains 'IsIsolationModeEnabled') { ConvertTo-CabsBoolText $router.IsIsolationModeEnabled } else { $null }
        IgmpProxyPropertyName    = $igmpProxyProperty
        IgmpProxyTransport       = $igmpProxyTransport
        IgmpProxyEnabled         = $igmpProxyValue

        RawNetworkAdapters       = $networkApi.BodyJson
        RawRouter                = $router
        FetchedAt                = (Get-Date).ToString('s')
    }
}
