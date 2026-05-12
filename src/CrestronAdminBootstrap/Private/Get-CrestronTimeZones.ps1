function Get-CrestronTimeZones {
    <#
    .SYNOPSIS
        Returns Crestron's TimeZone code table used by the SystemClock object.
    .DESCRIPTION
        Codes are 3-digit strings (e.g. "010" = Central US). Curated subset
        covering common US/EU/AU/AS zones. If a tech needs a code not in this
        list, the launcher allows raw 3-digit entry as fallback.
    .OUTPUTS
        Array of PSCustomObjects: Code (3-digit string), Name (display label).
    #>
    [CmdletBinding()]
    param()

    @(
        [pscustomobject]@{ Code = '004'; Name = 'Hawaii Standard Time (UTC-10:00)' }
        [pscustomobject]@{ Code = '005'; Name = 'Alaska Standard Time (UTC-09:00)' }
        [pscustomobject]@{ Code = '008'; Name = 'Pacific Time (US & Canada) (UTC-08:00)' }
        [pscustomobject]@{ Code = '009'; Name = 'Mountain Time (US & Canada) (UTC-07:00)' }
        [pscustomobject]@{ Code = '010'; Name = 'Central Time (US & Canada) (UTC-06:00)' }
        [pscustomobject]@{ Code = '014'; Name = 'Eastern Time (US & Canada) (UTC-05:00)' }
        [pscustomobject]@{ Code = '015'; Name = 'Atlantic Time (Canada) (UTC-04:00)' }
        [pscustomobject]@{ Code = '017'; Name = 'Newfoundland (UTC-03:30)' }
        [pscustomobject]@{ Code = '018'; Name = 'Brasilia (UTC-03:00)' }
        [pscustomobject]@{ Code = '019'; Name = 'Buenos Aires (UTC-03:00)' }
        [pscustomobject]@{ Code = '023'; Name = 'UTC / Coordinated Universal Time' }
        [pscustomobject]@{ Code = '025'; Name = 'GMT - London / Dublin / Lisbon (UTC+00:00)' }
        [pscustomobject]@{ Code = '027'; Name = 'Central European Time - Berlin / Paris / Madrid (UTC+01:00)' }
        [pscustomobject]@{ Code = '028'; Name = 'Central European Time - Amsterdam / Brussels / Vienna (UTC+01:00)' }
        [pscustomobject]@{ Code = '029'; Name = 'Central European Time - Belgrade / Prague / Warsaw (UTC+01:00)' }
        [pscustomobject]@{ Code = '030'; Name = 'Eastern European Time - Athens / Helsinki / Istanbul (UTC+02:00)' }
        [pscustomobject]@{ Code = '034'; Name = 'Moscow / St. Petersburg (UTC+03:00)' }
        [pscustomobject]@{ Code = '035'; Name = 'Tehran (UTC+03:30)' }
        [pscustomobject]@{ Code = '036'; Name = 'Abu Dhabi / Muscat (UTC+04:00)' }
        [pscustomobject]@{ Code = '037'; Name = 'Kabul (UTC+04:30)' }
        [pscustomobject]@{ Code = '039'; Name = 'Karachi / Tashkent (UTC+05:00)' }
        [pscustomobject]@{ Code = '040'; Name = 'India Standard Time - Mumbai / Kolkata (UTC+05:30)' }
        [pscustomobject]@{ Code = '044'; Name = 'Bangkok / Hanoi / Jakarta (UTC+07:00)' }
        [pscustomobject]@{ Code = '045'; Name = 'China Standard Time - Beijing / Hong Kong (UTC+08:00)' }
        [pscustomobject]@{ Code = '048'; Name = 'Japan Standard Time - Tokyo / Osaka (UTC+09:00)' }
        [pscustomobject]@{ Code = '049'; Name = 'Korea Standard Time - Seoul (UTC+09:00)' }
        [pscustomobject]@{ Code = '051'; Name = 'Australian Central Time - Adelaide (UTC+09:30)' }
        [pscustomobject]@{ Code = '053'; Name = 'Australian Eastern Time - Sydney / Melbourne (UTC+10:00)' }
        [pscustomobject]@{ Code = '054'; Name = 'Brisbane (UTC+10:00)' }
        [pscustomobject]@{ Code = '055'; Name = 'Hobart (UTC+10:00)' }
        [pscustomobject]@{ Code = '058'; Name = 'Auckland / Wellington (UTC+12:00)' }
    )
}