function Set-CrestronHostname {
    <#
    .SYNOPSIS
        Changes the device hostname on a Crestron 4-Series device.

    .DESCRIPTION
        POSTs a partial NetworkAdapters payload to /Device with only the
        HostName field changed. Lighter than Set-CrestronNetwork when only
        hostname needs to change.

        Validates per RFC 1123 / standard hostname rules: 1-63 chars,
        letters/digits/hyphens, must not start or end with hyphen.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER Hostname
        New hostname. Will be sent verbatim; no domain suffix is appended.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 30.

    .OUTPUTS
        PSCustomObject: IP, Status, Success, Hostname, NeedsReboot,
        SectionResults, Response, Timestamp.

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 172.22.0.21 -Credential $cred
        Set-CrestronHostname -Session $session -Hostname 'CR-101-TS1070'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Hostname,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    # Hostname validation
    if ($Hostname.Length -lt 1 -or $Hostname.Length -gt 63) {
        throw "Hostname must be 1-63 characters. Got $($Hostname.Length)."
    }
    if ($Hostname -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$') {
        throw "Hostname '$Hostname' is invalid. Allowed: letters, digits, hyphens. Must not start or end with a hyphen."
    }

    function Convert-CabsHostnameResult {
        param($Api)

        $sectionResults = @()
        $overallSuccess = $true
        $needsReboot    = $false

        if ($Api.BodyJson -and $Api.BodyJson.Actions) {
            foreach ($action in $Api.BodyJson.Actions) {
                foreach ($r in @($action.Results)) {
                    $rPath = "$($r.Path)$(if ($r.Property) { '.' + $r.Property } else { '' })"
                    $sid   = [int]$r.StatusId
                    $rOk   = $sid -in 0,1,5,-4
                    if (-not $rOk) { $overallSuccess = $false }
                    if ($sid -eq 1 -or "$($r.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
                        $needsReboot = $true
                    }
                    $sectionResults += [pscustomobject]@{
                        Path       = $rPath
                        StatusId   = $sid
                        StatusInfo = $r.StatusInfo
                        Ok         = $rOk
                    }
                }
            }
        }
        else {
            $overallSuccess = $Api.Success
        }

        if (-not $Api.Success) { $overallSuccess = $false }
        if ($overallSuccess -and -not $needsReboot) {
            $needsReboot = $true
        }

        $bodyPreview = if ($Api.Body) {
            $clean = ($Api.Body -replace '\s+', ' ').Trim()
            $clean.Substring(0, [Math]::Min(300, $clean.Length))
        } else { '' }

        [pscustomobject]@{
            OverallSuccess = $overallSuccess
            NeedsReboot    = $needsReboot
            SectionResults = $sectionResults
            BodyPreview    = $bodyPreview
        }
    }

    $hasNetworkAdapters = $false
    $hasEthernet = $false

    try {
        $currentApi = Invoke-CrestronApi -Session $Session -Path '/Device/NetworkAdapters' -Method GET -TimeoutSec $TimeoutSec
        $hasNetworkAdapters = [bool]($currentApi.Success -and $currentApi.BodyJson.Device.NetworkAdapters)
    } catch { }

    if (-not $hasNetworkAdapters) {
        try {
            $ethernetApi = Invoke-CrestronApi -Session $Session -Path '/Device/Ethernet' -Method GET -TimeoutSec $TimeoutSec
            $hasEthernet = [bool]($ethernetApi.Success -and
                $ethernetApi.BodyJson -and
                $ethernetApi.BodyJson.Device -and
                $ethernetApi.BodyJson.Device.Ethernet -and
                -not ($ethernetApi.BodyJson.Device.Ethernet -is [string]))
        } catch { }
    }

    $attempts = if ($hasNetworkAdapters) {
        @([pscustomobject]@{
            Path = '/Device'
            Body = @{
                Device = @{
                    NetworkAdapters = @{
                        HostName = $Hostname
                    }
                }
            }
            WritePath = 'NetworkAdapters'
        })
    }
    elseif ($hasEthernet) {
        @(
            [pscustomobject]@{
                Path = '/Device'
                Body = @{
                    Device = @{
                        Ethernet = @{
                            HostName = $Hostname
                        }
                    }
                }
                WritePath = 'Ethernet'
            },
            [pscustomobject]@{
                Path = '/Device/Ethernet'
                Body = @{
                    Device = @{
                        Ethernet = @{
                            HostName = $Hostname
                        }
                    }
                }
                WritePath = 'Ethernet'
            },
            [pscustomobject]@{
                Path = '/Device/Ethernet'
                Body = @{
                    Ethernet = @{
                        HostName = $Hostname
                    }
                }
                WritePath = 'Ethernet'
            },
            [pscustomobject]@{
                Path = '/Device/Ethernet'
                Body = @{
                    HostName = $Hostname
                }
                WritePath = 'Ethernet'
            }
        )
    }
    else {
        throw "Device $($Session.IP) does not expose NetworkAdapters or Ethernet hostname settings."
    }

    $api = $null
    $parsed = $null
    $writePath = ''

    foreach ($attempt in $attempts) {
        $api = Invoke-CrestronApi -Session $Session -Path $attempt.Path -Method POST `
                                  -Body $attempt.Body -TimeoutSec $TimeoutSec
        $parsed = Convert-CabsHostnameResult $api
        $writePath = "$($attempt.WritePath)"
        if ($parsed.OverallSuccess) { break }
    }

    [pscustomobject]@{
        IP             = $Session.IP
        Status         = $api.Status
        Success        = $parsed.OverallSuccess
        Hostname       = $Hostname
        NeedsReboot    = $parsed.NeedsReboot
        WritePath      = $writePath
        SectionResults = $parsed.SectionResults
        Response       = $parsed.BodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}
