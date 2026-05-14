function Get-CrestronAvSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,

        [int]$TimeoutSec = 15
    )

    $ip = $Session.IP

    $result = [ordered]@{
        IP                         = $ip
        Model                      = ''
        SupportsStreamTransmit     = $false
        SupportsStreamReceive      = $false
        SupportsAvioV2             = $false
        SupportsAudioVideoIO       = $false
        SupportsEdidManagement     = $false
        SupportsAvRouting          = $false
        AvApiFamily                = 'None'
        AvApiVersion               = ''
        SupportsGlobalEdid         = $false

        DeviceMode                 = ''
        ActiveVideoSource          = ''
        ActiveAudioSource          = ''

        TransmitMulticastAddresses = @()
        ReceiveMulticastAddresses  = @()

        Inputs                     = @()
        Outputs                    = @()
        EdidOptions                = @()
        EdidNames                  = @()

        FetchedAt                  = (Get-Date).ToString('s')
    }

    try {
        $infoApi = Invoke-CrestronApi -Session $Session -Path '/Device/DeviceInfo' -Method GET -TimeoutSec $TimeoutSec
        if ($infoApi.Success -and $infoApi.BodyJson.Device.DeviceInfo) {
            $info = $infoApi.BodyJson.Device.DeviceInfo

            if ($info.PSObject.Properties.Name -contains 'Model') {
                $result.Model = "$($info.Model)"
            }
            elseif ($info.PSObject.Properties.Name -contains 'ModelName') {
                $result.Model = "$($info.ModelName)"
            }
        }
    }
    catch { }

    try {
        $dsApi = Invoke-CrestronApi -Session $Session -Path '/Device/DeviceSpecific' -Method GET -TimeoutSec $TimeoutSec
        if ($dsApi.Success -and $dsApi.BodyJson.Device.DeviceSpecific) {
            $ds = $dsApi.BodyJson.Device.DeviceSpecific

            if ($ds.PSObject.Properties.Name -contains 'DeviceMode') {
                $result.DeviceMode = "$($ds.DeviceMode)"
            }

            if ($ds.PSObject.Properties.Name -contains 'ActiveVideoSource') {
                $result.ActiveVideoSource = "$($ds.ActiveVideoSource)"
            }

            if ($ds.PSObject.Properties.Name -contains 'ActiveAudioSource') {
                $result.ActiveAudioSource = "$($ds.ActiveAudioSource)"
            }
        }
    }
    catch { }

    try {
        $txApi = Invoke-CrestronApi -Session $Session -Path '/Device/StreamTransmit' -Method GET -TimeoutSec $TimeoutSec
        if ($txApi.Success -and $txApi.BodyJson.Device.StreamTransmit) {
            $result.SupportsStreamTransmit = $true

            $streams = @($txApi.BodyJson.Device.StreamTransmit.Streams)
            $result.TransmitMulticastAddresses = @($streams | ForEach-Object {
                [pscustomobject]@{
                    StreamType       = "$($_.StreamType)"
                    SessionInitiation = "$($_.SessionInitiation)"
                    TransportMode    = "$($_.TransportMode)"
                    MulticastAddress = "$($_.MulticastAddress)"
                    HdcpMode         = "$($_.HdcpTransmitterMode)"
                    Status           = "$($_.Status)"
                }
            })
        }
    }
    catch { }

    try {
        $rxApi = Invoke-CrestronApi -Session $Session -Path '/Device/StreamReceive' -Method GET -TimeoutSec $TimeoutSec
        if ($rxApi.Success -and $rxApi.BodyJson.Device.StreamReceive) {
            $result.SupportsStreamReceive = $true

            $streams = @($rxApi.BodyJson.Device.StreamReceive.Streams)
            $result.ReceiveMulticastAddresses = @($streams | ForEach-Object {
                [pscustomobject]@{
                    StreamType       = "$($_.StreamType)"
                    SessionInitiation = "$($_.SessionInitiation)"
                    TransportMode    = "$($_.TransportMode)"
                    MulticastAddress = "$($_.MulticastAddress)"
                    StreamLocation   = "$($_.StreamLocation)"
                    HdcpMode         = "$($_.HdcpTransmitterMode)"
                    Status           = "$($_.Status)"
                }
            })
        }
    }
    catch { }

    try {
        $avioApi = Invoke-CrestronApi -Session $Session -Path '/Device/AvioV2' -Method GET -TimeoutSec $TimeoutSec

        if ($avioApi.Success -and
            $avioApi.BodyJson -and
            $avioApi.BodyJson.Device -and
            $avioApi.BodyJson.Device.AvioV2 -and
            "$($avioApi.BodyJson.Device.AvioV2)" -notmatch 'UNSUPPORTED PROPERTY') {

            $avio = $avioApi.BodyJson.Device.AvioV2
            $result.SupportsAvioV2 = $true
            $result.AvApiFamily = 'AvioV2'
            $result.SupportsGlobalEdid = $true

            if ($avio.PSObject.Properties.Name -contains 'Version') {
                $result.AvApiVersion = "$($avio.Version)"
            }
        }
    }
    catch { }

    try {
        $avApi = Invoke-CrestronApi -Session $Session -Path '/Device/AudioVideoInputOutput' -Method GET -TimeoutSec $TimeoutSec
        if ($avApi.Success -and $avApi.BodyJson.Device.AudioVideoInputOutput) {
            $result.SupportsAudioVideoIO = $true

            if ($result.AvApiFamily -eq 'None') {
                $result.AvApiFamily = 'AudioVideoInputOutput'
            }

            $av = $avApi.BodyJson.Device.AudioVideoInputOutput

            if ($result.AvApiFamily -eq 'AudioVideoInputOutput') {
                if ($av.PSObject.Properties.Name -contains 'Version') {
                    $result.AvApiVersion = "$($av.Version)"
                }

                try {
                    $result.SupportsGlobalEdid = ([version]$result.AvApiVersion -ge [version]'2.5.0')
                }
                catch {
                    $result.SupportsGlobalEdid = $false
                }
            }

            $edidOptions = @()

            foreach ($input in @($av.Inputs)) {
                foreach ($port in @($input.Ports)) {
                    foreach ($edidItem in @($port.Edid.EdidList)) {
                        if ($edidItem.Name) {
                            $edidOptions += [pscustomobject]@{
                                Name = "$($edidItem.Name)"
                                Type = "$($edidItem.Type)"
                            }
                        }
                    }
                }
            }

            if ($edidOptions.Count -gt 0) {
                $result.EdidOptions = @($result.EdidOptions + $edidOptions |
                    Where-Object { $_.Name } |
                    Sort-Object Name, Type -Unique)
                $result.EdidNames = @($result.EdidOptions |
                    Select-Object -ExpandProperty Name -Unique |
                    Sort-Object)
            }

            $result.Inputs = @($av.Inputs | ForEach-Object {
                $input = $_

                foreach ($port in @($input.Ports)) {
                    [pscustomobject]@{
                        InputName              = "$($input.Name)"
                        InputUuid              = "$($input.Uuid)"
                        PortType               = "$($port.PortType)"
                        PortUuid               = "$($port.Uuid)"
                        CurrentEdid            = "$($port.Edid.CurrentEdid)"
                        EdidOptions            = @($port.Edid.EdidList | ForEach-Object { "$($_.Name)" })
                        HdcpReceiverCapability = "$($port.Hdmi.HdcpReceiverCapability)"
                        HdcpState              = "$($port.Hdmi.HdcpState)"
                        SourceHdcpActive       = [bool]$port.Hdmi.IsSourceHdcpActive
                        SyncDetected           = [bool]$port.IsSyncDetected
                        HorizontalResolution   = [int]$port.HorizontalResolution
                        VerticalResolution     = [int]$port.VerticalResolution
                        FramesPerSecond        = [int]$port.FramesPerSecond
                    }
                }
            })

            $result.Outputs = @($av.Outputs | ForEach-Object {
                $output = $_

                foreach ($port in @($output.Ports)) {
                    [pscustomobject]@{
                        OutputName          = "$($output.Name)"
                        OutputUuid          = "$($output.Uuid)"
                        PortType            = "$($port.PortType)"
                        PortUuid            = "$($port.Uuid)"
                        Resolution          = "$($port.Resolution)"
                        HorizontalResolution = [int]$port.HorizontalResolution
                        VerticalResolution   = [int]$port.VerticalResolution
                        FramesPerSecond      = [int]$port.FramesPerSecond
                        HdcpTransmitterMode  = "$($port.Hdmi.HdcpTransmitterMode)"
                        HdcpState            = "$($port.Hdmi.HdcpState)"
                        SinkConnected        = [bool]$port.IsSinkConnected
                        Transmitting         = [bool]$port.Hdmi.Transmitting
                        DisabledByHdcp       = [bool]$port.Hdmi.DisabledByHdcp
                        DownstreamEdidName   = "$($port.DownstreamEdid.NameString)"
                        DownstreamPreferred  = "$($port.DownstreamEdid.PrefTimingString)"
                    }
                }
            })
        }
    }
    catch { }

    try {
        $edidApi = Invoke-CrestronApi -Session $Session -Path '/Device/EdidMgmnt' -Method GET -TimeoutSec $TimeoutSec
        if ($edidApi.Success -and $edidApi.BodyJson.Device.EdidMgmnt) {
            $result.SupportsEdidManagement = $true
            $edid = $edidApi.BodyJson.Device.EdidMgmnt

            $names = @()
            $edidOptions = @()

            if ($edid.SystemEdidList) {
                foreach ($p in $edid.SystemEdidList.PSObject.Properties) {
                    if ($p.Value.Name) {
                        $name = "$($p.Value.Name)"
                        $names += $name
                        $edidOptions += [pscustomobject]@{
                            Name = $name
                            Type = 'System'
                        }
                    }
                }
            }

            if ($edid.CopyEdidList) {
                foreach ($p in $edid.CopyEdidList.PSObject.Properties) {
                    if ($p.Value.Name) {
                        $name = "$($p.Value.Name)"
                        $names += $name
                        $edidOptions += [pscustomobject]@{
                            Name = $name
                            Type = 'Copy'
                        }
                    }
                }
            }

            if ($edidOptions.Count -gt 0) {
                $result.EdidOptions = @($result.EdidOptions + $edidOptions |
                    Where-Object { $_.Name } |
                    Sort-Object Name, Type -Unique)
            }

            $result.EdidNames = @($result.EdidNames + $names |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique)
        }
    }
    catch { }

    try {
        $routeApi = Invoke-CrestronApi -Session $Session -Path '/Device/AvRouting' -Method GET -TimeoutSec $TimeoutSec
        if ($routeApi.Success -and $routeApi.BodyJson.Device.AvRouting) {
            $result.SupportsAvRouting = $true
        }
    }
    catch { }

    [pscustomobject]$result
}
