function Expand-Cidr {
    <#
    .SYNOPSIS
        Expands a CIDR block into an array of host IP addresses.
    .DESCRIPTION
        Skips the network and broadcast addresses. Returns string IPs.
    .EXAMPLE
        Expand-Cidr -Cidr '10.10.20.0/24'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cidr
    )

    $base, $bits = $Cidr -split '/'
    $bits  = [int]$bits
    $bytes = ([IPAddress]$base).GetAddressBytes()
    [Array]::Reverse($bytes)
    $start = [BitConverter]::ToUInt32($bytes, 0) -band ([uint32]::MaxValue -shl (32 - $bits))
    $count = [math]::Pow(2, 32 - $bits)

    for ($i = 1; $i -lt $count - 1; $i++) {
        $b = [BitConverter]::GetBytes([uint32]($start + $i))
        [Array]::Reverse($b)
        ([IPAddress]$b).ToString()
    }
}