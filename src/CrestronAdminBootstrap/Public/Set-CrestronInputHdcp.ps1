function Set-CrestronInputHdcp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [ValidateSet('Auto','Disabled','Enabled','HDCP 1.4','HDCP 1.x','HDCP 2.x','HDCP 2.0','HDCP 2.2','Never Authenticate','NeverAuthenticate')]
        [string]$Mode,

        [int]$InputIndex = 0,

        [int]$PortIndex = 0,

        [int]$TimeoutSec = 30
    )

    $family = Get-CrestronAvApiFamily -Session $Session -TimeoutSec $TimeoutSec

    if ($family.Family -eq 'None') {
        throw "Device $($Session.IP) does not expose a supported AV API object."
    }

    $deviceMode = switch -Regex ($Mode) {
        '^Never\s*Authenticate$' { 'Disabled'; break }
        '^NeverAuthenticate$'    { 'Disabled'; break }
        '^Enabled$'              { 'Auto'; break }
        '^HDCP\s*1(\.x|\.4)?$'  { 'HDCP 1.4'; break }
        '^HDCP\s*2(\.x|\.0|\.2)?$' { 'HDCP 2.x'; break }
        default                  { $Mode }
    }

    if ($InputIndex -lt 0) {
        throw "InputIndex must be 0 or greater."
    }

    if ($PortIndex -lt 0) {
        throw "PortIndex must be 0 or greater."
    }

    $portObject = @{
        Digital = @{
            HdcpReceiverCapability = $deviceMode
        }
    }

    if ($family.Family -ne 'AvioV2') {
        $portObject = @{
            Hdmi = @{
                HdcpReceiverCapability = $deviceMode
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

                # Ignore parent array wrapper warning; the nested HDMI property result is what matters.
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
        Setting        = 'InputHdcp'
        AvApiFamily    = $family.Family
        Mode           = $Mode
        DeviceMode     = $deviceMode
        InputIndex     = $InputIndex
        PortIndex      = $PortIndex
        NeedsReboot    = $needsReboot
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}
