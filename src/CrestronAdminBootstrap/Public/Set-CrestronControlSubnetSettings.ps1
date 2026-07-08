function Set-CrestronControlSubnetSettings {
    <#
    .SYNOPSIS
        Applies 4-Series processor Control Subnet settings.

    .DESCRIPTION
        Builds a partial /Device payload for NetworkAdapters.Adapters.ControlSubnet,
        NetworkAdapters.IgmpVersion, and Router settings. Only parameters
        supplied by the caller are posted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Nullable[bool]]$Enabled,
        [ValidateSet('DHCP','Static')][string]$IPMode,
        [string]$IPAddress,
        [string]$SubnetMask,
        [string]$Gateway,
        [ValidateSet('V2','V3')][string]$IgmpVersion,
        [Nullable[bool]]$RouterAutomaticMode,
        [string]$RouterPrefix,
        [Nullable[int]]$RouterOnlineDelay,
        [Nullable[bool]]$RouterIsolationMode,
        [Nullable[bool]]$IgmpProxyEnabled,
        [string]$IgmpProxyPropertyName,
        [pscredential]$Credential,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    function Test-CabsIpv4Address {
        param([string]$Value)

        if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
        if ($Value -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { return $false }

        foreach ($octet in ($Value -split '\.')) {
            $n = 0
            if (-not [int]::TryParse($octet, [ref]$n)) { return $false }
            if ($n -lt 0 -or $n -gt 255) { return $false }
        }

        return $true
    }

    function New-CabsControlSubnetIpv4Payloads {
        if (-not $hasIpMode) {
            return @($null)
        }

        if ($IPMode -eq 'DHCP') {
            return @(@{
                IsDhcpEnabled = $true
            })
        }

        return @(
            @{
                IsDhcpEnabled = $false
                StaticAddresses = @(@{
                    Address    = $IPAddress
                    SubnetMask = $SubnetMask
                })
                StaticDefaultGateway = $Gateway
            },
            @{
                IsDhcpEnabled = $false
                StaticAddress = @{
                    Address    = $IPAddress
                    SubnetMask = $SubnetMask
                }
                StaticDefaultGateway = $Gateway
            },
            @{
                IsDhcpEnabled = $false
                Addresses = @(@{
                    Address    = $IPAddress
                    SubnetMask = $SubnetMask
                })
                DefaultGateway = $Gateway
            },
            @{
                IsDhcpEnabled = $false
                Address = $IPAddress
                SubnetMask = $SubnetMask
                DefaultGateway = $Gateway
            }
        )
    }

    function Convert-CabsControlSubnetApiResult {
        param(
            $Api,
            [string]$Attempt
        )

        $sectionResults = @()
        $overallSuccess = if ($Api) { [bool]$Api.Success } else { $true }
        $needsReboot = $false

        if ($Api -and $Api.BodyJson -and $Api.BodyJson.Actions) {
            foreach ($action in @($Api.BodyJson.Actions)) {
                foreach ($r in @($action.Results)) {
                    $path = "$($r.Path)"

                    if ($r.Property -and $path -notmatch "\.$([regex]::Escape("$($r.Property)"))$") {
                        $path = "$path.$($r.Property)"
                    }

                    $sid = [int]$r.StatusId
                    $ok = $sid -in 0,1,5,-4

                    if (-not $ok) {
                        $overallSuccess = $false
                    }

                    if ($sid -eq 1 -or "$($r.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
                        $needsReboot = $true
                    }

                    $sectionResults += [pscustomobject]@{
                        Path       = $path
                        StatusId   = $sid
                        StatusInfo = "$($r.StatusInfo)"
                        Ok         = $ok
                        Attempt    = $Attempt
                    }
                }
            }
        }

        if ($Api -and -not $Api.Success) {
            $overallSuccess = $false
        }

        $bodyPreview = if ($Api -and $Api.Body) {
            $clean = ($Api.Body -replace '\s+', ' ').Trim()
            $clean.Substring(0, [Math]::Min(300, $clean.Length))
        }
        else {
            ''
        }

        [pscustomobject]@{
            OverallSuccess = $overallSuccess
            NeedsReboot    = $needsReboot
            SectionResults = $sectionResults
            BodyPreview    = $bodyPreview
        }
    }

    function Invoke-CabsControlSubnetAttempts {
        param(
            [object[]]$Attempts
        )

        $last = $null
        foreach ($attempt in @($Attempts)) {
            $apiResult = Invoke-CrestronApi -Session $Session -Path $attempt.Path -Method POST `
                                           -Body $attempt.Body -TimeoutSec $TimeoutSec
            $parsed = Convert-CabsControlSubnetApiResult -Api $apiResult -Attempt "$($attempt.Label)"
            $last = [pscustomobject]@{
                Api    = $apiResult
                Parsed = $parsed
                Label  = "$($attempt.Label)"
            }

            if ($parsed.OverallSuccess) {
                return $last
            }
        }

        return $last
    }

    $hasEnabled = $PSBoundParameters.ContainsKey('Enabled') -and $null -ne $Enabled
    $hasIpMode = $PSBoundParameters.ContainsKey('IPMode') -and -not [string]::IsNullOrWhiteSpace($IPMode)
    $hasIgmpVersion = $PSBoundParameters.ContainsKey('IgmpVersion') -and -not [string]::IsNullOrWhiteSpace($IgmpVersion)
    $hasRouterAutomaticMode = $PSBoundParameters.ContainsKey('RouterAutomaticMode') -and $null -ne $RouterAutomaticMode
    $hasRouterPrefix = $PSBoundParameters.ContainsKey('RouterPrefix') -and -not [string]::IsNullOrWhiteSpace($RouterPrefix)
    $hasRouterOnlineDelay = $PSBoundParameters.ContainsKey('RouterOnlineDelay') -and $null -ne $RouterOnlineDelay
    $hasRouterIsolationMode = $PSBoundParameters.ContainsKey('RouterIsolationMode') -and $null -ne $RouterIsolationMode
    $hasIgmpProxy = $PSBoundParameters.ContainsKey('IgmpProxyEnabled') -and $null -ne $IgmpProxyEnabled

    if (-not ($hasEnabled -or $hasIpMode -or $hasIgmpVersion -or
              $hasRouterAutomaticMode -or $hasRouterPrefix -or $hasRouterOnlineDelay -or
              $hasRouterIsolationMode -or $hasIgmpProxy)) {
        throw "Provide at least one control subnet setting to apply."
    }

    if ($hasIpMode -and $IPMode -eq 'Static') {
        foreach ($pair in @(
            @('IPAddress', $IPAddress),
            @('SubnetMask', $SubnetMask),
            @('Gateway', $Gateway)
        )) {
            if (-not (Test-CabsIpv4Address $pair[1])) {
                throw "$($pair[0]) '$($pair[1])' is not a valid IPv4 address."
            }
        }
    }

    if ($hasRouterOnlineDelay -and $RouterOnlineDelay -lt 0) {
        throw "RouterOnlineDelay must be 0 or greater."
    }

    $currentArgs = @{
        Session    = $Session
        TimeoutSec = $TimeoutSec
    }
    if ($Credential) {
        $currentArgs.Credential = $Credential
    }

    $current = Get-CrestronControlSubnetSettings @currentArgs

    if (-not $current.SupportsControlSubnet) {
        throw "Device $($Session.IP) does not expose NetworkAdapters.Adapters.ControlSubnet."
    }

    $adapterName = if ($current.ControlSubnetAdapterName) { "$($current.ControlSubnetAdapterName)" } else { 'ControlSubnet' }
    $adapterContainer = if ($current.ControlSubnetAdapterContainer) { "$($current.ControlSubnetAdapterContainer)" } else { 'Adapters' }
    $adapterContainerStyle = if ($current.ControlSubnetAdapterContainerStyle) { "$($current.ControlSubnetAdapterContainerStyle)" } else { 'Map' }
    $appliedSections = @()
    $telnetCommand = ''
    $telnetResult = $null
    $api = $null
    $bodyPreview = ''
    $needsReboot = $false
    $sectionResults = @()

    $adapterBaseBody = @{}
    if ($hasEnabled) {
        $adapterBaseBody.IsAdapterEnabled = [bool]$Enabled
    }

    $adapterPayloads = @()
    if ($adapterBaseBody.Count -gt 0 -or $hasIpMode) {
        foreach ($ipv4Payload in @(New-CabsControlSubnetIpv4Payloads)) {
            $body = @{}
            foreach ($key in @($adapterBaseBody.Keys)) {
                $body[$key] = $adapterBaseBody[$key]
            }

            if ($null -ne $ipv4Payload) {
                $body.IPv4 = $ipv4Payload
            }

            $adapterPayloads += $body
        }
    }

    $igmpVersionNames = @()
    if ($hasIgmpVersion) {
        if (-not [string]::IsNullOrWhiteSpace("$($current.IgmpVersionPropertyName)")) {
            $igmpVersionNames += "$($current.IgmpVersionPropertyName)"
        }
        $igmpVersionNames += @('IgmpVersion','IGMPVersion')
        $igmpVersionNames = @($igmpVersionNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }
    else {
        $igmpVersionNames = @('')
    }

    $networkPayloads = @()
    foreach ($adapterPayload in @($adapterPayloads)) {
        $containerNames = @('Adapters')
        if (-not [string]::IsNullOrWhiteSpace($adapterContainer)) {
            $containerNames += $adapterContainer
        }
        $containerNames = @($containerNames | Select-Object -Unique)

        foreach ($containerName in @($containerNames)) {
            foreach ($igmpName in @($igmpVersionNames)) {
                $networkAdapters = @{}
                if ($adapterPayload.Count -gt 0) {
                    if ($adapterContainerStyle -eq 'List' -and $containerName -eq $adapterContainer) {
                        $adapterListBody = @{}
                        foreach ($key in @($adapterPayload.Keys)) {
                            $adapterListBody[$key] = $adapterPayload[$key]
                        }
                        if (-not $adapterListBody.ContainsKey('Name')) {
                            $adapterListBody.Name = $adapterName
                        }
                        $networkAdapters[$containerName] = @($adapterListBody)
                    }
                    else {
                        $networkAdapters[$containerName] = @{
                            $adapterName = $adapterPayload
                        }
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($igmpName)) {
                    $networkAdapters[$igmpName] = $IgmpVersion
                }

                if ($networkAdapters.Count -gt 0) {
                    $networkPayloads += [pscustomobject]@{
                        NetworkAdapters = $networkAdapters
                        Label           = "NetworkAdapters.$containerName"
                    }
                }
            }
        }

        foreach ($igmpName in @($igmpVersionNames)) {
            $networkAdapters = @{}
            if ($adapterPayload.Count -gt 0) {
                $networkAdapters[$adapterName] = $adapterPayload
            }
            if (-not [string]::IsNullOrWhiteSpace($igmpName)) {
                $networkAdapters[$igmpName] = $IgmpVersion
            }
            if ($networkAdapters.Count -gt 0) {
                $networkPayloads += [pscustomobject]@{
                    NetworkAdapters = $networkAdapters
                    Label           = "NetworkAdapters.$adapterName"
                }
            }
        }
    }

    if ($adapterPayloads.Count -eq 0 -and $hasIgmpVersion) {
        foreach ($igmpName in @($igmpVersionNames)) {
            $networkPayloads += [pscustomobject]@{
                NetworkAdapters = @{ $igmpName = $IgmpVersion }
                Label           = "NetworkAdapters.$igmpName"
            }
        }
    }

    if ($adapterPayloads.Count -gt 0) {
        $appliedSections += "NetworkAdapters.$adapterContainer.$adapterName"
    }

    if ($hasIgmpVersion) {
        $appliedSections += 'NetworkAdapters.IgmpVersion'
    }

    $networkPayloads = @($networkPayloads | ForEach-Object {
        $json = $_.NetworkAdapters | ConvertTo-Json -Depth 12 -Compress
        [pscustomobject]@{
            NetworkAdapters = $_.NetworkAdapters
            Label           = $_.Label
            Json            = $json
        }
    } | Sort-Object Json -Unique)

    $networkAttempts = @()
    foreach ($networkPayload in @($networkPayloads)) {
        $networkAttempts += [pscustomobject]@{
            Path  = '/Device'
            Body  = @{ Device = @{ NetworkAdapters = $networkPayload.NetworkAdapters } }
            Label = "$($networkPayload.Label) via /Device"
        }
        $networkAttempts += [pscustomobject]@{
            Path  = '/Device/NetworkAdapters'
            Body  = @{ Device = @{ NetworkAdapters = $networkPayload.NetworkAdapters } }
            Label = "$($networkPayload.Label) via /Device/NetworkAdapters Device"
        }
        $networkAttempts += [pscustomobject]@{
            Path  = '/Device/NetworkAdapters'
            Body  = @{ NetworkAdapters = $networkPayload.NetworkAdapters }
            Label = "$($networkPayload.Label) via /Device/NetworkAdapters wrapped"
        }
        $networkAttempts += [pscustomobject]@{
            Path  = '/Device/NetworkAdapters'
            Body  = $networkPayload.NetworkAdapters
            Label = "$($networkPayload.Label) via /Device/NetworkAdapters direct"
        }
    }

    $routerBody = @{}

    if ($hasRouterAutomaticMode) {
        $routerBody.AutomaticMode = [bool]$RouterAutomaticMode
    }

    if ($hasRouterPrefix) {
        $routerBody.RouterPrefix = "$RouterPrefix"
    }

    if ($hasRouterOnlineDelay) {
        $routerBody.RouterOnlineDelay = [int]$RouterOnlineDelay
    }

    if ($hasRouterIsolationMode) {
        $routerBody.IsIsolationModeEnabled = [bool]$RouterIsolationMode
    }

    if ($hasIgmpProxy) {
        $proxyProperty = if (-not [string]::IsNullOrWhiteSpace($IgmpProxyPropertyName)) {
            "$IgmpProxyPropertyName"
        }
        elseif (-not [string]::IsNullOrWhiteSpace("$($current.IgmpProxyPropertyName)")) {
            "$($current.IgmpProxyPropertyName)"
        }
        else {
            ''
        }

        if ($Credential) {
            $telnetCommand = if ([bool]$IgmpProxyEnabled) { 'IGMPPROXY ON' } else { 'IGMPPROXY OFF' }
        }

        if ($proxyProperty) {
            $currentProxy = if ($current.RawRouter -and $proxyProperty) {
                $current.RawRouter.$proxyProperty
            }
            else {
                $null
            }

            if ($currentProxy -and $currentProxy.PSObject.Properties.Name -contains 'IsEnabled') {
                $routerBody[$proxyProperty] = @{ IsEnabled = [bool]$IgmpProxyEnabled }
            }
            elseif ($currentProxy -and $currentProxy.PSObject.Properties.Name -contains 'Enabled') {
                $routerBody[$proxyProperty] = @{ Enabled = [bool]$IgmpProxyEnabled }
            }
            else {
                $routerBody[$proxyProperty] = [bool]$IgmpProxyEnabled
            }
        }
        elseif (-not $Credential) {
            throw "Device $($Session.IP) does not expose a detected IGMP proxy web API property. Provide -Credential to use the IGMPPROXY telnet command fallback."
        }
    }

    if ($routerBody.Count -gt 0) {
        $appliedSections += 'Router'
    }

    $routerAttempts = @()
    if ($routerBody.Count -gt 0) {
        $routerAttempts += [pscustomobject]@{
            Path  = '/Device'
            Body  = @{ Device = @{ Router = $routerBody } }
            Label = 'Router via /Device'
        }
        $routerAttempts += [pscustomobject]@{
            Path  = '/Device/Router'
            Body  = @{ Device = @{ Router = $routerBody } }
            Label = 'Router via /Device/Router Device'
        }
        $routerAttempts += [pscustomobject]@{
            Path  = '/Device/Router'
            Body  = @{ Router = $routerBody }
            Label = 'Router via /Device/Router wrapped'
        }
        $routerAttempts += [pscustomobject]@{
            Path  = '/Device/Router'
            Body  = $routerBody
            Label = 'Router via /Device/Router direct'
        }
    }

    if ($networkAttempts.Count -eq 0 -and $routerAttempts.Count -eq 0 -and [string]::IsNullOrWhiteSpace($telnetCommand)) {
        throw "No control subnet payload was built."
    }

    $networkSuccess = ($networkAttempts.Count -eq 0)
    $routerSuccess = ($routerAttempts.Count -eq 0)

    if ($networkAttempts.Count -gt 0 -and $routerAttempts.Count -gt 0) {
        $combinedAttempts = @()
        foreach ($networkPayload in @($networkPayloads)) {
            $combinedAttempts += [pscustomobject]@{
                Path  = '/Device'
                Body  = @{
                    Device = @{
                        NetworkAdapters = $networkPayload.NetworkAdapters
                        Router = $routerBody
                    }
                }
                Label = "$($networkPayload.Label) + Router via /Device"
            }
        }

        $combined = Invoke-CabsControlSubnetAttempts -Attempts $combinedAttempts
        if ($combined) {
            $api = $combined.Api
            $sectionResults += @($combined.Parsed.SectionResults)
            if ($combined.Parsed.NeedsReboot) { $needsReboot = $true }
            if ($combined.Parsed.BodyPreview) { $bodyPreview = $combined.Parsed.BodyPreview }
            if ($combined.Parsed.OverallSuccess) {
                $networkSuccess = $true
                $routerSuccess = $true
            }
        }
    }

    if (-not $networkSuccess -and $networkAttempts.Count -gt 0) {
        $network = Invoke-CabsControlSubnetAttempts -Attempts $networkAttempts
        if ($network) {
            $api = $network.Api
            $sectionResults += @($network.Parsed.SectionResults)
            if ($network.Parsed.NeedsReboot) { $needsReboot = $true }
            if ($network.Parsed.BodyPreview) { $bodyPreview = $network.Parsed.BodyPreview }
            $networkSuccess = [bool]$network.Parsed.OverallSuccess
        }
    }

    if (-not $routerSuccess -and $routerAttempts.Count -gt 0) {
        $router = Invoke-CabsControlSubnetAttempts -Attempts $routerAttempts
        if ($router) {
            $api = $router.Api
            $sectionResults += @($router.Parsed.SectionResults)
            if ($router.Parsed.NeedsReboot) { $needsReboot = $true }
            if ($router.Parsed.BodyPreview) { $bodyPreview = $router.Parsed.BodyPreview }
            $routerSuccess = [bool]$router.Parsed.OverallSuccess
        }
    }

    $overallSuccess = [bool]($networkSuccess -and $routerSuccess)

    if (-not [string]::IsNullOrWhiteSpace($telnetCommand)) {
        try {
            $telnetResult = Invoke-CrestronTelnetCommand `
                -IP $Session.IP `
                -Credential $Credential `
                -Command $telnetCommand `
                -TimeoutSec $TimeoutSec

            $appliedSections += 'IGMPPROXY (Telnet)'
            $sectionResults += [pscustomobject]@{
                Path       = 'IGMPPROXY'
                StatusId   = 0
                StatusInfo = 'Command sent through telnet'
                Ok         = $true
            }
            if ($hasIgmpProxy -and $routerBody.Count -eq 0) {
                $overallSuccess = $overallSuccess -and $true
            }
        }
        catch {
            if ($routerBody.Count -eq 0 -or -not $routerSuccess) {
                $overallSuccess = $false
            }
            $sectionResults += [pscustomobject]@{
                Path       = 'IGMPPROXY'
                StatusId   = -1
                StatusInfo = "$($_.Exception.Message)"
                Ok         = $false
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($bodyPreview) -and $telnetResult -and $telnetResult.Output) {
        $clean = ($telnetResult.Output -replace '\s+', ' ').Trim()
        $bodyPreview = $clean.Substring(0, [Math]::Min(300, $clean.Length))
    }

    [pscustomobject]@{
        IP              = $Session.IP
        Status          = if ($api) { $api.Status } elseif ($overallSuccess) { 200 } else { 0 }
        Success         = $overallSuccess
        Setting         = 'ControlSubnet'
        AppliedSections = @($appliedSections | Select-Object -Unique)
        NeedsReboot     = $needsReboot
        SectionResults  = $sectionResults
        Response        = $bodyPreview
        Timestamp       = (Get-Date).ToString('s')
    }
}
