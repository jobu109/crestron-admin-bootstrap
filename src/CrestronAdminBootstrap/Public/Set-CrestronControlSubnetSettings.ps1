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
    $networkAdapters = @{}
    $adapterBody = @{}
    $appliedSections = @()
    $telnetCommand = ''
    $telnetResult = $null

    if ($hasEnabled) {
        $adapterBody.IsAdapterEnabled = [bool]$Enabled
    }

    if ($hasIpMode) {
        $ipv4 = @{
            IsDhcpEnabled = ($IPMode -eq 'DHCP')
        }

        if ($IPMode -eq 'Static') {
            $ipv4.StaticAddresses = @(@{
                Address    = $IPAddress
                SubnetMask = $SubnetMask
            })
            $ipv4.StaticDefaultGateway = $Gateway
        }

        $adapterBody.IPv4 = $ipv4
    }

    if ($adapterBody.Count -gt 0) {
        $networkAdapters.Adapters = @{
            $adapterName = $adapterBody
        }
        $appliedSections += "NetworkAdapters.Adapters.$adapterName"
    }

    if ($hasIgmpVersion) {
        $networkAdapters.IgmpVersion = $IgmpVersion
        $appliedSections += 'NetworkAdapters.IgmpVersion'
    }

    $deviceBody = @{}

    if ($networkAdapters.Count -gt 0) {
        $deviceBody.NetworkAdapters = $networkAdapters
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

        if (-not $proxyProperty) {
            if (-not $Credential) {
                throw "Device $($Session.IP) does not expose a detected IGMP proxy web API property. Provide -Credential to use the IGMPPROXY telnet command fallback."
            }

            $telnetCommand = if ([bool]$IgmpProxyEnabled) { 'IGMPPROXY ON' } else { 'IGMPPROXY OFF' }
        }
        else {
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
    }

    if ($routerBody.Count -gt 0) {
        $deviceBody.Router = $routerBody
        $appliedSections += 'Router'
    }

    if ($deviceBody.Count -eq 0 -and [string]::IsNullOrWhiteSpace($telnetCommand)) {
        throw "No control subnet payload was built."
    }

    $payload = if ($deviceBody.Count -gt 0) { @{ Device = $deviceBody } } else { $null }

    $api = if ($payload) {
        Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST -Body $payload -TimeoutSec $TimeoutSec
    }
    else {
        $null
    }

    $sectionResults = @()
    $overallSuccess = if ($api) { $api.Success } else { $true }
    $needsReboot = $false

    if ($api -and $api.BodyJson -and $api.BodyJson.Actions) {
        foreach ($action in @($api.BodyJson.Actions)) {
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
                }
            }
        }
    }

    if ($api -and -not $api.Success) {
        $overallSuccess = $false
    }

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
        }
        catch {
            $overallSuccess = $false
            $sectionResults += [pscustomobject]@{
                Path       = 'IGMPPROXY'
                StatusId   = -1
                StatusInfo = "$($_.Exception.Message)"
                Ok         = $false
            }
        }
    }

    $bodyPreview = if ($api -and $api.Body) {
        $clean = ($api.Body -replace '\s+', ' ').Trim()
        $clean.Substring(0, [Math]::Min(300, $clean.Length))
    }
    elseif ($telnetResult -and $telnetResult.Output) {
        $clean = ($telnetResult.Output -replace '\s+', ' ').Trim()
        $clean.Substring(0, [Math]::Min(300, $clean.Length))
    }
    else {
        ''
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
