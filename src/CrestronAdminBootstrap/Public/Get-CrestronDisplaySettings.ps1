function Get-CrestronDisplaySettings {
    <#
    .SYNOPSIS
        Retrieves display brightness and screen saver state when the device exposes it.

    .DESCRIPTION
        Crestron firmware exposes display settings under slightly different Device
        child objects across product families. This cmdlet probes the known display
        objects, then returns a flattened state object for the GUI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    $display = Get-CrestronDisplayObject -Session $Session -TimeoutSec $TimeoutSec
    $screenSaver = Get-CrestronDeviceObjectByName -Session $Session -Name 'ScreenSaver' -TimeoutSec $TimeoutSec

    if (-not $display -and -not $screenSaver) {
        return [pscustomobject]@{
            IP                       = $Session.IP
            Model                    = $Session.Model
            SupportsDisplaySettings  = $false
            DisplayPath              = ''
            DisplayPathName          = ''
            AutoBrightness           = $null
            Brightness               = $null
            ScreensaverEnabled       = $null
            StandbyTimeout           = $null
            RawJson                  = $null
            FetchedAt                = (Get-Date).ToString('s')
        }
    }

    $obj = if ($display) { $display.Object } else { $null }
    $lcdSectionNames = Get-CrestronDisplayLcdSectionNames

    $autoBrightness = Get-CrestronDisplayBoolValueDeep -Object $obj -SectionNames $lcdSectionNames -Names @(
        'AutoBrightness',
        'AutoBrightnessEnabled',
        'IsAutoBrightnessEnabled',
        'EnableAutoBrightness',
        'AdaptiveBrightness'
    )

    $brightness = Get-CrestronDisplayIntValueDeep -Object $obj -SectionNames $lcdSectionNames -Names @(
        'Brightness',
        'BrightnessLevel',
        'BacklightBrightness',
        'ScreenBrightness',
        'LCDBacklightBrightness'
    )

    $screensaverEnabled = $null
    if ($screenSaver) {
        $screensaverEnabled = Get-CrestronDisplayBoolValue -Object $screenSaver.Object -Names @(
            'IsEnabled',
            'Enabled',
            'ScreenSaver',
            'Screensaver',
            'ScreenSaverEnabled',
            'ScreensaverEnabled',
            'IsScreenSaverEnabled',
            'EnableScreenSaver'
        )
    }

    if ($null -eq $screensaverEnabled) {
        $screensaverEnabled = Get-CrestronDisplayBoolValueDeep -Object $obj -SectionNames (Get-CrestronDisplayScreensaverSectionNames) -Names @(
            'ScreenSaver',
            'Screensaver',
            'IsEnabled',
            'Enabled',
            'ScreenSaverEnabled',
            'ScreensaverEnabled',
            'IsScreenSaverEnabled',
            'EnableScreenSaver'
        )
    }

    $standbyTimeout = Get-CrestronDisplayIntValueDeep -Object $obj -SectionNames $lcdSectionNames -Names @(
        'StandbyTimeoutMinutes',
        'StandbyTimeout',
        'StandbyTimeOut',
        'StandbyTimeoutSeconds',
        'StandbyTimer',
        'StandbyTimerMinutes',
        'DisplayStandbyTimeout',
        'DisplayStandbyTimeoutMinutes'
    )

    [pscustomobject]@{
        IP                       = $Session.IP
        Model                    = $Session.Model
        SupportsDisplaySettings  = $true
        DisplayPath              = if ($display) { $display.Path } elseif ($screenSaver) { $screenSaver.Path } else { '' }
        DisplayPathName          = if ($display) { $display.PathName } elseif ($screenSaver) { $screenSaver.PathName } else { '' }
        AutoBrightness           = $autoBrightness
        Brightness               = $brightness
        ScreensaverEnabled       = $screensaverEnabled
        StandbyTimeout           = $standbyTimeout
        RawJson                  = if ($display) { $display.RawJson } elseif ($screenSaver) { $screenSaver.RawJson } else { $null }
        FetchedAt                = (Get-Date).ToString('s')
    }
}
