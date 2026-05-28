function Get-CrestronAvFrameworkPropertyNames {
    @(
        'AVFramework',
        'AvFramework',
        'AvFrameworkEnabled',
        'AVFrameworkEnabled',
        'IsAvFrameworkEnabled',
        'IsAVFrameworkEnabled',
        'EnableAvFramework',
        'EnableAVFramework',
        'AvFrameworkEnable',
        'AVFrameworkEnable',
        'AvfEnabled',
        'AVFEnabled',
        'IsAvfEnabled',
        'IsAVFEnabled'
    )
}

function Get-CrestronAvFrameworkSectionNames {
    @(
        'AVFramework',
        'AvFramework',
        'AVFrameworkSettings',
        'AvFrameworkSettings',
        'AVF',
        'Avf'
    )
}

function Get-CrestronAvFrameworkContainerNames {
    @(
        'FeatureConfig',
        'FeatureConfiguration',
        'Features',
        'DeviceSpecific',
        'Applications',
        'ApplicationSettings',
        'AppSettings',
        'Project',
        'ProjectSettings'
    )
}

function Test-CrestronAvFrameworkObjectSupported {
    param($Object)

    if ($null -eq $Object) {
        return $false
    }

    $value = Get-CrestronDisplayBoolValue -Object $Object -Names (Get-CrestronAvFrameworkPropertyNames)
    if ($null -ne $value) {
        return $true
    }

    foreach ($sectionName in Get-CrestronAvFrameworkSectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Object -Names @($sectionName)
        if (-not $section) {
            continue
        }

        $value = Get-CrestronDisplayBoolValue -Object $section.Object -Names @((Get-CrestronAvFrameworkPropertyNames) + @('IsEnabled','Enabled','Enable'))
        if ($null -ne $value) {
            return $true
        }
    }

    if (Test-CrestronDisplayMemberRecursive -Object $Object -Names (Get-CrestronAvFrameworkPropertyNames)) {
        return $true
    }

    return $false
}

function Get-CrestronAvFrameworkBoolValue {
    param(
        $Object,
        [switch]$AllowGeneric
    )

    if ($null -eq $Object) {
        return $null
    }

    $value = Get-CrestronDisplayBoolValue -Object $Object -Names (Get-CrestronAvFrameworkPropertyNames)
    if ($null -ne $value) {
        return $value
    }

    if ($AllowGeneric) {
        $value = Get-CrestronDisplayBoolValue -Object $Object -Names @('IsEnabled','Enabled','Enable')
        if ($null -ne $value) {
            return $value
        }
    }

    foreach ($sectionName in Get-CrestronAvFrameworkSectionNames) {
        $section = Get-CrestronDisplayChildObject -Object $Object -Names @($sectionName)
        if (-not $section) {
            continue
        }

        $value = Get-CrestronDisplayBoolValue -Object $section.Object -Names @((Get-CrestronAvFrameworkPropertyNames) + @('IsEnabled','Enabled','Enable'))
        if ($null -ne $value) {
            return $value
        }
    }

    $values = Get-CrestronDisplayBoolValuesRecursive -Object $Object -Names (Get-CrestronAvFrameworkPropertyNames)
    if ($values.Count -gt 0) {
        return [bool]$values[0]
    }

    return $null
}

function Get-CrestronAvFrameworkObjectFromBody {
    param($BodyJson)

    if ($null -eq $BodyJson) {
        return $null
    }

    $candidateNames = @(
        (Get-CrestronAvFrameworkSectionNames) +
        (Get-CrestronAvFrameworkPropertyNames) +
        (Get-CrestronAvFrameworkContainerNames)
    ) | Select-Object -Unique
    $device = Get-CrestronObjectProperty -Object $BodyJson -Name 'Device'

    foreach ($root in @($device, $BodyJson)) {
        if (-not $root) {
            continue
        }

        foreach ($name in $candidateNames) {
            $value = Get-CrestronObjectProperty -Object $root -Name $name
            if ($null -eq $value) {
                continue
            }

            if ($value -is [string] -or $value.GetType().IsPrimitive) {
                $directObject = @{}
                $pathName = Get-CrestronFirstPropertyName -Object $root -Names @($name)
                $directObject[$pathName] = $value
                return [pscustomobject]@{
                    PathName         = $pathName
                    Object           = [pscustomobject]$directObject
                    IsDirectProperty = $true
                }
            }

            $sectionNamedValue = @((Get-CrestronAvFrameworkSectionNames) | Where-Object { $_ -ieq "$name" }).Count -gt 0
            $genericEnabled = if ($sectionNamedValue) {
                Get-CrestronDisplayBoolValue -Object $value -Names @('IsEnabled','Enabled','Enable')
            }
            else {
                $null
            }

            if ((Test-CrestronAvFrameworkObjectSupported $value) -or ($null -ne $genericEnabled)) {
                return [pscustomobject]@{
                    PathName         = (Get-CrestronFirstPropertyName -Object $root -Names @($name))
                    Object           = $value
                    IsDirectProperty = $false
                }
            }
        }
    }

    return $null
}

function Get-CrestronAvFrameworkObject {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    $candidatePaths = @(
        @{ Path = '/Device/AVFramework';         Name = 'AVFramework' },
        @{ Path = '/Device/AvFramework';         Name = 'AvFramework' },
        @{ Path = '/Device/AVFrameworkSettings'; Name = 'AVFrameworkSettings' },
        @{ Path = '/Device/AvFrameworkSettings'; Name = 'AvFrameworkSettings' },
        @{ Path = '/Device/AVF';                 Name = 'AVF' },
        @{ Path = '/Device/Avf';                 Name = 'Avf' },
        @{ Path = '/Device/FeatureConfig';       Name = 'FeatureConfig' },
        @{ Path = '/Device/FeatureConfiguration'; Name = 'FeatureConfiguration' },
        @{ Path = '/Device/Features';            Name = 'Features' },
        @{ Path = '/Device/DeviceSpecific';      Name = 'DeviceSpecific' },
        @{ Path = '/Device/Applications';        Name = 'Applications' },
        @{ Path = '/Device/ApplicationSettings'; Name = 'ApplicationSettings' },
        @{ Path = '/Device/AppSettings';         Name = 'AppSettings' },
        @{ Path = '/Device/Project';             Name = 'Project' },
        @{ Path = '/Device/ProjectSettings';     Name = 'ProjectSettings' }
    )

    try {
        $deviceApi = Invoke-CrestronApi -Session $Session -Path '/Device' -Method GET -TimeoutSec $TimeoutSec
        if ($deviceApi.Success -and $deviceApi.BodyJson) {
            $found = Get-CrestronAvFrameworkObjectFromBody -BodyJson $deviceApi.BodyJson
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

            $found = Get-CrestronAvFrameworkObjectFromBody -BodyJson $api.BodyJson
            if ($found) {
                return [pscustomobject]@{
                    Path             = $candidate.Path
                    PathName         = $found.PathName
                    Object           = $found.Object
                    IsDirectProperty = [bool]$found.IsDirectProperty
                    RawJson          = $api.BodyJson
                }
            }

            $deviceObject = Get-CrestronObjectProperty -Object $api.BodyJson -Name 'Device'
            if ($deviceObject -and (Test-CrestronAvFrameworkObjectSupported $deviceObject)) {
                return [pscustomobject]@{
                    Path             = $candidate.Path
                    PathName         = $candidate.Name
                    Object           = $deviceObject
                    IsDirectProperty = $false
                    RawJson          = $api.BodyJson
                }
            }

            if (Test-CrestronAvFrameworkObjectSupported $api.BodyJson) {
                return [pscustomobject]@{
                    Path             = $candidate.Path
                    PathName         = $candidate.Name
                    Object           = $api.BodyJson
                    IsDirectProperty = $false
                    RawJson          = $api.BodyJson
                }
            }
        }
        catch { }
    }

    return $null
}
