function Get-CrestronObjectProperty {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($prop in @($Object.PSObject.Properties)) {
        if ($prop.Name -ieq $Name) {
            return $prop.Value
        }
    }

    return $null
}

function Get-CrestronFirstPropertyName {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        foreach ($prop in @($Object.PSObject.Properties)) {
            if ($prop.Name -ieq $name) {
                return $prop.Name
            }
        }
    }

    return $null
}

function ConvertFrom-CrestronDisplayBool {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($Value -is [int] -or $Value -is [long]) {
        return ([int]$Value -ne 0)
    }

    $text = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    switch -Regex ($text) {
        '^(true|yes|on|enabled|enable|1)$'       { return $true }
        '^(false|no|off|disabled|disable|0)$'    { return $false }
        default                                  { return $null }
    }
}

function Get-CrestronDisplayNestedValue {
    param(
        $Value,
        [Parameter(Mandatory)][string[]]$SubPropertyNames
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string] -or $Value.GetType().IsPrimitive) {
        return $Value
    }

    $subName = Get-CrestronFirstPropertyName -Object $Value -Names $SubPropertyNames
    if ($subName) {
        return (Get-CrestronObjectProperty -Object $Value -Name $subName)
    }

    return $null
}

function Get-CrestronDisplayBoolValue {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    $subNames = @('IsEnabled','Enabled','Value','State','Mode','IsActive','IsOn')

    foreach ($name in $Names) {
        $value = Get-CrestronObjectProperty -Object $Object -Name $name
        if ($null -eq $value) {
            continue
        }

        $nested = Get-CrestronDisplayNestedValue -Value $value -SubPropertyNames $subNames
        $converted = ConvertFrom-CrestronDisplayBool $nested
        if ($null -ne $converted) {
            return $converted
        }
    }

    return $null
}

function Get-CrestronDisplayIntValue {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    $subNames = @('Value','CurrentValue','Level','Brightness','Percent','Percentage','Timeout','TimeoutMinutes','TimeoutSeconds','TimeoutSec','Minutes','Seconds','Duration','Delay')

    foreach ($name in $Names) {
        $value = Get-CrestronObjectProperty -Object $Object -Name $name
        if ($null -eq $value) {
            continue
        }

        $nested = Get-CrestronDisplayNestedValue -Value $value -SubPropertyNames $subNames
        if ($null -eq $nested) {
            continue
        }

        $number = 0
        if ([int]::TryParse("$nested", [ref]$number)) {
            return $number
        }
    }

    return $null
}

function Get-CrestronDisplayChildObject {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    $name = Get-CrestronFirstPropertyName -Object $Object -Names $Names
    if (-not $name) {
        return $null
    }

    $value = Get-CrestronObjectProperty -Object $Object -Name $name
    if ($null -eq $value) {
        return $null
    }

    if ($value -is [string] -or $value.GetType().IsPrimitive) {
        return $null
    }

    [pscustomobject]@{
        Name   = $name
        Object = $value
    }
}

function Test-CrestronDisplayComplexValue {
    param($Value)

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [string] -or $Value.GetType().IsPrimitive) {
        return $false
    }

    return $true
}

function Get-CrestronDisplayBoolValuesRecursive {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names,
        [int]$MaxDepth = 8
    )

    if ($null -eq $Object -or $MaxDepth -lt 0) {
        return @()
    }

    if (-not (Test-CrestronDisplayComplexValue $Object)) {
        return @()
    }

    $values = @()
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string]) -and -not ($Object -is [System.Collections.IDictionary])) {
        foreach ($item in @($Object)) {
            $values += @(Get-CrestronDisplayBoolValuesRecursive -Object $item -Names $Names -MaxDepth ($MaxDepth - 1))
        }
        return @($values)
    }

    foreach ($prop in @($Object.PSObject.Properties)) {
        $nameMatches = @($Names | Where-Object { $_ -ieq $prop.Name }).Count -gt 0
        if ($nameMatches) {
            $nested = Get-CrestronDisplayNestedValue -Value $prop.Value -SubPropertyNames @('IsEnabled','Enabled','Value','State','Mode','IsActive','IsOn')
            $converted = ConvertFrom-CrestronDisplayBool $nested
            if ($null -ne $converted) {
                $values += [bool]$converted
            }
        }

        if (Test-CrestronDisplayComplexValue $prop.Value) {
            $values += @(Get-CrestronDisplayBoolValuesRecursive -Object $prop.Value -Names $Names -MaxDepth ($MaxDepth - 1))
        }
    }

    return @($values)
}

function Test-CrestronDisplayMemberRecursive {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names,
        [int]$MaxDepth = 8
    )

    if ($null -eq $Object -or $MaxDepth -lt 0) {
        return $false
    }

    if (-not (Test-CrestronDisplayComplexValue $Object)) {
        return $false
    }

    if (Get-CrestronFirstPropertyName -Object $Object -Names $Names) {
        return $true
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string]) -and -not ($Object -is [System.Collections.IDictionary])) {
        foreach ($item in @($Object)) {
            if (Test-CrestronDisplayMemberRecursive -Object $item -Names $Names -MaxDepth ($MaxDepth - 1)) {
                return $true
            }
        }
        return $false
    }

    foreach ($prop in @($Object.PSObject.Properties)) {
        if (-not (Test-CrestronDisplayComplexValue $prop.Value)) {
            continue
        }

        if (Test-CrestronDisplayMemberRecursive -Object $prop.Value -Names $Names -MaxDepth ($MaxDepth - 1)) {
            return $true
        }
    }

    return $false
}

function Get-CrestronVirtualButtonsObject {
    param(
        $Object,
        [int]$MaxDepth = 8
    )

    if ($null -eq $Object -or $MaxDepth -lt 0 -or -not (Test-CrestronDisplayComplexValue $Object)) {
        return $null
    }

    $direct = Get-CrestronObjectProperty -Object $Object -Name 'VirtualButtons'
    if (Test-CrestronDisplayComplexValue $direct) {
        return $direct
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string]) -and -not ($Object -is [System.Collections.IDictionary])) {
        foreach ($item in @($Object)) {
            $found = Get-CrestronVirtualButtonsObject -Object $item -MaxDepth ($MaxDepth - 1)
            if ($found) {
                return $found
            }
        }
        return $null
    }

    foreach ($prop in @($Object.PSObject.Properties)) {
        if (-not (Test-CrestronDisplayComplexValue $prop.Value)) {
            continue
        }

        $found = Get-CrestronVirtualButtonsObject -Object $prop.Value -MaxDepth ($MaxDepth - 1)
        if ($found) {
            return $found
        }
    }

    return $null
}

function Get-CrestronVirtualButtonsToolbarBoolValue {
    param($Object)

    $virtualButtons = Get-CrestronVirtualButtonsObject -Object $Object
    if (-not $virtualButtons) {
        return $null
    }

    $value = Get-CrestronDisplayBoolValue -Object $virtualButtons -Names @(
        'IsEnabled',
        'Enabled',
        'Enable',
        'IsVisible',
        'Visible',
        'Show',
        'Value',
        'State'
    )
    if ($null -ne $value) {
        return $value
    }

    $value = Get-CrestronDisplayBoolValue -Object $virtualButtons -Names (Get-CrestronToolbarWakeConditionPropertyNames)
    if ($null -ne $value) {
        return $value
    }

    $value = Get-CrestronDisplayBoolValue -Object $virtualButtons -Names (Get-CrestronToolbarStandbyConditionPropertyNames)
    if ($null -ne $value) {
        return $value
    }

    return $null
}

function Get-CrestronDisplayLcdSectionNames {
    @(
        'Lcd',
        'LCD',
        'LcdSettings',
        'DisplayLcd',
        'DisplayLCD',
        'Panel',
        'TouchPanel',
        'Touchpanel',
        'TouchScreen',
        'Touchscreen',
        'Screen',
        'Backlight',
        'BackLight',
        'BacklightControl',
        'BackLightControl',
        'DisplaySettings'
    )
}

function Get-CrestronDisplayScreensaverSectionNames {
    @(
        'ScreenSaver',
        'Screensaver',
        'ScreenSaverSettings',
        'ScreensaverSettings',
        'ScreenSaverAndStandby',
        'ScreensaverAndStandby',
        'ScreenSaverStandby',
        'Standby',
        'Power',
        'PowerSettings',
        'DisplayPower',
        'DisplayPowerSettings',
        'Idle'
    )
}

function Get-CrestronToolbarSectionNames {
    @(
        'Toolbar',
        'ToolBar',
        'ToolbarSettings',
        'ToolBarSettings',
        'ButtonToolbar',
        'ButtonToolBar',
        'ButtonToolbarSettings',
        'ButtonToolBarSettings',
        'VirtualToolbar',
        'VirtualToolBar',
        'VirtualToolbarSettings',
        'VirtualToolBarSettings',
        'VirtualButtonToolbar',
        'VirtualButtonToolBar',
        'VirtualButtons',
        'VirtualButtonSettings',
        'OnScreenToolbar',
        'OnScreenToolBar',
        'SoftToolbar',
        'SoftToolBar',
        'SoftButtonToolbar',
        'SoftButtonToolBar',
        'ProjectToolbar',
        'ProjectToolBar',
        'UserProjectToolbar',
        'UserProjectToolBar',
        'UserToolbar',
        'UserToolBar',
        'NavigationBar',
        'NavBar',
        'UserInterface',
        'TouchScreen',
        'Touchscreen',
        'TouchPanel',
        'Touchpanel',
        'Display',
        'DisplaySettings',
        'Screen'
    )
}

function Get-CrestronToolbarDirectPropertyNames {
    @(
        'Toolbar',
        'ToolBar',
        'ButtonToolbar',
        'ButtonToolBar',
        'VirtualToolbar',
        'VirtualToolBar',
        'VirtualButtonToolbar',
        'VirtualButtonToolBar',
        'OnScreenToolbar',
        'OnScreenToolBar',
        'SoftToolbar',
        'SoftToolBar',
        'SoftButtonToolbar',
        'SoftButtonToolBar',
        'DisplayToolbar',
        'DisplayToolBar',
        'ProjectToolbar',
        'ProjectToolBar',
        'UserProjectToolbar',
        'UserProjectToolBar',
        'UserToolbar',
        'UserToolBar',
        'NavigationBar',
        'NavBar'
    )
}

function Get-CrestronToolbarPropertyNames {
    @(
        'ToolbarEnabled',
        'ToolBarEnabled',
        'IsToolbarEnabled',
        'IsToolBarEnabled',
        'EnableToolbar',
        'EnableToolBar',
        'ShowToolbar',
        'ShowToolBar',
        'ToolbarVisible',
        'ToolBarVisible',
        'ToolbarButtonEnabled',
        'ToolBarButtonEnabled',
        'ToolbarButtonVisible',
        'ToolBarButtonVisible',
        'ShowToolbarButton',
        'ShowToolBarButton',
        'ButtonToolbarEnabled',
        'ButtonToolBarEnabled',
        'IsButtonToolbarEnabled',
        'IsButtonToolBarEnabled',
        'EnableButtonToolbar',
        'EnableButtonToolBar',
        'ShowButtonToolbar',
        'ShowButtonToolBar',
        'ButtonToolbarVisible',
        'ButtonToolBarVisible',
        'VirtualToolbarEnabled',
        'VirtualToolBarEnabled',
        'IsVirtualToolbarEnabled',
        'IsVirtualToolBarEnabled',
        'EnableVirtualToolbar',
        'EnableVirtualToolBar',
        'ShowVirtualToolbar',
        'ShowVirtualToolBar',
        'VirtualToolbarVisible',
        'VirtualToolBarVisible',
        'VirtualButtonToolbarEnabled',
        'VirtualButtonToolBarEnabled',
        'ShowVirtualButtonToolbar',
        'ShowVirtualButtonToolBar',
        'OnScreenToolbarEnabled',
        'OnScreenToolBarEnabled',
        'ShowOnScreenToolbar',
        'ShowOnScreenToolBar',
        'SoftToolbarEnabled',
        'SoftToolBarEnabled',
        'ShowSoftToolbar',
        'ShowSoftToolBar',
        'SoftButtonToolbarEnabled',
        'SoftButtonToolBarEnabled',
        'ShowSoftButtonToolbar',
        'ShowSoftButtonToolBar',
        'DisplayToolbar',
        'DisplayToolBar',
        'DisplayToolbarEnabled',
        'DisplayToolbarVisible',
        'DisplayToolBarVisible',
        'ProjectToolbarEnabled',
        'ProjectToolBarEnabled',
        'ProjectToolbarVisible',
        'ProjectToolBarVisible',
        'ShowProjectToolbar',
        'ShowProjectToolBar',
        'UserProjectToolbarEnabled',
        'UserProjectToolBarEnabled',
        'UserProjectToolbarVisible',
        'UserProjectToolBarVisible',
        'ShowUserProjectToolbar',
        'ShowUserProjectToolBar',
        'UserToolbarEnabled',
        'UserToolBarEnabled',
        'UserToolbarVisible',
        'UserToolBarVisible',
        'ShowUserToolbar',
        'ShowUserToolBar',
        'NavigationBarEnabled',
        'NavBarEnabled',
        'ShowNavigationBar',
        'ShowNavBar',
        'ApplicationToolbarEnabled',
        'ApplicationToolBarEnabled',
        'AppToolbarEnabled',
        'AppToolBarEnabled',
        'ShowApplicationToolbar',
        'ShowApplicationToolBar',
        'ShowAppToolbar',
        'ShowAppToolBar'
    )
}

function Get-CrestronToolbarDisabledPropertyNames {
    @(
        'ToolbarDisabled',
        'ToolBarDisabled',
        'IsToolbarDisabled',
        'IsToolBarDisabled',
        'DisableToolbar',
        'DisableToolBar',
        'ToolbarDisable',
        'ToolBarDisable',
        'HideToolbar',
        'HideToolBar',
        'ToolbarHidden',
        'ToolBarHidden',
        'IsToolbarHidden',
        'IsToolBarHidden',
        'ToolbarButtonDisabled',
        'ToolBarButtonDisabled',
        'DisableToolbarButton',
        'DisableToolBarButton',
        'HideToolbarButton',
        'HideToolBarButton',
        'ToolbarButtonHidden',
        'ToolBarButtonHidden',
        'ButtonToolbarDisabled',
        'ButtonToolBarDisabled',
        'IsButtonToolbarDisabled',
        'IsButtonToolBarDisabled',
        'DisableButtonToolbar',
        'DisableButtonToolBar',
        'HideButtonToolbar',
        'HideButtonToolBar',
        'ButtonToolbarHidden',
        'ButtonToolBarHidden',
        'VirtualToolbarDisabled',
        'VirtualToolBarDisabled',
        'IsVirtualToolbarDisabled',
        'IsVirtualToolBarDisabled',
        'DisableVirtualToolbar',
        'DisableVirtualToolBar',
        'HideVirtualToolbar',
        'HideVirtualToolBar',
        'VirtualToolbarHidden',
        'VirtualToolBarHidden',
        'VirtualButtonToolbarDisabled',
        'VirtualButtonToolBarDisabled',
        'DisableVirtualButtonToolbar',
        'DisableVirtualButtonToolBar',
        'HideVirtualButtonToolbar',
        'HideVirtualButtonToolBar',
        'OnScreenToolbarDisabled',
        'OnScreenToolBarDisabled',
        'DisableOnScreenToolbar',
        'DisableOnScreenToolBar',
        'HideOnScreenToolbar',
        'HideOnScreenToolBar',
        'SoftToolbarDisabled',
        'SoftToolBarDisabled',
        'DisableSoftToolbar',
        'DisableSoftToolBar',
        'HideSoftToolbar',
        'HideSoftToolBar',
        'SoftButtonToolbarDisabled',
        'SoftButtonToolBarDisabled',
        'DisableSoftButtonToolbar',
        'DisableSoftButtonToolBar',
        'HideSoftButtonToolbar',
        'HideSoftButtonToolBar',
        'DisplayToolbarDisabled',
        'DisplayToolBarDisabled',
        'DisableDisplayToolbar',
        'DisableDisplayToolBar',
        'HideDisplayToolbar',
        'HideDisplayToolBar',
        'DisplayToolbarHidden',
        'DisplayToolBarHidden',
        'ProjectToolbarDisabled',
        'ProjectToolBarDisabled',
        'DisableProjectToolbar',
        'DisableProjectToolBar',
        'HideProjectToolbar',
        'HideProjectToolBar',
        'ProjectToolbarHidden',
        'ProjectToolBarHidden',
        'UserProjectToolbarDisabled',
        'UserProjectToolBarDisabled',
        'DisableUserProjectToolbar',
        'DisableUserProjectToolBar',
        'HideUserProjectToolbar',
        'HideUserProjectToolBar',
        'UserProjectToolbarHidden',
        'UserProjectToolBarHidden',
        'UserToolbarDisabled',
        'UserToolBarDisabled',
        'DisableUserToolbar',
        'DisableUserToolBar',
        'HideUserToolbar',
        'HideUserToolBar',
        'UserToolbarHidden',
        'UserToolBarHidden',
        'NavigationBarDisabled',
        'NavBarDisabled',
        'DisableNavigationBar',
        'DisableNavBar',
        'HideNavigationBar',
        'HideNavBar',
        'NavigationBarHidden',
        'NavBarHidden',
        'ApplicationToolbarDisabled',
        'ApplicationToolBarDisabled',
        'DisableApplicationToolbar',
        'DisableApplicationToolBar',
        'HideApplicationToolbar',
        'HideApplicationToolBar',
        'AppToolbarDisabled',
        'AppToolBarDisabled',
        'DisableAppToolbar',
        'DisableAppToolBar',
        'HideAppToolbar',
        'HideAppToolBar'
    )
}

function Get-CrestronToolbarGenericPropertyNames {
    @(
        'IsEnabled',
        'Enabled',
        'Enable',
        'IsVisible',
        'Visible',
        'Show',
        'Value',
        'State'
    )
}

function Get-CrestronToolbarWakeConditionPropertyNames {
    @(
        'ShowOnWake',
        'IsShowOnWakeEnabled',
        'ShowOnPanelWake',
        'IsShowOnPanelWakeEnabled',
        'ShowToolbarOnWake',
        'ShowToolBarOnWake',
        'IsShowToolbarOnWakeEnabled',
        'IsShowToolBarOnWakeEnabled',
        'ShowToolbarOnPanelWake',
        'ShowToolBarOnPanelWake',
        'IsShowToolbarOnPanelWakeEnabled',
        'IsShowToolBarOnPanelWakeEnabled',
        'ShowButtonToolbarOnWake',
        'ShowButtonToolBarOnWake',
        'IsShowButtonToolbarOnWakeEnabled',
        'IsShowButtonToolBarOnWakeEnabled',
        'ShowButtonToolbarOnPanelWake',
        'ShowButtonToolBarOnPanelWake',
        'IsShowButtonToolbarOnPanelWakeEnabled',
        'IsShowButtonToolBarOnPanelWakeEnabled',
        'ShowVirtualToolbarOnWake',
        'ShowVirtualToolBarOnWake',
        'IsShowVirtualToolbarOnWakeEnabled',
        'IsShowVirtualToolBarOnWakeEnabled',
        'ShowVirtualToolbarOnPanelWake',
        'ShowVirtualToolBarOnPanelWake',
        'IsShowVirtualToolbarOnPanelWakeEnabled',
        'IsShowVirtualToolBarOnPanelWakeEnabled',
        'ShowVirtualButtonToolbarOnWake',
        'ShowVirtualButtonToolBarOnWake',
        'IsShowVirtualButtonToolbarOnWakeEnabled',
        'IsShowVirtualButtonToolBarOnWakeEnabled',
        'ShowVirtualButtonToolbarOnPanelWake',
        'ShowVirtualButtonToolBarOnPanelWake',
        'IsShowVirtualButtonToolbarOnPanelWakeEnabled',
        'IsShowVirtualButtonToolBarOnPanelWakeEnabled'
    )
}

function Get-CrestronToolbarStandbyConditionPropertyNames {
    @(
        'ShowOnStandby',
        'IsShowOnStandbyEnabled',
        'ShowInStandby',
        'IsShowInStandbyEnabled',
        'ShowWhileInStandby',
        'IsShowWhileInStandbyEnabled',
        'ShowDuringStandby',
        'IsShowDuringStandbyEnabled',
        'ShowToolbarOnStandby',
        'ShowToolBarOnStandby',
        'IsShowToolbarOnStandbyEnabled',
        'IsShowToolBarOnStandbyEnabled',
        'ShowToolbarInStandby',
        'ShowToolBarInStandby',
        'IsShowToolbarInStandbyEnabled',
        'IsShowToolBarInStandbyEnabled',
        'ShowToolbarDuringStandby',
        'ShowToolBarDuringStandby',
        'IsShowToolbarDuringStandbyEnabled',
        'IsShowToolBarDuringStandbyEnabled',
        'ShowButtonToolbarOnStandby',
        'ShowButtonToolBarOnStandby',
        'IsShowButtonToolbarOnStandbyEnabled',
        'IsShowButtonToolBarOnStandbyEnabled',
        'ShowButtonToolbarInStandby',
        'ShowButtonToolBarInStandby',
        'IsShowButtonToolbarInStandbyEnabled',
        'IsShowButtonToolBarInStandbyEnabled',
        'ShowButtonToolbarDuringStandby',
        'ShowButtonToolBarDuringStandby',
        'IsShowButtonToolbarDuringStandbyEnabled',
        'IsShowButtonToolBarDuringStandbyEnabled',
        'ShowVirtualToolbarOnStandby',
        'ShowVirtualToolBarOnStandby',
        'IsShowVirtualToolbarOnStandbyEnabled',
        'IsShowVirtualToolBarOnStandbyEnabled',
        'ShowVirtualToolbarInStandby',
        'ShowVirtualToolBarInStandby',
        'IsShowVirtualToolbarInStandbyEnabled',
        'IsShowVirtualToolBarInStandbyEnabled',
        'ShowVirtualToolbarDuringStandby',
        'ShowVirtualToolBarDuringStandby',
        'IsShowVirtualToolbarDuringStandbyEnabled',
        'IsShowVirtualToolBarDuringStandbyEnabled',
        'ShowVirtualButtonToolbarOnStandby',
        'ShowVirtualButtonToolBarOnStandby',
        'IsShowVirtualButtonToolbarOnStandbyEnabled',
        'IsShowVirtualButtonToolBarOnStandbyEnabled',
        'ShowVirtualButtonToolbarInStandby',
        'ShowVirtualButtonToolBarInStandby',
        'IsShowVirtualButtonToolbarInStandbyEnabled',
        'IsShowVirtualButtonToolBarInStandbyEnabled',
        'ShowVirtualButtonToolbarDuringStandby',
        'ShowVirtualButtonToolBarDuringStandby',
        'IsShowVirtualButtonToolbarDuringStandbyEnabled',
        'IsShowVirtualButtonToolBarDuringStandbyEnabled'
    )
}

function Get-CrestronToolbarConditionPropertyNames {
    @(
        (Get-CrestronToolbarWakeConditionPropertyNames) +
        (Get-CrestronToolbarStandbyConditionPropertyNames)
    )
}

function Get-CrestronDisplayBoolValueDeep {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names,
        [string[]]$SectionNames = @()
    )

    $value = Get-CrestronDisplayBoolValue -Object $Object -Names $Names
    if ($null -ne $value) {
        return $value
    }

    foreach ($sectionName in $SectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Object -Names @($sectionName)
        if (-not $section) {
            continue
        }

        $sectionValue = Get-CrestronDisplayBoolValue -Object $section.Object -Names $Names
        if ($null -ne $sectionValue) {
            return $sectionValue
        }
    }

    return $null
}

function Get-CrestronDisplayBoolValuesDeep {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names,
        [string[]]$SectionNames = @()
    )

    $values = @()
    foreach ($name in $Names) {
        $value = Get-CrestronObjectProperty -Object $Object -Name $name
        if ($null -eq $value) {
            continue
        }

        $nested = Get-CrestronDisplayNestedValue -Value $value -SubPropertyNames @('IsEnabled','Enabled','Value','State','Mode','IsActive','IsOn')
        $converted = ConvertFrom-CrestronDisplayBool $nested
        if ($null -ne $converted) {
            $values += [bool]$converted
        }
    }

    foreach ($sectionName in $SectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Object -Names @($sectionName)
        if (-not $section) {
            continue
        }

        foreach ($name in $Names) {
            $value = Get-CrestronObjectProperty -Object $section.Object -Name $name
            if ($null -eq $value) {
                continue
            }

            $nested = Get-CrestronDisplayNestedValue -Value $value -SubPropertyNames @('IsEnabled','Enabled','Value','State','Mode','IsActive','IsOn')
            $converted = ConvertFrom-CrestronDisplayBool $nested
            if ($null -ne $converted) {
                $values += [bool]$converted
            }
        }
    }

    return @($values)
}

function Get-CrestronToolbarBoolValue {
    param($Object)

    $virtualButtonsValue = Get-CrestronVirtualButtonsToolbarBoolValue -Object $Object
    if ($null -ne $virtualButtonsValue) {
        return $virtualButtonsValue
    }

    $conditionValues = @(Get-CrestronDisplayBoolValuesDeep `
        -Object $Object `
        -SectionNames (Get-CrestronToolbarSectionNames) `
        -Names (Get-CrestronToolbarWakeConditionPropertyNames))

    if ($conditionValues.Count -eq 0) {
        $conditionValues = @(Get-CrestronDisplayBoolValuesRecursive -Object $Object -Names (Get-CrestronToolbarWakeConditionPropertyNames))
    }

    if ($conditionValues.Count -gt 0) {
        return [bool]$conditionValues[0]
    }

    $conditionValues = @(Get-CrestronDisplayBoolValuesDeep `
        -Object $Object `
        -SectionNames (Get-CrestronToolbarSectionNames) `
        -Names (Get-CrestronToolbarStandbyConditionPropertyNames))

    if ($conditionValues.Count -eq 0) {
        $conditionValues = @(Get-CrestronDisplayBoolValuesRecursive -Object $Object -Names (Get-CrestronToolbarStandbyConditionPropertyNames))
    }

    if ($conditionValues.Count -gt 0) {
        return [bool]$conditionValues[0]
    }

    $positiveNames = @((Get-CrestronToolbarPropertyNames) + (Get-CrestronToolbarDirectPropertyNames))

    $value = Get-CrestronDisplayBoolValueDeep `
        -Object $Object `
        -SectionNames (Get-CrestronToolbarSectionNames) `
        -Names $positiveNames

    if ($null -ne $value) {
        return $value
    }

    $recursivePositiveValues = @(Get-CrestronDisplayBoolValuesRecursive -Object $Object -Names $positiveNames)
    if ($recursivePositiveValues.Count -gt 0) {
        return [bool]$recursivePositiveValues[0]
    }

    $genericValue = Get-CrestronDisplayBoolValueDeep `
        -Object $Object `
        -SectionNames (Get-CrestronToolbarSectionNames) `
        -Names (Get-CrestronToolbarGenericPropertyNames)

    if ($null -ne $genericValue) {
        return $genericValue
    }

    $disabledValue = Get-CrestronDisplayBoolValueDeep `
        -Object $Object `
        -SectionNames (Get-CrestronToolbarSectionNames) `
        -Names (Get-CrestronToolbarDisabledPropertyNames)

    if ($null -eq $disabledValue) {
        $recursiveDisabledValues = @(Get-CrestronDisplayBoolValuesRecursive -Object $Object -Names (Get-CrestronToolbarDisabledPropertyNames))
        if ($recursiveDisabledValues.Count -gt 0) {
            $disabledValue = [bool]$recursiveDisabledValues[0]
        }
    }

    if ($null -eq $disabledValue) {
        return $null
    }

    return (-not [bool]$disabledValue)
}

function Get-CrestronDisplayIntValueDeep {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$Names,
        [string[]]$SectionNames = @()
    )

    $value = Get-CrestronDisplayIntValue -Object $Object -Names $Names
    if ($null -ne $value) {
        return $value
    }

    foreach ($sectionName in $SectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Object -Names @($sectionName)
        if (-not $section) {
            continue
        }

        $sectionValue = Get-CrestronDisplayIntValue -Object $section.Object -Names $Names
        if ($null -ne $sectionValue) {
            return $sectionValue
        }
    }

    return $null
}

function Test-CrestronDisplayObjectSupported {
    param($Object)

    if ($null -eq $Object) {
        return $false
    }

    $knownNames = @(
        'AutoBrightness','AutoBrightnessEnabled','IsAutoBrightnessEnabled','EnableAutoBrightness','AdaptiveBrightness',
        'AutoBrightnessMode','IsAdaptiveBrightnessEnabled','AmbientLightSensor','AmbientLightSensorEnabled',
        'Brightness','BrightnessLevel','Backlight','BackLight','BacklightLevel','BackLightLevel','BacklightBrightness',
        'ScreenBrightness','ScreenBrightnessLevel','LCDBacklightBrightness','LcdBrightness','DisplayBrightness',
        'ScreenSaver','Screensaver','ScreenSaverEnabled','ScreensaverEnabled','ScreenSaverEnable','ScreensaverEnable',
        'IsScreenSaverEnabled','EnableScreenSaver','EnableScreensaver',
        'StandbyTimeout','StandbyTimeOut','StandbyTimeoutMinutes','StandbyTimeoutSeconds','StandbyTimer','StandbyTimerMinutes',
        'DisplayStandbyTimeout','DisplayStandbyTimeoutMinutes','DisplayOffTimeout','IdleTimeout','SleepTimeout'
    )

    foreach ($name in $knownNames) {
        if (Get-CrestronFirstPropertyName -Object $Object -Names @($name)) {
            return $true
        }
    }

    $sectionNames = @() +
        (Get-CrestronDisplayLcdSectionNames) +
        (Get-CrestronDisplayScreensaverSectionNames)

    foreach ($sectionName in $sectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Object -Names @($sectionName)
        if (-not $section) {
            continue
        }

        foreach ($name in $knownNames) {
            if (Get-CrestronFirstPropertyName -Object $section.Object -Names @($name)) {
                return $true
            }
        }
    }

    return $false
}

function Test-CrestronToolbarObjectSupported {
    param(
        $Object,
        [bool]$AllowGeneric = $false
    )

    if ($null -eq $Object) {
        return $false
    }

    $explicitNames = @(
        (Get-CrestronToolbarPropertyNames) +
        (Get-CrestronToolbarDirectPropertyNames) +
        (Get-CrestronToolbarConditionPropertyNames) +
        (Get-CrestronToolbarDisabledPropertyNames)
    )
    foreach ($name in $explicitNames) {
        if (Get-CrestronFirstPropertyName -Object $Object -Names @($name)) {
            return $true
        }
    }

    if ($AllowGeneric) {
        foreach ($name in Get-CrestronToolbarGenericPropertyNames) {
            if (Get-CrestronFirstPropertyName -Object $Object -Names @($name)) {
                return $true
            }
        }
    }

    foreach ($sectionName in Get-CrestronToolbarSectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Object -Names @($sectionName)
        if (-not $section) {
            continue
        }

        foreach ($name in @($explicitNames + (Get-CrestronToolbarGenericPropertyNames))) {
            if (Get-CrestronFirstPropertyName -Object $section.Object -Names @($name)) {
                return $true
            }
        }
    }

    if (Test-CrestronDisplayMemberRecursive -Object $Object -Names @($explicitNames + (Get-CrestronToolbarGenericPropertyNames))) {
        return $true
    }

    return $false
}

function Get-CrestronDisplayObjectFromBody {
    param(
        $BodyJson,
        [Parameter(Mandatory)][string[]]$CandidateNames
    )

    if ($null -eq $BodyJson) {
        return $null
    }

    $device = Get-CrestronObjectProperty -Object $BodyJson -Name 'Device'
    if ($device) {
        foreach ($name in $CandidateNames) {
            $value = Get-CrestronObjectProperty -Object $device -Name $name
            if ($value) {
                return [pscustomobject]@{
                    PathName = (Get-CrestronFirstPropertyName -Object $device -Names @($name))
                    Object   = $value
                }
            }
        }
    }

    foreach ($name in $CandidateNames) {
        $value = Get-CrestronObjectProperty -Object $BodyJson -Name $name
        if ($value) {
            return [pscustomobject]@{
                PathName = (Get-CrestronFirstPropertyName -Object $BodyJson -Names @($name))
                Object   = $value
            }
        }
    }

    return $null
}

function Get-CrestronToolbarObjectFromBody {
    param(
        $BodyJson,
        [Parameter(Mandatory)][string[]]$CandidateNames
    )

    $directNames = @(
        $CandidateNames +
        (Get-CrestronToolbarPropertyNames) +
        (Get-CrestronToolbarDirectPropertyNames) +
        (Get-CrestronToolbarConditionPropertyNames) +
        (Get-CrestronToolbarDisabledPropertyNames)
    ) | Select-Object -Unique
    $device = Get-CrestronObjectProperty -Object $BodyJson -Name 'Device'
    foreach ($root in @($device, $BodyJson)) {
        if (-not $root) {
            continue
        }

        $directName = Get-CrestronFirstPropertyName -Object $root -Names $directNames
        if (-not $directName) {
            continue
        }

        $directValue = Get-CrestronObjectProperty -Object $root -Name $directName
        if ($null -eq $directValue) {
            continue
        }

        if ($directValue -is [string] -or $directValue.GetType().IsPrimitive) {
            $directObject = @{}
            $directObject[$directName] = $directValue
            return [pscustomobject]@{
                PathName         = $directName
                Object           = [pscustomobject]$directObject
                IsDirectProperty = $true
            }
        }

        $allowGeneric = "$directName" -match '(?i)toolbar|navigation|navbar'
        if (Test-CrestronToolbarObjectSupported -Object $directValue -AllowGeneric $allowGeneric) {
            return [pscustomobject]@{
                PathName         = $directName
                Object           = $directValue
                IsDirectProperty = $false
            }
        }
    }

    $found = Get-CrestronDisplayObjectFromBody -BodyJson $BodyJson -CandidateNames $CandidateNames
    if ($found) {
        $allowGeneric = "$($found.PathName)" -match '(?i)toolbar|navigation|navbar'
        if (Test-CrestronToolbarObjectSupported -Object $found.Object -AllowGeneric $allowGeneric) {
            return [pscustomobject]@{
                PathName         = $found.PathName
                Object           = $found.Object
                IsDirectProperty = $false
            }
        }
    }

    foreach ($root in @($device, $BodyJson)) {
        if (-not $root) {
            continue
        }

        foreach ($name in @('UserInterface','TouchScreen','Touchscreen','TouchPanel','Display','DisplaySettings','Screen','DeviceSpecific')) {
            $container = Get-CrestronObjectProperty -Object $root -Name $name
            if (-not $container) {
                continue
            }

            if (Test-CrestronToolbarObjectSupported -Object $container) {
                return [pscustomobject]@{
                    PathName         = (Get-CrestronFirstPropertyName -Object $root -Names @($name))
                    Object           = $container
                    IsDirectProperty = $false
                }
            }
        }
    }

    return $null
}

function Test-CrestronDisplayMemberDeep {
    param(
        $Object,
        [Parameter(Mandatory)][string[]]$SectionNames,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Object) {
        return $false
    }

    if (Get-CrestronFirstPropertyName -Object $Object -Names $Names) {
        return $true
    }

    foreach ($sectionName in $SectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Object -Names @($sectionName)
        if (-not $section) {
            continue
        }

        if (Get-CrestronFirstPropertyName -Object $section.Object -Names $Names) {
            return $true
        }
    }

    return $false
}

function Get-CrestronDisplayObject {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    $candidateNames = @(
        'Display',
        'DeviceDisplay',
        'UserInterface',
        'TouchScreen',
        'Touchscreen',
        'TouchPanel',
        'Touchpanel',
        'Screen',
        'Lcd',
        'LCD',
        'DisplayLcd',
        'DisplayLCD',
        'Panel',
        'Backlight',
        'BackLight',
        'ScreenSaver',
        'Screensaver',
        'PowerSettings',
        'DisplaySettings',
        'DeviceSpecific'
    )
    $candidatePaths = @(
        @{ Path = '/Device/Display';       Name = 'Display' },
        @{ Path = '/Device/DeviceDisplay'; Name = 'DeviceDisplay' },
        @{ Path = '/Device/UserInterface'; Name = 'UserInterface' },
        @{ Path = '/Device/TouchScreen';   Name = 'TouchScreen' },
        @{ Path = '/Device/Touchscreen';   Name = 'Touchscreen' },
        @{ Path = '/Device/TouchPanel';    Name = 'TouchPanel' },
        @{ Path = '/Device/Screen';        Name = 'Screen' },
        @{ Path = '/Device/Lcd';           Name = 'Lcd' },
        @{ Path = '/Device/LCD';           Name = 'LCD' },
        @{ Path = '/Device/DisplayLcd';    Name = 'DisplayLcd' },
        @{ Path = '/Device/Panel';         Name = 'Panel' },
        @{ Path = '/Device/Backlight';     Name = 'Backlight' },
        @{ Path = '/Device/BackLight';     Name = 'BackLight' },
        @{ Path = '/Device/ScreenSaver';   Name = 'ScreenSaver' },
        @{ Path = '/Device/Screensaver';   Name = 'Screensaver' },
        @{ Path = '/Device/PowerSettings'; Name = 'PowerSettings' },
        @{ Path = '/Device/DisplaySettings'; Name = 'DisplaySettings' },
        @{ Path = '/Device/DeviceSpecific'; Name = 'DeviceSpecific' }
    )

    try {
        $deviceApi = Invoke-CrestronApi -Session $Session -Path '/Device' -Method GET -TimeoutSec $TimeoutSec
        if ($deviceApi.Success -and $deviceApi.BodyJson) {
            $found = Get-CrestronDisplayObjectFromBody -BodyJson $deviceApi.BodyJson -CandidateNames $candidateNames
            if ($found -and (Test-CrestronDisplayObjectSupported $found.Object)) {
                return [pscustomobject]@{
                    Path     = "/Device/$($found.PathName)"
                    PathName = $found.PathName
                    Object   = $found.Object
                    RawJson  = $deviceApi.BodyJson
                }
            }
        }
    }
    catch { }

    foreach ($candidate in $candidatePaths) {
        try {
            $api = Invoke-CrestronApi -Session $Session -Path $candidate.Path -Method GET -TimeoutSec $TimeoutSec
            if (-not ($api.Success -and $api.BodyJson)) {
                continue
            }

            $found = Get-CrestronDisplayObjectFromBody -BodyJson $api.BodyJson -CandidateNames @($candidate.Name)
            if ($found -and (Test-CrestronDisplayObjectSupported $found.Object)) {
                return [pscustomobject]@{
                    Path     = $candidate.Path
                    PathName = $found.PathName
                    Object   = $found.Object
                    RawJson  = $api.BodyJson
                }
            }

            $found = Get-CrestronDisplayObjectFromBody -BodyJson $api.BodyJson -CandidateNames $candidateNames
            if ($found -and (Test-CrestronDisplayObjectSupported $found.Object)) {
                return [pscustomobject]@{
                    Path     = "/Device/$($found.PathName)"
                    PathName = $found.PathName
                    Object   = $found.Object
                    RawJson  = $api.BodyJson
                }
            }

            $deviceObject = Get-CrestronObjectProperty -Object $api.BodyJson -Name 'Device'
            if ($deviceObject -and (Test-CrestronDisplayObjectSupported $deviceObject)) {
                return [pscustomobject]@{
                    Path     = $candidate.Path
                    PathName = $candidate.Name
                    Object   = $deviceObject
                    RawJson  = $api.BodyJson
                }
            }

            if (Test-CrestronDisplayObjectSupported $api.BodyJson) {
                return [pscustomobject]@{
                    Path     = $candidate.Path
                    PathName = $candidate.Name
                    Object   = $api.BodyJson
                    RawJson  = $api.BodyJson
                }
            }
        }
        catch { }
    }

    return $null
}

function Get-CrestronToolbarObject {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    $candidateNames = @(
        'Toolbar',
        'ToolBar',
        'ToolbarSettings',
        'ToolBarSettings',
        'ButtonToolbar',
        'ButtonToolBar',
        'ButtonToolbarSettings',
        'ButtonToolBarSettings',
        'VirtualToolbar',
        'VirtualToolBar',
        'VirtualToolbarSettings',
        'VirtualToolBarSettings',
        'VirtualButtonToolbar',
        'VirtualButtonToolBar',
        'VirtualButtons',
        'VirtualButtonSettings',
        'OnScreenToolbar',
        'OnScreenToolBar',
        'SoftToolbar',
        'SoftToolBar',
        'SoftButtonToolbar',
        'SoftButtonToolBar',
        'ProjectToolbar',
        'ProjectToolBar',
        'UserProjectToolbar',
        'UserProjectToolBar',
        'UserToolbar',
        'UserToolBar',
        'NavigationBar',
        'NavBar'
    )

    $candidatePaths = @(
        @{ Path = '/Device/Toolbar';             Name = 'Toolbar' },
        @{ Path = '/Device/ToolBar';             Name = 'ToolBar' },
        @{ Path = '/Device/ToolbarSettings';     Name = 'ToolbarSettings' },
        @{ Path = '/Device/ToolBarSettings';     Name = 'ToolBarSettings' },
        @{ Path = '/Device/ButtonToolbar';       Name = 'ButtonToolbar' },
        @{ Path = '/Device/ButtonToolBar';       Name = 'ButtonToolBar' },
        @{ Path = '/Device/ButtonToolbarSettings'; Name = 'ButtonToolbarSettings' },
        @{ Path = '/Device/ButtonToolBarSettings'; Name = 'ButtonToolBarSettings' },
        @{ Path = '/Device/VirtualToolbar';      Name = 'VirtualToolbar' },
        @{ Path = '/Device/VirtualToolBar';      Name = 'VirtualToolBar' },
        @{ Path = '/Device/VirtualToolbarSettings'; Name = 'VirtualToolbarSettings' },
        @{ Path = '/Device/VirtualToolBarSettings'; Name = 'VirtualToolBarSettings' },
        @{ Path = '/Device/VirtualButtonToolbar'; Name = 'VirtualButtonToolbar' },
        @{ Path = '/Device/VirtualButtonToolBar'; Name = 'VirtualButtonToolBar' },
        @{ Path = '/Device/Display/VirtualButtons'; Name = 'VirtualButtons' },
        @{ Path = '/Device/VirtualButtons';    Name = 'VirtualButtons' },
        @{ Path = '/Device/VirtualButtonSettings'; Name = 'VirtualButtonSettings' },
        @{ Path = '/Device/OnScreenToolbar';     Name = 'OnScreenToolbar' },
        @{ Path = '/Device/OnScreenToolBar';     Name = 'OnScreenToolBar' },
        @{ Path = '/Device/SoftToolbar';         Name = 'SoftToolbar' },
        @{ Path = '/Device/SoftToolBar';         Name = 'SoftToolBar' },
        @{ Path = '/Device/SoftButtonToolbar';   Name = 'SoftButtonToolbar' },
        @{ Path = '/Device/SoftButtonToolBar';   Name = 'SoftButtonToolBar' },
        @{ Path = '/Device/ProjectToolbar';      Name = 'ProjectToolbar' },
        @{ Path = '/Device/UserProjectToolbar';  Name = 'UserProjectToolbar' },
        @{ Path = '/Device/UserToolbar';         Name = 'UserToolbar' },
        @{ Path = '/Device/NavigationBar';       Name = 'NavigationBar' },
        @{ Path = '/Device/NavBar';              Name = 'NavBar' },
        @{ Path = '/Device/UserInterface';       Name = 'UserInterface' },
        @{ Path = '/Device/TouchScreen';         Name = 'TouchScreen' },
        @{ Path = '/Device/TouchPanel';          Name = 'TouchPanel' },
        @{ Path = '/Device/Display';             Name = 'Display' },
        @{ Path = '/Device/DisplaySettings';     Name = 'DisplaySettings' },
        @{ Path = '/Device/Screen';              Name = 'Screen' },
        @{ Path = '/Device/DeviceSpecific';      Name = 'DeviceSpecific' }
    )

    try {
        $deviceApi = Invoke-CrestronApi -Session $Session -Path '/Device' -Method GET -TimeoutSec $TimeoutSec
        if ($deviceApi.Success -and $deviceApi.BodyJson) {
            $found = Get-CrestronToolbarObjectFromBody -BodyJson $deviceApi.BodyJson -CandidateNames $candidateNames
            if ($found) {
                return [pscustomobject]@{
                    Path             = "/Device/$($found.PathName)"
                    PathName         = $found.PathName
                    Object           = $found.Object
                    IsDirectProperty = [bool]$found.IsDirectProperty
                    RawJson          = $deviceApi.BodyJson
                }
            }
        }
    }
    catch { }

    foreach ($candidate in $candidatePaths) {
        try {
            $api = Invoke-CrestronApi -Session $Session -Path $candidate.Path -Method GET -TimeoutSec $TimeoutSec
            if (-not ($api.Success -and $api.BodyJson)) {
                continue
            }

            $found = Get-CrestronToolbarObjectFromBody -BodyJson $api.BodyJson -CandidateNames @($candidate.Name)
            if ($found) {
                return [pscustomobject]@{
                    Path             = $candidate.Path
                    PathName         = $found.PathName
                    Object           = $found.Object
                    IsDirectProperty = [bool]$found.IsDirectProperty
                    RawJson          = $api.BodyJson
                }
            }
        }
        catch { }
    }

    return $null
}

function Get-CrestronDeviceObjectByName {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 15
    )

    try {
        $api = Invoke-CrestronApi -Session $Session -Path "/Device/$Name" -Method GET -TimeoutSec $TimeoutSec
        if (-not ($api.Success -and $api.BodyJson)) {
            return $null
        }

        $found = Get-CrestronDisplayObjectFromBody -BodyJson $api.BodyJson -CandidateNames @($Name)
        if (-not $found) {
            return $null
        }

        [pscustomobject]@{
            Path     = "/Device/$($found.PathName)"
            PathName = $found.PathName
            Object   = $found.Object
            RawJson  = $api.BodyJson
        }
    }
    catch {
        return $null
    }
}

function Get-CrestronHashtableChild {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Target.ContainsKey($Name) -or -not ($Target[$Name] -is [hashtable])) {
        $Target[$Name] = @{}
    }

    $Target[$Name]
}

function ConvertTo-CrestronWritableValue {
    param(
        $Value,
        [int]$MaxDepth = 12
    )

    if ($null -eq $Value -or $MaxDepth -lt 0) {
        return $Value
    }

    if ($Value -is [string] -or
        $Value.GetType().IsPrimitive -or
        $Value -is [decimal] -or
        $Value -is [datetime]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in @($Value.Keys)) {
            $result["$key"] = ConvertTo-CrestronWritableValue -Value $Value[$key] -MaxDepth ($MaxDepth - 1)
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in @($Value)) {
            $items += ,(ConvertTo-CrestronWritableValue -Value $item -MaxDepth ($MaxDepth - 1))
        }
        return @($items)
    }

    $properties = @($Value.PSObject.Properties | Where-Object { $_.Name -and $_.IsGettable })
    if ($properties.Count -eq 0) {
        return $Value
    }

    $objectResult = @{}
    foreach ($prop in $properties) {
        try {
            $objectResult[$prop.Name] = ConvertTo-CrestronWritableValue -Value $prop.Value -MaxDepth ($MaxDepth - 1)
        }
        catch { }
    }

    return $objectResult
}

function New-CrestronVirtualButtonsToolbarPayload {
    param(
        $VirtualButtons,
        [Parameter(Mandatory)][bool]$ToolbarEnabled
    )

    $payload = ConvertTo-CrestronWritableValue -Value $VirtualButtons
    if (-not ($payload -is [hashtable])) {
        $payload = @{}
    }

    $payload['IsEnabled'] = $ToolbarEnabled
    $payload['IsShowOnWakeEnabled'] = $ToolbarEnabled
    $payload['IsShowDuringStandbyEnabled'] = $ToolbarEnabled
    return $payload
}

function Get-CrestronDisplayWritableSection {
    param(
        $Existing,
        [Parameter(Mandatory)][string[]]$SectionNames
    )

    foreach ($sectionName in $SectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Existing -Names @($sectionName)
        if ($section) {
            return $section
        }
    }

    return $null
}

function Set-CrestronDisplayBooleanMember {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        $Existing,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$DefaultName,
        [Parameter(Mandatory)][bool]$Value
    )

    $name = Get-CrestronFirstPropertyName -Object $Existing -Names $Names
    $hasExistingProperty = [bool]$name
    if (-not $name) {
        $name = $DefaultName
    }

    $existingValue = Get-CrestronObjectProperty -Object $Existing -Name $name
    if ($hasExistingProperty -and $null -ne $existingValue -and -not ($existingValue -is [string]) -and -not ($existingValue.GetType().IsPrimitive)) {
        $subName = Get-CrestronFirstPropertyName -Object $existingValue -Names @('IsEnabled','Enabled','Value','State')
        if (-not $subName) {
            $subName = 'IsEnabled'
        }

        $Target[$name] = @{ $subName = $Value }
        return
    }

    if ($hasExistingProperty) {
        $Target[$name] = $Value
        return
    }

    if ($name -match 'Enabled$|^Is|^Enable') {
        $Target[$name] = $Value
    }
    else {
        $Target[$name] = @{ IsEnabled = $Value }
    }
}

function Set-CrestronDisplayIntMember {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        $Existing,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$DefaultName,
        [Parameter(Mandatory)][int]$Value
    )

    $name = Get-CrestronFirstPropertyName -Object $Existing -Names $Names
    $hasExistingProperty = [bool]$name
    if (-not $name) {
        $name = $DefaultName
    }

    $existingValue = Get-CrestronObjectProperty -Object $Existing -Name $name
    if ($hasExistingProperty -and $null -ne $existingValue -and -not ($existingValue -is [string]) -and -not ($existingValue.GetType().IsPrimitive)) {
        $subName = Get-CrestronFirstPropertyName -Object $existingValue -Names @('Value','Level','Brightness','Timeout','TimeoutMinutes','Minutes','Seconds')
        if (-not $subName) {
            $subName = 'Value'
        }

        $Target[$name] = @{ $subName = $Value }
        return
    }

    $Target[$name] = $Value
}

function Set-CrestronDisplayBooleanMemberDeep {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        $Existing,
        [Parameter(Mandatory)][string[]]$SectionNames,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$DefaultName,
        [Parameter(Mandatory)][bool]$Value
    )

    $section = Get-CrestronDisplayWritableSection -Existing $Existing -SectionNames $SectionNames
    if ($section) {
        $sectionTarget = Get-CrestronHashtableChild -Target $Target -Name $section.Name
        Set-CrestronDisplayBooleanMember -Target $sectionTarget -Existing $section.Object -Names $Names -DefaultName $DefaultName -Value $Value
        return
    }

    Set-CrestronDisplayBooleanMember -Target $Target -Existing $Existing -Names $Names -DefaultName $DefaultName -Value $Value
}

function Set-CrestronToolbarConditionMembersDeep {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        $Existing,
        [Parameter(Mandatory)][bool]$ToolbarEnabled
    )

    $names = Get-CrestronToolbarConditionPropertyNames
    $section = Get-CrestronDisplayWritableSection -Existing $Existing -SectionNames (Get-CrestronToolbarSectionNames)
    if ($section) {
        $targetObject = Get-CrestronHashtableChild -Target $Target -Name $section.Name
        $existingObject = $section.Object
    }
    else {
        $targetObject = $Target
        $existingObject = $Existing
    }

    $foundNames = @()
    foreach ($name in $names) {
        $foundName = Get-CrestronFirstPropertyName -Object $existingObject -Names @($name)
        if ($foundName) {
            $foundNames += $foundName
        }
    }

    if ($foundNames.Count -eq 0) {
        Set-CrestronDisplayBooleanMember -Target $targetObject -Existing $existingObject -Names @('IsShowOnWakeEnabled') -DefaultName 'IsShowOnWakeEnabled' -Value $ToolbarEnabled
        Set-CrestronDisplayBooleanMember -Target $targetObject -Existing $existingObject -Names @('IsShowDuringStandbyEnabled') -DefaultName 'IsShowDuringStandbyEnabled' -Value $ToolbarEnabled
        return
    }

    foreach ($foundName in $foundNames) {
        Set-CrestronDisplayBooleanMember -Target $targetObject -Existing $existingObject -Names @($foundName) -DefaultName $foundName -Value $ToolbarEnabled
    }
}

function Set-CrestronToolbarEnabledMemberDeep {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        $Existing,
        [Parameter(Mandatory)][bool]$ToolbarEnabled
    )

    $sectionNames = Get-CrestronToolbarSectionNames
    $positiveNames = @((Get-CrestronToolbarPropertyNames) + (Get-CrestronToolbarDirectPropertyNames))
    $genericNames = Get-CrestronToolbarGenericPropertyNames
    $conditionNames = Get-CrestronToolbarConditionPropertyNames
    $disabledNames = Get-CrestronToolbarDisabledPropertyNames

    if (Test-CrestronDisplayMemberDeep -Object $Existing -SectionNames $sectionNames -Names $positiveNames) {
        Set-CrestronDisplayBooleanMemberDeep `
            -Target $Target `
            -Existing $Existing `
            -SectionNames $sectionNames `
            -Names $positiveNames `
            -DefaultName 'ToolbarEnabled' `
            -Value $ToolbarEnabled
        return
    }

    if (Test-CrestronDisplayMemberDeep -Object $Existing -SectionNames $sectionNames -Names $conditionNames) {
        Set-CrestronToolbarConditionMembersDeep `
            -Target $Target `
            -Existing $Existing `
            -ToolbarEnabled $ToolbarEnabled
        return
    }

    if (Test-CrestronDisplayMemberDeep -Object $Existing -SectionNames $sectionNames -Names $disabledNames) {
        Set-CrestronDisplayBooleanMemberDeep `
            -Target $Target `
            -Existing $Existing `
            -SectionNames $sectionNames `
            -Names $disabledNames `
            -DefaultName 'DisableToolbar' `
            -Value (-not $ToolbarEnabled)
        return
    }

    if (Test-CrestronDisplayMemberDeep -Object $Existing -SectionNames $sectionNames -Names $genericNames) {
        Set-CrestronDisplayBooleanMemberDeep `
            -Target $Target `
            -Existing $Existing `
            -SectionNames $sectionNames `
            -Names $genericNames `
            -DefaultName 'IsEnabled' `
            -Value $ToolbarEnabled
        return
    }

    Set-CrestronDisplayBooleanMemberDeep `
        -Target $Target `
        -Existing $Existing `
        -SectionNames $sectionNames `
        -Names $positiveNames `
        -DefaultName 'ToolbarEnabled' `
        -Value $ToolbarEnabled
}

function Set-CrestronDisplayIntMemberDeep {
    param(
        [Parameter(Mandatory)][hashtable]$Target,
        $Existing,
        [Parameter(Mandatory)][string[]]$SectionNames,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$DefaultName,
        [Parameter(Mandatory)][int]$Value
    )

    $section = Get-CrestronDisplayWritableSection -Existing $Existing -SectionNames $SectionNames
    if ($section) {
        $sectionTarget = Get-CrestronHashtableChild -Target $Target -Name $section.Name
        Set-CrestronDisplayIntMember -Target $sectionTarget -Existing $section.Object -Names $Names -DefaultName $DefaultName -Value $Value
        return
    }

    Set-CrestronDisplayIntMember -Target $Target -Existing $Existing -Names $Names -DefaultName $DefaultName -Value $Value
}
