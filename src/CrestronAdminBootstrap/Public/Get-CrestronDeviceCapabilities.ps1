function Get-CrestronDeviceCapabilities {
    <#
    .SYNOPSIS
        Detects which major Crestron device settings are supported.

    .DESCRIPTION
        Uses the authenticated session and lightweight GET requests to determine
        which device setting sections appear to be available on the device.

        This cmdlet is intentionally conservative. A setting is marked supported
        only when the expected CresNext object can be fetched or when
        Get-CrestronDeviceState already exposes a reliable capability flag.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 15.

    .OUTPUTS
        PSCustomObject with support flags used by the GUI.

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 172.22.0.21 -Credential $cred
        Get-CrestronDeviceCapabilities -Session $session
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [int]$TimeoutSec = 15
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }

    function Test-CrestronCapabilityPath {
        param(
            [Parameter(Mandatory)][string]$Path
        )

        try {
            $result = Invoke-CrestronApi -Session $Session -Path $Path -Method GET -TimeoutSec $TimeoutSec

            if ($result.Success -and $result.BodyJson) {
                return $true
            }

            return $false
        }
        catch {
            return $false
        }
    }

    $state = $null

    try {
        $state = Get-CrestronDeviceState -Session $Session -TimeoutSec $TimeoutSec
    }
    catch {
        $state = $null
    }

    $supportsNetwork = Test-CrestronCapabilityPath -Path '/Device/NetworkAdapters'
    $supportsDevice = Test-CrestronCapabilityPath -Path '/Device'

    $supportsIpTable = (Test-CrestronCapabilityPath -Path '/Device/IpTableV2') -or
                       (Test-CrestronCapabilityPath -Path '/Device/IpTable')

    $supportsDeviceSpecific = Test-CrestronCapabilityPath -Path '/Device/DeviceSpecific'

    $supportsNtp = $false
    $supportsCloud = $false
    $supportsFusion = $false
    $supportsAutoUpdate = $false
    $avSettings = $null

    try {
        $deviceApi = Invoke-CrestronApi -Session $Session -Path '/Device' -Method GET -TimeoutSec $TimeoutSec

        if ($deviceApi.Success -and $deviceApi.BodyJson -and $deviceApi.BodyJson.Device) {
            $device = $deviceApi.BodyJson.Device

            $deviceProps = @($device.PSObject.Properties.Name)

            $supportsNtp = ($deviceProps -contains 'SystemClock')
            $supportsCloud = ($deviceProps -contains 'CloudSettings')
            $supportsFusion = ($deviceProps -contains 'Fusion') -or
                            ($deviceProps -contains 'FusionRoom') -or
                            ($deviceProps -contains 'FusionConfig')
            $supportsAutoUpdate = ($deviceProps -contains 'AutoUpdateMaster') -or
                                ($deviceProps -contains 'AutoUpdate')

            if (-not $supportsFusion -and ($deviceProps -contains 'CloudSettings')) {
                try {
                    $cloudApi = Invoke-CrestronApi -Session $Session -Path '/Device/CloudSettings' -Method GET -TimeoutSec $TimeoutSec

                    if ($cloudApi.Success -and $cloudApi.BodyJson -and
                        $cloudApi.BodyJson.Device -and
                        $cloudApi.BodyJson.Device.CloudSettings) {

                        $cloudSettings = $cloudApi.BodyJson.Device.CloudSettings
                        $cloudProps = @($cloudSettings.PSObject.Properties.Name)

                        $supportsFusion = ($cloudProps -contains 'FusionCloud')
                    }
                }
                catch { }
            }
        }
    }
    catch { }

    try {
        $avSettings = Get-CrestronAvSettings -Session $Session -TimeoutSec $TimeoutSec
    }
    catch {
        $avSettings = $null
    }

    $supportsAvSettings = $false
    $supportsAvMulticast = $false
    $supportsGlobalEdid = $false
    $avApiFamily = 'None'
    $avApiVersion = ''
    $edidNames = @()
    $model = "$($Session.Model)"

    if ([string]::IsNullOrWhiteSpace($model) -and $state -and -not [string]::IsNullOrWhiteSpace("$($state.Model)")) {
        $model = "$($state.Model)"
    }

    if ($avSettings) {
        if ([string]::IsNullOrWhiteSpace($model) -and -not [string]::IsNullOrWhiteSpace("$($avSettings.Model)")) {
            $model = "$($avSettings.Model)"
        }

        $avApiFamily = "$($avSettings.AvApiFamily)"
        $avApiVersion = "$($avSettings.AvApiVersion)"
        $supportsAvSettings = ($avApiFamily -ne 'None')
        $supportsAvMulticast = ($model -match '^DM-NVX') -and
                               ([bool]$avSettings.SupportsStreamTransmit -or [bool]$avSettings.SupportsStreamReceive)
        $supportsGlobalEdid = [bool]$avSettings.SupportsGlobalEdid
        $edidNames = @($avSettings.EdidNames |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique)
    }

    [pscustomobject]@{
        IP                     = $Session.IP
        Model                  = $model

        SupportsDevice         = $supportsDevice
        SupportsNetwork        = $supportsNetwork
        SupportsIpTable        = $supportsIpTable
        SupportsDeviceSpecific = $supportsDeviceSpecific

        SupportsWifi           = if ($state) { [bool]$state.HasWifi } else { $false }
        SupportsModeChange     = if ($state) { [bool]$state.SupportsModeChange } else { $false }
        CurrentDeviceMode      = if ($state) { "$($state.CurrentDeviceMode)" } else { '' }

        SupportsNtp            = $supportsNtp
        SupportsCloud          = $supportsCloud
        SupportsFusion         = $supportsFusion
        SupportsAutoUpdate     = $supportsAutoUpdate
        SupportsAvSettings     = $supportsAvSettings
        SupportsAvMulticast    = $supportsAvMulticast
        SupportsGlobalEdid     = $supportsGlobalEdid
        AvApiFamily            = $avApiFamily
        AvApiVersion           = $avApiVersion
        EdidNames              = $edidNames

        FetchedAt              = (Get-Date).ToString('s')
    }
}
