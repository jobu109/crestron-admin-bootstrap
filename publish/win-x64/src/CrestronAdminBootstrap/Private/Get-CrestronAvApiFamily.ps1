function Get-CrestronAvApiFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [int]$TimeoutSec = 15
    )

    try {
        $avioApi = Invoke-CrestronApi -Session $Session -Path '/Device/AvioV2' -Method GET -TimeoutSec $TimeoutSec

        if ($avioApi.Success -and
            $avioApi.BodyJson -and
            $avioApi.BodyJson.Device -and
            $avioApi.BodyJson.Device.AvioV2 -and
            "$($avioApi.BodyJson.Device.AvioV2)" -notmatch 'UNSUPPORTED PROPERTY') {

            return [pscustomobject]@{
                Family = 'AvioV2'
                Path   = '/Device'
                Object = 'AvioV2'
            }
        }
    }
    catch { }

    try {
        $avioApi = Invoke-CrestronApi -Session $Session -Path '/Device/AudioVideoInputOutput' -Method GET -TimeoutSec $TimeoutSec

        if ($avioApi.Success -and
            $avioApi.BodyJson -and
            $avioApi.BodyJson.Device -and
            $avioApi.BodyJson.Device.AudioVideoInputOutput) {

            return [pscustomobject]@{
                Family = 'AudioVideoInputOutput'
                Path   = '/Device'
                Object = 'AudioVideoInputOutput'
            }
        }
    }
    catch { }

    return [pscustomobject]@{
        Family = 'None'
        Path   = ''
        Object = ''
    }
}