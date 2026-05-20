function Get-CrestronAvFrameworkSettings {
    <#
    .SYNOPSIS
        Retrieves AV Framework enablement when the device exposes it.

    .DESCRIPTION
        Crestron firmware exposes AV Framework under a few different Device
        child objects. This cmdlet probes the known object/property names and
        returns a conservative support flag only when a readable value is found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    $avFramework = Get-CrestronAvFrameworkObject -Session $Session -TimeoutSec $TimeoutSec

    if (-not $avFramework) {
        return [pscustomobject]@{
            IP                          = $Session.IP
            Model                       = $Session.Model
            SupportsAvFrameworkSettings = $false
            AvFrameworkEnabled          = $null
            Path                        = ''
            PathName                    = ''
            RawJson                     = $null
            FetchedAt                   = (Get-Date).ToString('s')
        }
    }

    $allowGeneric = @((Get-CrestronAvFrameworkSectionNames) | Where-Object { $_ -ieq "$($avFramework.PathName)" }).Count -gt 0
    $enabled = Get-CrestronAvFrameworkBoolValue -Object $avFramework.Object -AllowGeneric:$allowGeneric
    $supports = $null -ne $enabled

    [pscustomobject]@{
        IP                          = $Session.IP
        Model                       = $Session.Model
        SupportsAvFrameworkSettings = [bool]$supports
        AvFrameworkEnabled          = $enabled
        Path                        = if ($supports) { "$($avFramework.Path)" } else { '' }
        PathName                    = if ($supports) { "$($avFramework.PathName)" } else { '' }
        RawJson                     = if ($supports) { $avFramework.RawJson } else { $null }
        FetchedAt                   = (Get-Date).ToString('s')
    }
}
