function Set-CrestronDisplaySettings {
    <#
    .SYNOPSIS
        Applies display brightness and screen saver settings.

    .DESCRIPTION
        Detects the device's display settings object and builds a partial payload
        using the property names already exposed by the device whenever possible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Nullable[bool]]$AutoBrightness,
        [Nullable[int]]$Brightness,
        [Nullable[bool]]$ScreensaverEnabled,
        [Nullable[int]]$StandbyTimeout,
        [Nullable[bool]]$ToolbarEnabled,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    $hasAutoBrightness = $PSBoundParameters.ContainsKey('AutoBrightness') -and $null -ne $AutoBrightness
    $hasBrightness = $PSBoundParameters.ContainsKey('Brightness') -and $null -ne $Brightness
    $hasScreensaver = $PSBoundParameters.ContainsKey('ScreensaverEnabled') -and $null -ne $ScreensaverEnabled
    $hasStandby = $PSBoundParameters.ContainsKey('StandbyTimeout') -and $null -ne $StandbyTimeout
    $hasToolbar = $PSBoundParameters.ContainsKey('ToolbarEnabled') -and $null -ne $ToolbarEnabled

    if (-not ($hasAutoBrightness -or $hasBrightness -or $hasScreensaver -or $hasStandby -or $hasToolbar)) {
        throw "Provide at least one display setting to apply."
    }

    if ($hasBrightness -and ($Brightness -lt 0 -or $Brightness -gt 100)) {
        throw "Brightness must be between 0 and 100."
    }

    if ($hasStandby -and ($StandbyTimeout -lt 0 -or $StandbyTimeout -gt 86400)) {
        throw "StandbyTimeout must be between 0 and 86400."
    }

    $display = Get-CrestronDisplayObject -Session $Session -TimeoutSec $TimeoutSec
    $screenSaver = Get-CrestronDeviceObjectByName -Session $Session -Name 'ScreenSaver' -TimeoutSec $TimeoutSec
    $toolbar = if ($hasToolbar) {
        Get-CrestronToolbarObject -Session $Session -TimeoutSec $TimeoutSec
    }
    else {
        $null
    }

    if (-not $display -and -not $screenSaver -and -not $toolbar) {
        throw "Device $($Session.IP) does not expose supported display settings."
    }

    $deviceBody = @{}
    $appliedSections = @()
    $displayBody = @{}
    $existing = if ($display) { $display.Object } else { $null }
    $lcdSectionNames = Get-CrestronDisplayLcdSectionNames

    if ($hasAutoBrightness -or $hasBrightness -or $hasStandby) {
        if (-not $display) {
            throw "Device $($Session.IP) does not expose LCD display settings."
        }
    }

    if ($hasAutoBrightness) {
        Set-CrestronDisplayBooleanMemberDeep `
            -Target $displayBody `
            -Existing $existing `
            -SectionNames $lcdSectionNames `
            -Names @('AutoBrightness','AutoBrightnessEnabled','IsAutoBrightnessEnabled','EnableAutoBrightness','AdaptiveBrightness','AutoBrightnessMode','IsAdaptiveBrightnessEnabled','AmbientLightSensor','AmbientLightSensorEnabled') `
            -DefaultName 'AutoBrightness' `
            -Value ([bool]$AutoBrightness)
    }

    if ($hasBrightness) {
        Set-CrestronDisplayIntMemberDeep `
            -Target $displayBody `
            -Existing $existing `
            -SectionNames $lcdSectionNames `
            -Names @('Brightness','BrightnessLevel','Backlight','BackLight','BacklightLevel','BackLightLevel','BacklightBrightness','ScreenBrightness','ScreenBrightnessLevel','LcdBrightness','DisplayBrightness','LCDBacklightBrightness') `
            -DefaultName 'Brightness' `
            -Value ([int]$Brightness)
    }

    if ($hasStandby) {
        Set-CrestronDisplayIntMemberDeep `
            -Target $displayBody `
            -Existing $existing `
            -SectionNames $lcdSectionNames `
            -Names @('StandbyTimeoutMinutes','StandbyTimeout','StandbyTimeOut','StandbyTimeoutSeconds','StandbyTimer','StandbyTimerMinutes','DisplayStandbyTimeout','DisplayStandbyTimeoutMinutes','DisplayOffTimeout','IdleTimeout','SleepTimeout') `
            -DefaultName 'StandbyTimeoutMinutes' `
            -Value ([int]$StandbyTimeout)
    }

    if ($displayBody.Count -gt 0) {
        $deviceBody[$display.PathName] = $displayBody
        $appliedSections += $display.PathName
    }

    if ($hasScreensaver) {
        if ($screenSaver) {
            $screenSaverBody = @{}
            Set-CrestronDisplayBooleanMember `
                -Target $screenSaverBody `
                -Existing $screenSaver.Object `
                -Names @('IsEnabled','Enabled','ScreenSaver','Screensaver','ScreenSaverEnabled','ScreensaverEnabled','ScreenSaverEnable','ScreensaverEnable','IsScreenSaverEnabled','EnableScreenSaver','EnableScreensaver') `
                -DefaultName 'IsEnabled' `
                -Value ([bool]$ScreensaverEnabled)

            $deviceBody[$screenSaver.PathName] = $screenSaverBody
            $appliedSections += $screenSaver.PathName
        }
        elseif ($display) {
            if (-not $deviceBody.ContainsKey($display.PathName)) {
                $deviceBody[$display.PathName] = $displayBody
                $appliedSections += $display.PathName
            }

            Set-CrestronDisplayBooleanMemberDeep `
                -Target $deviceBody[$display.PathName] `
                -Existing $existing `
                -SectionNames (Get-CrestronDisplayScreensaverSectionNames) `
                -Names @('ScreenSaver','Screensaver','IsEnabled','Enabled','ScreenSaverEnabled','ScreensaverEnabled','ScreenSaverEnable','ScreensaverEnable','IsScreenSaverEnabled','EnableScreenSaver','EnableScreensaver') `
                -DefaultName 'ScreenSaver' `
                -Value ([bool]$ScreensaverEnabled)
        }
        else {
            throw "Device $($Session.IP) does not expose screen saver settings."
        }
    }

    if ($hasToolbar) {
        if (-not $toolbar) {
            throw "Device $($Session.IP) does not expose supported touch panel toolbar settings."
        }

        $toolbarApplied = $false
        $displayVirtualButtons = if ($display -and $display.RawJson) {
            Get-CrestronVirtualButtonsObject -Object $display.RawJson
        }
        else {
            $null
        }

        if ($displayVirtualButtons) {
            $displaySectionName = if (-not [string]::IsNullOrWhiteSpace("$($display.PathName)")) {
                "$($display.PathName)"
            }
            else {
                'Display'
            }

            if (-not $deviceBody.ContainsKey($displaySectionName)) {
                $deviceBody[$displaySectionName] = @{}
                $appliedSections += $displaySectionName
            }

            $deviceBody[$displaySectionName]['VirtualButtons'] = New-CrestronVirtualButtonsToolbarPayload `
                -VirtualButtons $displayVirtualButtons `
                -ToolbarEnabled ([bool]$ToolbarEnabled)
            $toolbarApplied = $true
        }

        $toolbarVirtualButtons = if ($toolbar -and $toolbar.RawJson) {
            Get-CrestronVirtualButtonsObject -Object $toolbar.RawJson
        }
        else {
            $null
        }

        if (-not $toolbarApplied -and $toolbarVirtualButtons) {
            if (-not $deviceBody.ContainsKey('Display')) {
                $deviceBody['Display'] = @{}
                $appliedSections += 'Display'
            }

            $deviceBody['Display']['VirtualButtons'] = New-CrestronVirtualButtonsToolbarPayload `
                -VirtualButtons $toolbarVirtualButtons `
                -ToolbarEnabled ([bool]$ToolbarEnabled)
            $toolbarApplied = $true
        }

        if (-not $toolbarApplied) {
            if ([bool]$toolbar.IsDirectProperty) {
                Set-CrestronToolbarEnabledMemberDeep `
                    -Target $deviceBody `
                    -Existing $toolbar.Object `
                    -ToolbarEnabled ([bool]$ToolbarEnabled)
                $appliedSections += $toolbar.PathName
            }
            else {
                if (-not $deviceBody.ContainsKey($toolbar.PathName)) {
                    $deviceBody[$toolbar.PathName] = @{}
                    $appliedSections += $toolbar.PathName
                }

                Set-CrestronToolbarEnabledMemberDeep `
                    -Target $deviceBody[$toolbar.PathName] `
                    -Existing $toolbar.Object `
                    -ToolbarEnabled ([bool]$ToolbarEnabled)
            }
        }
    }

    $payload = @{ Device = $deviceBody }
    $requestPayload = try {
        $payload | ConvertTo-Json -Depth 12 -Compress
    }
    catch {
        ''
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

    if (-not $api.Success) {
        $overallSuccess = $false
    }

    $bodyPreview = if ($api.Body) {
        $clean = ($api.Body -replace '\s+', ' ').Trim()
        $clean.Substring(0, [Math]::Min(300, $clean.Length))
    }
    else {
        ''
    }

    [pscustomobject]@{
        IP              = $Session.IP
        Status          = $api.Status
        Success         = $overallSuccess
        Setting         = 'DisplaySettings'
        DisplayPath     = if ($display) { $display.Path } elseif ($screenSaver) { $screenSaver.Path } else { '' }
        ToolbarPath     = if ($toolbar) { $toolbar.Path } else { '' }
        AppliedSections = @($appliedSections | Select-Object -Unique)
        NeedsReboot     = $needsReboot
        SectionResults  = $sectionResults
        Response        = $bodyPreview
        RequestPath     = '/Device'
        RequestPayload  = $requestPayload
        Timestamp       = (Get-Date).ToString('s')
    }
}
