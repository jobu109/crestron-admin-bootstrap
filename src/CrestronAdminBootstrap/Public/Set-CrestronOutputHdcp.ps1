function Set-CrestronOutputHdcp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [ValidateSet('Auto','FollowInput','ForceHighest','NeverAuthenticate')]
        [string]$Mode,

        [int]$TimeoutSec = 30
    )

    $family = Get-CrestronAvApiFamily -Session $Session -TimeoutSec $TimeoutSec

    if ($family.Family -eq 'None') {
        throw "Device $($Session.IP) does not expose a supported AV API object."
    }

    # Friendly parameter names -> documented / device-facing values.
    $deviceMode = switch ($Mode) {
        'Auto'              { 'Auto' }
        'FollowInput'       { 'Follow Input' }
        'ForceHighest'      { 'Force Highest' }
        'NeverAuthenticate' { 'Never Authenticate' }
    }

    if ($family.Family -eq 'AvioV2') {
        $payload = @{
            Device = @{
                AvioV2 = @{
                    Outputs = @(
                        @{
                            Ports = @(
                                @{
                                    Digital = @{
                                        HdcpTransmitterMode = $deviceMode
                                    }
                                }
                            )
                        }
                    )
                }
            }
        }
    }
    else {
        $payload = @{
            Device = @{
                AudioVideoInputOutput = @{
                    Outputs = @(
                        @{
                            Name = 'output0'
                            Ports = @(
                                @{
                                    Hdmi = @{
                                        HdcpTransmitterMode = $deviceMode
                                    }
                                }
                            )
                        }
                    )
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
        Setting        = 'OutputHdcp'
        AvApiFamily    = $family.Family
        Mode           = $Mode
        DeviceMode     = $deviceMode
        NeedsReboot    = $needsReboot
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}