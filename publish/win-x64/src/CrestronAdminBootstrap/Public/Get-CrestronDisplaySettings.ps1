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
    $toolbar = Get-CrestronToolbarObject -Session $Session -TimeoutSec $TimeoutSec

    if (-not $display -and -not $screenSaver -and -not $toolbar) {
        return [pscustomobject]@{
            IP                       = $Session.IP
            Model                    = $Session.Model
            SupportsDisplaySettings  = $false
            SupportsToolbarSettings  = $false
            DisplayPath              = ''
            DisplayPathName          = ''
            ToolbarPath              = ''
            ToolbarPathName          = ''
            AutoBrightness           = $null
            Brightness               = $null
            ScreensaverEnabled       = $null
            StandbyTimeout           = $null
            ToolbarEnabled           = $null
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
        'AdaptiveBrightness',
        'AutoBrightnessMode',
        'IsAdaptiveBrightnessEnabled',
        'AmbientLightSensor',
        'AmbientLightSensorEnabled'
    )

    $brightness = Get-CrestronDisplayIntValueDeep -Object $obj -SectionNames $lcdSectionNames -Names @(
        'Brightness',
        'BrightnessLevel',
        'Backlight',
        'BackLight',
        'BacklightLevel',
        'BackLightLevel',
        'BacklightBrightness',
        'ScreenBrightness',
        'ScreenBrightnessLevel',
        'LcdBrightness',
        'DisplayBrightness',
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
            'ScreenSaverEnable',
            'ScreensaverEnable',
            'IsScreenSaverEnabled',
            'EnableScreenSaver',
            'EnableScreensaver'
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
            'ScreenSaverEnable',
            'ScreensaverEnable',
            'IsScreenSaverEnabled',
            'EnableScreenSaver',
            'EnableScreensaver'
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
        'DisplayStandbyTimeoutMinutes',
        'DisplayOffTimeout',
        'IdleTimeout',
        'SleepTimeout'
    )

    $toolbarEnabled = if ($toolbar) {
        Get-CrestronToolbarBoolValue -Object $toolbar.Object
    }
    else {
        $null
    }
    if ($null -eq $toolbarEnabled -and $toolbar -and $toolbar.RawJson) {
        $toolbarEnabled = Get-CrestronVirtualButtonsToolbarBoolValue -Object $toolbar.RawJson
    }
    if ($null -eq $toolbarEnabled -and $display -and $display.RawJson) {
        $toolbarEnabled = Get-CrestronVirtualButtonsToolbarBoolValue -Object $display.RawJson
    }
    $modelLooksToolbarCapable = "$($Session.Model)".Trim().ToUpperInvariant() -match '^(TS|TSW|TSS|TST|DGE)(-|$)'
    $familyLooksToolbarCapable = "$($Session.DeviceFamily)" -match '(?i)touch|panel|display'
    $supportsToolbarSettings = [bool]$toolbar -and (
        ($null -ne $toolbarEnabled) -or
        $modelLooksToolbarCapable -or
        $familyLooksToolbarCapable
    )

    [pscustomobject]@{
        IP                       = $Session.IP
        Model                    = $Session.Model
        SupportsDisplaySettings  = [bool]($display -or $screenSaver)
        SupportsToolbarSettings  = [bool]$supportsToolbarSettings
        DisplayPath              = if ($display) { $display.Path } elseif ($screenSaver) { $screenSaver.Path } else { '' }
        DisplayPathName          = if ($display) { $display.PathName } elseif ($screenSaver) { $screenSaver.PathName } else { '' }
        ToolbarPath              = if ($toolbar) { $toolbar.Path } else { '' }
        ToolbarPathName          = if ($toolbar) { $toolbar.PathName } else { '' }
        AutoBrightness           = $autoBrightness
        Brightness               = $brightness
        ScreensaverEnabled       = $screensaverEnabled
        StandbyTimeout           = $standbyTimeout
        ToolbarEnabled           = $toolbarEnabled
        RawJson                  = if ($display) { $display.RawJson } elseif ($screenSaver) { $screenSaver.RawJson } elseif ($toolbar) { $toolbar.RawJson } else { $null }
        FetchedAt                = (Get-Date).ToString('s')
    }
}
