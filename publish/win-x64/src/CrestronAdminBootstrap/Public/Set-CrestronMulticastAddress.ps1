function Set-CrestronMulticastAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [ValidateSet('Transmit','Receive')]
        [string]$Direction,

        [Parameter(Mandatory)]
        [ValidatePattern('^239\.(\d{1,3}\.){2}\d{1,3}$')]
        [string]$MulticastAddress,

        [int]$StreamIndex = 0,

        [int]$TimeoutSec = 30
    )

    if ($StreamIndex -lt 0) {
        throw "StreamIndex must be 0 or greater."
    }

    $octets = $MulticastAddress -split '\.'
    foreach ($octet in $octets) {
        $n = [int]$octet
        if ($n -lt 0 -or $n -gt 255) {
            throw "Invalid multicast address '$MulticastAddress'. Octets must be 0-255."
        }
    }

    $streamObject = @{
        MulticastAddress = $MulticastAddress
    }

    $streams = @()
    for ($i = 0; $i -le $StreamIndex; $i++) {
        if ($i -eq $StreamIndex) {
            $streams += $streamObject
        }
        else {
            $streams += @{}
        }
    }

    if ($Direction -eq 'Transmit') {
        $payload = @{
            Device = @{
                StreamTransmit = @{
                    Streams = $streams
                }
            }
        }

        $targetName = 'StreamTransmit'
    }
    else {
        $payload = @{
            Device = @{
                StreamReceive = @{
                    Streams = $streams
                }
            }
        }

        $targetName = 'StreamReceive'
    }

    $api = Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST -Body $payload -TimeoutSec $TimeoutSec

    $sectionResults = @()
    $overallSuccess = $api.Success
    $needsReboot = $false

    if ($api.BodyJson -and $api.BodyJson.Actions) {
        foreach ($action in @($api.BodyJson.Actions)) {
            foreach ($r in @($action.Results)) {
                $path = "$($r.Path)"

                if ($r.Property -and $path -notmatch "\.$([regex]::Escape("$($r.Property)"))$") {
                    $path = "$path.$($r.Property)"
                }

                $sid = [int]$r.StatusId
                $ok = ($sid -in 0,1,5,-4)

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

    $bodyPreview = if ($api.Body) {
        $clean = ($api.Body -replace '\s+', ' ').Trim()
        $clean.Substring(0, [Math]::Min(300, $clean.Length))
    } else {
        ''
    }

    [pscustomobject]@{
        IP               = $Session.IP
        Status           = $api.Status
        Success          = $overallSuccess
        Setting          = 'MulticastAddress'
        Direction        = $Direction
        StreamIndex      = $StreamIndex
        MulticastAddress = $MulticastAddress
        TargetObject     = $targetName
        NeedsReboot      = $needsReboot
        SectionResults   = $sectionResults
        Response         = $bodyPreview
        Timestamp        = (Get-Date).ToString('s')
    }
}