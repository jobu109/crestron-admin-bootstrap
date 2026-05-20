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
    if (Test-CrestronUsableIpv4String $text) {
        return $text
    }

    return ''
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

    if ($entries.Count -eq 0 -and -not $Static) {
        $address = Get-CrestronObjectPropertyValue `
            -Object $IPv4 `
            -Names @('Address','IPAddress','IpAddress','IP','CurrentIPAddress','CurrentIpAddress')

        if (Test-CrestronUsableIpv4String $address) {
            $entries += [pscustomobject]@{
                Address    = "$address"
                SubnetMask = Get-CrestronObjectPropertyValue -Object $IPv4 -Names @('SubnetMask','Mask','Netmask')
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
        -Names @('Address','IPAddress','IpAddress','IP','CurrentIPAddress','CurrentIpAddress')

    return (Get-CrestronUsableIpv4String $value)
}

function Get-CrestronIpv4SubnetMaskText {
    param($Entry)

    if (-not $Entry -or $Entry -is [string]) { return '' }

    $value = Get-CrestronObjectPropertyValue `
        -Object $Entry `
        -Names @('SubnetMask','Mask','Netmask')

    return (Get-CrestronUsableIpv4String $value)
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
        $text = Get-CrestronUsableIpv4String $value
        if ($text) { return $text }
    }

    return ''
}

function Get-CrestronNetworkAdapterProperties {
    param($Adapters)

    if (-not $Adapters) { return @() }

    if ($Adapters -is [System.Collections.IDictionary]) {
        return @($Adapters.Keys | ForEach-Object {
            [pscustomobject]@{
                Name  = "$_"
                Value = $Adapters[$_]
            }
        })
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
    $adapterProperties = Get-CrestronNetworkAdapterProperties -Adapters $NetworkAdapters.Adapters
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
    foreach ($source in @($ipv4, $dnsSettings, $NetworkAdapters)) {
        if (-not $source) { continue }

        foreach ($name in @('StaticDns','StaticDNS','StaticDnsServers','StaticDNSServers','DnsServers','DNSServers','Servers')) {
            $value = Get-CrestronObjectPropertyValue -Object $source -Names @($name)
            if ($null -ne $value) {
                $values += @($value)
            }
        }
    }

    return @($values |
        ForEach-Object { "$_".Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne '0.0.0.0' } |
        Select-Object -Unique)
}
