function Get-CrestronObjectPropertyValue {
    param(
        $Object,
        [string[]]$Names = @(),
        [string]$Pattern = ''
    )

    if (-not $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($name in $Names) {
            if ($Object.Contains($name)) { return $Object[$name] }
        }

        if ($Pattern) {
            foreach ($key in @($Object.Keys)) {
                if ("$key" -match $Pattern) { return $Object[$key] }
            }
        }

        return $null
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }

    if ($Pattern) {
        foreach ($property in @($Object.PSObject.Properties)) {
            if ($property.Name -match $Pattern) {
                return $property.Value
            }
        }
    }

    return $null
}

function Test-CrestronUsableIpv4String {
    param($Value)

    $text = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -in @('0.0.0.0','::','N/A','null')) { return $false }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($text, [ref]$parsed)) {
        return $false
    }

    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Get-CrestronUsableIpv4String {
    param($Value)

    $text = "$Value".Trim()
    if ($text -match '^([^/]+)/(\d{1,2})$') {
        $text = $Matches[1]
    }

    if (Test-CrestronUsableIpv4String $text) {
        return $text
    }

    return ''
}

function ConvertTo-CrestronSubnetMaskFromPrefix {
    param($Value)

    $text = "$Value".Trim()
    if ($text -match '/(\d{1,2})$') {
        $text = $Matches[1]
    }

    $prefix = 0
    if (-not [int]::TryParse($text, [ref]$prefix)) {
        return ''
    }

    if ($prefix -lt 0 -or $prefix -gt 32) {
        return ''
    }

    $bytes = for ($i = 0; $i -lt 4; $i++) {
        $remaining = $prefix - ($i * 8)

        if ($remaining -ge 8) {
            255
        }
        elseif ($remaining -gt 0) {
            [int](256 - [Math]::Pow(2, 8 - $remaining))
        }
        else {
            0
        }
    }

    return ($bytes -join '.')
}

function Test-CrestronObjectLooksLikeIpv4Config {
    param($Object)

    if (-not $Object -or $Object -is [string]) { return $false }

    foreach ($name in @(
        'Addresses','CurrentAddresses','CurrentAddress','AddressList',
        'StaticAddresses','StaticAddress','ManualAddresses','ManualAddress',
        'Address','IPAddress','IpAddress','IP',
        'CurrentIPAddress','CurrentIpAddress','CurrentIP','IpV4Address','IPv4Address',
        'StaticIPAddress','StaticIpAddress','StaticIP','StaticIPv4Address',
        'SubnetMask','Mask','Netmask','CurrentSubnetMask','StaticSubnetMask',
        'DefaultGateway','StaticDefaultGateway','Gateway','Router',
        'IsDhcpEnabled','DhcpEnabled','IsDHCPEnabled'
    )) {
        $value = Get-CrestronObjectPropertyValue -Object $Object -Names @($name)
        if ($null -ne $value) { return $true }
    }

    return $false
}

function Get-CrestronIpv4AddressEntries {
    param(
        $IPv4,
        [switch]$Static
    )

    if (-not $IPv4) { return @() }

    $collectionNames = if ($Static) {
        @('StaticAddresses','StaticAddress','ManualAddresses','ManualAddress')
    }
    else {
        @('Addresses','CurrentAddresses','CurrentAddress','AddressList')
    }

    $entries = @()
    foreach ($name in $collectionNames) {
        $value = Get-CrestronObjectPropertyValue -Object $IPv4 -Names @($name)
        if ($null -ne $value) {
            $entries += @($value)
        }
    }

    if ($entries.Count -eq 0) {
        $addressNames = if ($Static) {
            @('StaticAddress','StaticIPAddress','StaticIpAddress','StaticIP','StaticIPv4Address','ManualAddress','Address','IPAddress','IpAddress','IP')
        }
        else {
            @('Address','IPAddress','IpAddress','IP','CurrentIPAddress','CurrentIpAddress','CurrentIP','IpV4Address','IPv4Address')
        }

        $subnetNames = if ($Static) {
            @('StaticSubnetMask','SubnetMask','Mask','Netmask','PrefixLength','SubnetPrefixLength','CIDR','Cidr')
        }
        else {
            @('CurrentSubnetMask','SubnetMask','Mask','Netmask','PrefixLength','SubnetPrefixLength','CIDR','Cidr')
        }

        $address = Get-CrestronObjectPropertyValue `
            -Object $IPv4 `
            -Names $addressNames

        if (Get-CrestronUsableIpv4String $address) {
            $entries += [pscustomobject]@{
                Address    = "$address"
                SubnetMask = Get-CrestronObjectPropertyValue -Object $IPv4 -Names $subnetNames
            }
        }
    }

    return @($entries)
}

function Get-CrestronIpv4AddressText {
    param($Entry)

    if (-not $Entry) { return '' }

    if ($Entry -is [string]) {
        return (Get-CrestronUsableIpv4String $Entry)
    }

    $value = Get-CrestronObjectPropertyValue `
        -Object $Entry `
        -Names @('Address','IPAddress','IpAddress','IP','CurrentIPAddress','CurrentIpAddress','CurrentIP','IpV4Address','IPv4Address','StaticIPAddress','StaticIpAddress','StaticIP','StaticIPv4Address')

    return (Get-CrestronUsableIpv4String $value)
}

function Get-CrestronIpv4SubnetMaskText {
    param($Entry)

    if (-not $Entry) { return '' }

    if ($Entry -is [string]) {
        if ("$Entry" -match '/(\d{1,2})$') {
            return (ConvertTo-CrestronSubnetMaskFromPrefix $Matches[1])
        }

        return ''
    }

    $value = Get-CrestronObjectPropertyValue `
        -Object $Entry `
        -Names @('SubnetMask','Mask','Netmask','CurrentSubnetMask','StaticSubnetMask')

    $mask = Get-CrestronUsableIpv4String $value
    if ($mask) { return $mask }

    $prefix = Get-CrestronObjectPropertyValue `
        -Object $Entry `
        -Names @('PrefixLength','SubnetPrefixLength','CIDR','Cidr','NetworkPrefixLength')

    $mask = ConvertTo-CrestronSubnetMaskFromPrefix $prefix
    if ($mask) { return $mask }

    $address = Get-CrestronObjectPropertyValue `
        -Object $Entry `
        -Names @('Address','IPAddress','IpAddress','IP','CurrentIPAddress','CurrentIpAddress','CurrentIP','IpV4Address','IPv4Address','StaticIPAddress','StaticIpAddress','StaticIP','StaticIPv4Address')

    return (ConvertTo-CrestronSubnetMaskFromPrefix $address)
}

function Get-CrestronIpv4GatewayText {
    param(
        $IPv4,
        [bool]$PreferStatic = $false
    )

    if (-not $IPv4) { return '' }

    $names = if ($PreferStatic) {
        @('StaticDefaultGateway','DefaultGateway','Gateway','Router')
    }
    else {
        @('DefaultGateway','Gateway','Router','StaticDefaultGateway')
    }

    foreach ($name in $names) {
        $value = Get-CrestronObjectPropertyValue -Object $IPv4 -Names @($name)
        $text = Get-CrestronIpv4AddressText $value
        if (-not $text) {
            $text = Get-CrestronUsableIpv4String $value
        }

        if ($text) { return $text }
    }

    return ''
}

function Get-CrestronNetworkAdapterProperties {
    param($Adapters)

    if (-not $Adapters) { return @() }

    $selfIpv4 = Get-CrestronObjectPropertyValue -Object $Adapters -Names @('IPv4','Ipv4') -Pattern '(?i)^ipv4$'
    if ($selfIpv4 -or (Test-CrestronObjectLooksLikeIpv4Config $Adapters)) {
        $name = Get-CrestronObjectPropertyValue `
            -Object $Adapters `
            -Names @('Name','AdapterName','InterfaceName','Id','ID','Key','Type','AdapterType','InterfaceType')

        if ([string]::IsNullOrWhiteSpace("$name")) {
            $name = 'Adapter0'
        }

        return @([pscustomobject]@{
            Name  = "$name"
            Value = $Adapters
        })
    }

    if ($Adapters -is [System.Collections.IDictionary]) {
        return @($Adapters.Keys | ForEach-Object {
            [pscustomobject]@{
                Name  = "$_"
                Value = $Adapters[$_]
            }
        })
    }

    if ($Adapters -is [System.Collections.IEnumerable] -and
        -not ($Adapters -is [string])) {
        $items = @($Adapters)
        if ($items.Count -gt 1 -or ($items.Count -eq 1 -and $items[0] -ne $Adapters)) {
            $index = 0
            return @($items | ForEach-Object {
                $item = $_
                $name = Get-CrestronObjectPropertyValue `
                    -Object $item `
                    -Names @('Name','AdapterName','InterfaceName','Id','ID','Key','Type','AdapterType','InterfaceType')

                if ([string]::IsNullOrWhiteSpace("$name")) {
                    $name = "Adapter$index"
                }

                $index++
                [pscustomobject]@{
                    Name  = "$name"
                    Value = $item
                }
            })
        }
    }

    return @($Adapters.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{
            Name  = $_.Name
            Value = $_.Value
        }
    })
}

function Get-CrestronNetworkAdapterInfo {
    param(
        [Parameter(Mandatory)]$NetworkAdapters,
        [string]$SessionIP = '',
        [switch]$Wifi
    )

    $sessionIpText = "$SessionIP".Trim()
    $adapterProperties = @()

    foreach ($containerName in @('Adapters','AdapterList','NetworkAdapters','NetworkAdapterList','Interfaces','InterfaceList')) {
        $container = Get-CrestronObjectPropertyValue -Object $NetworkAdapters -Names @($containerName)
        if ($container) {
            $adapterProperties += @(Get-CrestronNetworkAdapterProperties -Adapters $container)
        }
    }

    $adapterProperties += @(Get-CrestronNetworkAdapterProperties -Adapters $NetworkAdapters | Where-Object {
        $_.Name -notin @('HostName','Hostname','DomainName','DnsSettings','DNSSettings','IgmpVersion','IGMPVersion') -and
        (
            (Get-CrestronObjectPropertyValue -Object $_.Value -Names @('IPv4','Ipv4') -Pattern '(?i)^ipv4$') -or
            (Test-CrestronObjectLooksLikeIpv4Config $_.Value)
        )
    })

    $seenAdapters = @{}
    $adapterProperties = @($adapterProperties | Where-Object {
        $key = "$($_.Name)"
        if ($_.Value) {
            $key += "|$([Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($_.Value))"
        }

        if ($seenAdapters.ContainsKey($key)) {
            return $false
        }

        $seenAdapters[$key] = $true
        return $true
    })

    $candidates = @()

    foreach ($property in $adapterProperties) {
        $name = "$($property.Name)"
        $adapter = $property.Value
        if (-not $adapter) { continue }

        $adapterType = "$((Get-CrestronObjectPropertyValue -Object $adapter -Names @('AdapterType','Type','InterfaceType','Name')))"
        $isWifi = ($name -match '(?i)wifi|wireless|wlan') -or ($adapterType -match '(?i)wifi|wireless|wlan')
        if ([bool]$Wifi -ne [bool]$isWifi) { continue }

        $isControlSubnet = ($name -match '(?i)control.?subnet') -or ($adapterType -match '(?i)control.?subnet')
        if (-not $Wifi -and $isControlSubnet) { continue }

        $ipv4 = Get-CrestronObjectPropertyValue -Object $adapter -Names @('IPv4','Ipv4') -Pattern '(?i)^ipv4$'
        if (-not $ipv4 -and (Test-CrestronObjectLooksLikeIpv4Config $adapter)) {
            $ipv4 = $adapter
        }

        if (-not $ipv4) { continue }

        $currentEntries = @(Get-CrestronIpv4AddressEntries -IPv4 $ipv4)
        $staticEntries = @(Get-CrestronIpv4AddressEntries -IPv4 $ipv4 -Static)

        $currentEntry = @($currentEntries | Where-Object { Get-CrestronIpv4AddressText $_ } | Select-Object -First 1)[0]
        $staticEntry = @($staticEntries | Where-Object { Get-CrestronIpv4AddressText $_ } | Select-Object -First 1)[0]

        $currentIp = Get-CrestronIpv4AddressText $currentEntry
        $staticIp = Get-CrestronIpv4AddressText $staticEntry
        $currentSubnet = Get-CrestronIpv4SubnetMaskText $currentEntry
        $staticSubnet = Get-CrestronIpv4SubnetMaskText $staticEntry

        if (-not $currentSubnet) {
            $currentSubnet = Get-CrestronUsableIpv4String (Get-CrestronObjectPropertyValue -Object $ipv4 -Names @('SubnetMask','Mask','Netmask'))
        }

        if (-not $staticSubnet) {
            $staticSubnet = Get-CrestronUsableIpv4String (Get-CrestronObjectPropertyValue -Object $ipv4 -Names @('StaticSubnetMask','SubnetMask','Mask','Netmask'))
        }

        $isDhcp = Get-CrestronObjectPropertyValue -Object $ipv4 -Names @('IsDhcpEnabled','DhcpEnabled','IsDHCPEnabled')
        $isEnabled = Get-CrestronObjectPropertyValue -Object $adapter -Names @('IsAdapterEnabled','IsEnabled','Enabled')
        $isActive = Get-CrestronObjectPropertyValue -Object $adapter -Names @('IsActive','Active')

        $hasSessionIp = $false
        if (Test-CrestronUsableIpv4String $sessionIpText) {
            foreach ($entry in @($currentEntries + $staticEntries)) {
                if ((Get-CrestronIpv4AddressText $entry) -eq $sessionIpText) {
                    $hasSessionIp = $true
                    break
                }
            }
        }

        $nameScore = switch -Regex ($name) {
            '^(?i)EthernetLan$' { 90; break }
            '^(?i)Ethernet(Lan|LAN)?\d*$' { 80; break }
            '^(?i)(Lan|LAN)\d*$' { 70; break }
            '^(?i)(Eth|ETH)\d*$' { 60; break }
            default { 0 }
        }

        $score = 0
        if ($hasSessionIp) { $score += 1000 }
        $score += $nameScore
        if ($isActive) { $score += 40 }
        if ($isEnabled) { $score += 20 }
        if ($currentIp) { $score += 10 }
        if ($staticIp) { $score += 5 }

        $preferStatic = $false
        if ($null -ne $isDhcp) {
            $preferStatic = -not [bool]$isDhcp
        }

        $candidates += [pscustomobject]@{
            Name                 = $name
            Adapter              = $adapter
            IPv4                 = $ipv4
            IsDhcpEnabled        = if ($null -ne $isDhcp) { [bool]$isDhcp } else { $null }
            IsAdapterEnabled     = if ($null -ne $isEnabled) { [bool]$isEnabled } else { $null }
            IsActive             = if ($null -ne $isActive) { [bool]$isActive } else { $null }
            CurrentIP            = $currentIp
            CurrentSubnetMask    = $currentSubnet
            StaticIP             = $staticIp
            StaticSubnetMask     = $staticSubnet
            DefaultGateway       = Get-CrestronIpv4GatewayText -IPv4 $ipv4 -PreferStatic:$false
            StaticDefaultGateway = Get-CrestronIpv4GatewayText -IPv4 $ipv4 -PreferStatic:$true
            DomainName           = "$((Get-CrestronObjectPropertyValue -Object $adapter -Names @('DomainName','Domain')))"
            Score                = $score
        }
    }

    return @($candidates | Sort-Object Score -Descending | Select-Object -First 1)[0]
}

function Get-CrestronNetworkDnsServers {
    param($NetworkAdapters)

    $dnsSettings = Get-CrestronObjectPropertyValue -Object $NetworkAdapters -Names @('DnsSettings','DNSSettings')
    $ipv4 = if ($dnsSettings) {
        Get-CrestronObjectPropertyValue -Object $dnsSettings -Names @('IPv4','Ipv4') -Pattern '(?i)^ipv4$'
    }
    else {
        $null
    }

    $values = @()
    $adapterSources = @()
    foreach ($containerName in @('Adapters','AdapterList','NetworkAdapters','NetworkAdapterList','Interfaces','InterfaceList')) {
        $container = Get-CrestronObjectPropertyValue -Object $NetworkAdapters -Names @($containerName)
        if ($container) {
            $adapterSources += @(Get-CrestronNetworkAdapterProperties -Adapters $container | Select-Object -ExpandProperty Value)
        }
    }

    $adapterSources += @(Get-CrestronNetworkAdapterProperties -Adapters $NetworkAdapters | Where-Object {
        $_.Name -notin @('HostName','Hostname','DomainName','DnsSettings','DNSSettings','IgmpVersion','IGMPVersion') -and
        (
            (Get-CrestronObjectPropertyValue -Object $_.Value -Names @('IPv4','Ipv4') -Pattern '(?i)^ipv4$') -or
            (Test-CrestronObjectLooksLikeIpv4Config $_.Value)
        )
    } | Select-Object -ExpandProperty Value)

    $adapterIpv4Sources = @($adapterSources | ForEach-Object {
        $adapter = $_
        $adapterIpv4 = Get-CrestronObjectPropertyValue -Object $adapter -Names @('IPv4','Ipv4') -Pattern '(?i)^ipv4$'
        if (-not $adapterIpv4 -and (Test-CrestronObjectLooksLikeIpv4Config $adapter)) {
            $adapterIpv4 = $adapter
        }

        $adapterIpv4
    } | Where-Object { $_ })

    foreach ($source in @($ipv4, $dnsSettings, $NetworkAdapters) + $adapterSources + $adapterIpv4Sources) {
        if (-not $source) { continue }

        foreach ($name in @(
            'StaticDns','StaticDNS','StaticDnsServers','StaticDNSServers',
            'DnsServers','DNSServers','Servers','NameServers','Nameservers',
            'PrimaryDns','PrimaryDNS','Dns1','DNS1',
            'SecondaryDns','SecondaryDNS','Dns2','DNS2'
        )) {
            $value = Get-CrestronObjectPropertyValue -Object $source -Names @($name)
            if ($null -ne $value) {
                $values += @($value)
            }
        }
    }

    return @($values |
        ForEach-Object {
            $text = Get-CrestronIpv4AddressText $_
            if (-not $text) {
                $rawText = "$_".Trim()
                if ($rawText -match '\b(?:\d{1,3}\.){3}\d{1,3}\b') {
                    $text = $Matches[0]
                }
                else {
                    $text = $rawText
                }
            }
            $text
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne '0.0.0.0' } |
        Select-Object -Unique)
}
