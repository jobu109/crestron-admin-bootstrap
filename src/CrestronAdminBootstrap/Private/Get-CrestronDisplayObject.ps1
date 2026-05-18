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

    $subNames = @('IsEnabled','Enabled','Value','State')

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

    $subNames = @('Value','Level','Brightness','Timeout','TimeoutMinutes','Minutes','Seconds')

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

function Get-CrestronDisplayLcdSectionNames {
    @(
        'Lcd',
        'LCD',
        'LcdSettings',
        'DisplayLcd',
        'Panel',
        'Screen',
        'Backlight',
        'BackLight',
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
        'Idle'
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
        'Brightness','BrightnessLevel','BacklightBrightness','ScreenBrightness','LCDBacklightBrightness',
        'ScreenSaver','Screensaver','ScreenSaverEnabled','ScreensaverEnabled','IsScreenSaverEnabled','EnableScreenSaver',
        'StandbyTimeout','StandbyTimeOut','StandbyTimeoutMinutes','StandbyTimeoutSeconds','StandbyTimer','StandbyTimerMinutes',
        'DisplayStandbyTimeout','DisplayStandbyTimeoutMinutes'
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

function Get-CrestronDisplayObject {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    $candidateNames = @('Display','DeviceDisplay','UserInterface','TouchScreen','Screen','DeviceSpecific')
    $candidatePaths = @(
        @{ Path = '/Device/Display';       Name = 'Display' },
        @{ Path = '/Device/DeviceDisplay'; Name = 'DeviceDisplay' },
        @{ Path = '/Device/UserInterface'; Name = 'UserInterface' },
        @{ Path = '/Device/TouchScreen';   Name = 'TouchScreen' },
        @{ Path = '/Device/Screen';        Name = 'Screen' },
        @{ Path = '/Device/DeviceSpecific'; Name = 'DeviceSpecific' }
    )

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
