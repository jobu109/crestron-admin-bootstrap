function Set-CrestronGlobalEdid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [Parameter(Mandatory)]
        [string]$EdidName,

        [Parameter(Mandatory)]
        [ValidateSet('Copy','System','Custom')]
        [string]$EdidType,

        [int]$TimeoutSec = 30
    )

    $family = Get-CrestronAvApiFamily -Session $Session -TimeoutSec $TimeoutSec

    if ($family.Family -eq 'None') {
        throw "Device $($Session.IP) does not expose a supported AV API object."
    }

    if ($family.Family -eq 'AvioV2') {
        $payload = @{
            Device = @{
                AvioV2 = @{
                    GlobalConfig = @{
                        GlobalEdid     = $EdidName
                        GlobalEdidType = $EdidType
                    }
                }
            }
        }
    }
    else {
        $avApi = Invoke-CrestronApi -Session $Session -Path '/Device/AudioVideoInputOutput' -Method GET -TimeoutSec $TimeoutSec
        $versionText = "$($avApi.BodyJson.Device.AudioVideoInputOutput.Version)"

        try {
            $version = [version]$versionText
        }
        catch {
            $version = [version]'0.0.0'
        }

        if ($version -lt [version]'2.5.0') {
            return [pscustomobject]@{
                IP             = $Session.IP
                Status         = 0
                Success        = $false
                Setting        = 'GlobalEdid'
                AvApiFamily    = $family.Family
                EdidName       = $EdidName
                EdidType       = $EdidType
                NeedsReboot    = $false
                SectionResults = @(
                    [pscustomobject]@{
                        Path       = 'Device.AudioVideoInputOutput.GlobalConfig'
                        StatusId   = 3
                        StatusInfo = "Global EDID write requires AudioVideoInputOutput 2.5.0 or newer. Device reports $versionText."
                        Ok         = $false
                    }
                )
                Response       = ''
                Timestamp      = (Get-Date).ToString('s')
            }
        }

        $payload = @{
            Device = @{
                AudioVideoInputOutput = @{
                    GlobalConfig = @{
                        GlobalEdid     = $EdidName
                        GlobalEdidType = $EdidType
                    }
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
        IP             = $Session.IP
        Status         = $api.Status
        Success        = $overallSuccess
        Setting        = 'GlobalEdid'
        AvApiFamily    = $family.Family
        EdidName       = $EdidName
        EdidType       = $EdidType
        NeedsReboot    = $needsReboot
        SectionResults = $sectionResults
        Response       = $bodyPreview
        Timestamp      = (Get-Date).ToString('s')
    }
}