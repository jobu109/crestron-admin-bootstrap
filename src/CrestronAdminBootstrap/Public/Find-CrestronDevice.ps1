function Find-CrestronDevice {
    <#
    .SYNOPSIS
        Discovers Crestron devices using UDP auto-discovery, without enumerating hosts.
    .DESCRIPTION
        Sends three discovery broadcasts from each active IPv4 adapter. Results are
        restricted to the supplied CIDRs. Broadcasts do not cross routed VLANs.
        Requires UDP 41794; close Toolbox if it holds the discovery port.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Cidr,
        [ValidateRange(1, 30)][int]$WaitSec = 6
    )

    function ConvertTo-DiscoveryNumber([System.Net.IPAddress]$Address) {
        $b = $Address.GetAddressBytes()
        if ($b.Length -ne 4) { throw 'Discovery requires IPv4 CIDRs.' }
        [uint32](([uint64]$b[0] -shl 24) -bor ([uint64]$b[1] -shl 16) -bor ([uint64]$b[2] -shl 8) -bor $b[3])
    }
    $ranges = @(foreach ($value in $Cidr) {
        $parts = $value.Split('/')
        $bits = 0
        if ($parts.Count -ne 2 -or -not [int]::TryParse($parts[1], [ref]$bits) -or $bits -lt 0 -or $bits -gt 32) {
            throw "Invalid IPv4 CIDR: $value"
        }
        $number = ConvertTo-DiscoveryNumber ([System.Net.IPAddress]::Parse($parts[0]))
        $mask = if ($bits -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $bits) }
        @{ Network = $number -band $mask; Mask = $mask }
    })
    # CIP discovery wire format: 316 bytes, hostname at offset 27.
    $packet = [byte[]]::new(316)
    [byte[]]$header = 0x14,0,0,0,1,4,0,3,0,0
    $header.CopyTo($packet, 0)
    $hostBytes = [Text.Encoding]::ASCII.GetBytes([Environment]::MachineName)
    [Array]::Copy($hostBytes, 0, $packet, 27, [Math]::Min(16, $hostBytes.Length))
    $listeners = [Collections.Generic.List[object]]::new()
    $localAddresses = [Collections.Generic.HashSet[string]]::new()
    $found = @{}
    try {
        foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
            foreach ($address in $nic.GetIPProperties().UnicastAddresses) {
                if ($address.Address.AddressFamily -ne 'InterNetwork') { continue }
                $null = $localAddresses.Add($address.Address.ToString())
                $udp = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
                try {
                    $udp.ExclusiveAddressUse = $true
                    $udp.Client.Bind([Net.IPEndPoint]::new($address.Address, 41794))
                    $udp.EnableBroadcast = $true
                    $udp.Client.ReceiveBufferSize = 1048576
                    $ipBytes = $address.Address.GetAddressBytes()
                    $maskBytes = $address.IPv4Mask.GetAddressBytes()
                    $broadcast = [byte[]]::new(4)
                    for ($i = 0; $i -lt 4; $i++) { $broadcast[$i] = $ipBytes[$i] -bor ($maskBytes[$i] -bxor 255) }
                    $listeners.Add(@{ Client = $udp; Endpoint = [Net.IPEndPoint]::new([Net.IPAddress]::new($broadcast), 41794) })
                } catch {
                    $udp.Dispose()
                    Write-Warning "Cannot use discovery on $($address.Address): $($_.Exception.Message)"
                }
            }
        }
        if ($listeners.Count -eq 0) { throw 'No IPv4 discovery sockets available. Check adapters and UDP 41794 (Toolbox may be using it).' }
        Write-Host "UDP discovery on $($listeners.Count) adapter address(es), ${WaitSec}s response window."
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $nextSend = 0.0
        $attempt = 0
        while ($timer.Elapsed.TotalSeconds -lt $WaitSec) {
            if ($attempt -lt 3 -and $timer.Elapsed.TotalSeconds -ge $nextSend) {
                foreach ($entry in $listeners) {
                    try { $null = $entry.Client.Send($packet, $packet.Length, $entry.Endpoint) }
                    catch { Write-Warning "Discovery send failed: $($_.Exception.Message)" }
                }
                $attempt++
                $nextSend = $attempt * $WaitSec / 3.0
            }
            foreach ($entry in $listeners) {
                # Bound each drain so heavy traffic cannot extend the deadline.
                for ($n = 0; $n -lt 256 -and $entry.Client.Available -gt 0; $n++) {
                    $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
                    $data = $entry.Client.Receive([ref]$remote)
                    $ip = $remote.Address.ToString()
                    if ($localAddresses.Contains($ip) -or $data.Length -lt 272 -or [Linq.Enumerable]::SequenceEqual[byte]($data, $packet)) { continue }
                    $number = ConvertTo-DiscoveryNumber $remote.Address
                    if (-not @($ranges | Where-Object { ($number -band $_.Mask) -eq $_.Network }).Count) { continue }
                    $reply = ConvertFrom-CrestronDiscoveryReply -Data $data -IP $ip
                    if ($reply) { $found[$ip] = $reply }
                }
            }
            Start-Sleep -Milliseconds 20
        }
    } finally {
        foreach ($entry in $listeners) { $entry.Client.Dispose() }
    }
    if ($found.Count -eq 0) { Write-Warning 'No discovery replies in the selected CIDRs. Broadcast discovery stays on the local LAN; check VLAN, firewall and device AutoDiscovery settings. Use Find-CrestronBootup -FullScan for a routed sweep.' }
    $found.Values | Sort-Object { [version]$_.IP }
}
