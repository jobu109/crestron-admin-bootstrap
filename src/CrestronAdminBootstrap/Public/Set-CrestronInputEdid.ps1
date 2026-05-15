function Set-CrestronInputEdid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [string]$EdidName,

        [ValidateSet('Copy','System','Custom')]
        [string]$EdidType = 'System',

        [int]$InputIndex = 0,

        [int]$PortIndex = 0,

        [int]$TimeoutSec = 30
    )

    $family = Get-CrestronAvApiFamily -Session $Session -TimeoutSec $TimeoutSec

    if ($family.Family -eq 'None') {
        throw "Device $($Session.IP) does not expose a supported AV API object."
    }

    if ($InputIndex -lt 0) {
        throw "InputIndex must be 0 or greater."
    }

    if ($PortIndex -lt 0) {
        throw "PortIndex must be 0 or greater."
    }

    $portObject = @{
        CurrentEdid     = $EdidName
        CurrentEdidType = $EdidType
    }

    if ($family.Family -ne 'AvioV2') {
        $portObject = @{
            Edid = @{
                ApplyEdid = @{
                    Name = $EdidName
                    Type = $EdidType
                }
            }
        }
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

    $inputObject = @{
        Ports = $ports
    }

    if ($family.Family -ne 'AvioV2') {
        $inputObject['Name'] = "input$InputIndex"
    }

    $inputs = @()
    for ($i = 0; $i -le $InputIndex; $i++) {
        if ($i -eq $InputIndex) {
            $inputs += $inputObject
        }
        else {
            $inputs += @{}
        }
    }

    if ($family.Family -eq 'AvioV2') {
        $payload = @{
            Device = @{
                AvioV2 = @{
                    Inputs = $inputs
                }
            }
        }
    }
    else {
        $payload = @{
            Device = @{
                AudioVideoInputOutput = @{
                    Inputs = $inputs
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
                        ($path -match 'AudioVideoInputOutput\.Inputs\.Inputs_0') -or
                        ($path -match 'AvioV2\.Inputs\.Inputs_0')
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
        Setting        = 'InputEdid'
        AvApiFamily    = $family.Family
        EdidName       = $EdidName
        EdidType       = $EdidType
        InputIndex     = $InputIndex
        PortIndex      = $PortIndex
        NeedsReboot    = $needsReboot
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}
