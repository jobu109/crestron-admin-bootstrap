function Set-CrestronOutputResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Auto',
            '3840x2160@60',
            '3840x2160@30',
            '1920x1080@60',
            '1920x1080@30',
            '1280x720@60'
        )]
        [string]$Resolution,

        [int]$OutputIndex = 0,

        [int]$PortIndex = 0,

        [int]$TimeoutSec = 30
    )

    $family = Get-CrestronAvApiFamily -Session $Session -TimeoutSec $TimeoutSec

    if ($family.Family -eq 'None') {
        throw "Device $($Session.IP) does not expose a supported AV API object."
    }

    if ($OutputIndex -lt 0) {
        throw "OutputIndex must be 0 or greater."
    }

    if ($PortIndex -lt 0) {
        throw "PortIndex must be 0 or greater."
    }

    $portObject = @{
        Resolution = $Resolution
    }

    $ports = @()
    for ($i = 0; $i -le $PortIndex; $i++) {
        if ($i -eq $PortIndex) {
            $ports += $portObject
        }
        else {
            $ports += @{}
        }
    }

    $outputObject = @{
        Ports = $ports
    }

    if ($family.Family -ne 'AvioV2') {
        $outputObject['Name'] = "output$OutputIndex"
    }

    $outputs = @()
    for ($i = 0; $i -le $OutputIndex; $i++) {
        if ($i -eq $OutputIndex) {
            $outputs += $outputObject
        }
        else {
            $outputs += @{}
        }
    }

    if ($family.Family -eq 'AvioV2') {
        $payload = @{
            Device = @{
                AvioV2 = @{
                    Outputs = $outputs
                }
            }
        }
    }
    else {
        $payload = @{
            Device = @{
                AudioVideoInputOutput = @{
                    Outputs = $outputs
                }
            }
        }
    }

    $api = Invoke-CrestronApi -Session $Session -Path $family.Path -Method POST -Body $payload -TimeoutSec $TimeoutSec

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

                $isParentArrayWarning =
                    (
                        ($path -match 'AudioVideoInputOutput\.Outputs\.Outputs_0') -or
                        ($path -match 'AvioV2\.Outputs\.Outputs_0')
                    ) -and
                    ($sid -eq 3)

                $ok = ($sid -in 0,1,5,-4) -or $isParentArrayWarning

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
        IP             = $Session.IP
        Status         = $api.Status
        Success        = $overallSuccess
        Setting        = 'OutputResolution'
        AvApiFamily    = $family.Family
        Resolution     = $Resolution
        OutputIndex    = $OutputIndex
        PortIndex      = $PortIndex
        NeedsReboot    = $needsReboot
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}
