function New-CrestronDiscoveryRequest {
    param([string]$Hostname = [Environment]::MachineName)
    # Toolbox wire layout: ten-byte query header, then 256-byte sender name.
    $packet = [byte[]]::new(266)
    [byte[]]$header = 0x14,0,0,0,1,4,0,3,0,0
    $header.CopyTo($packet, 0)
    $name = [Text.Encoding]::ASCII.GetBytes($Hostname)
    [Array]::Copy($name, 0, $packet, 10, [Math]::Min(255, $name.Length))
    return ,$packet
}
