# Real UDP receiver integration with synthetic loopback devices; no hardware required.
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/CrestronAdminBootstrap/CrestronAdminBootstrap.psd1" -Force
$sender = Start-ThreadJob {
    Start-Sleep -Milliseconds 500
    foreach ($ip in @('127.0.0.2', '127.0.0.3')) {
        $socket = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Parse($ip), 0))
        try {
            $reply = [Text.Encoding]::ASCII.GetBytes(([char]0).ToString() * 10 + "ROOM101`0TSW-1070`0")
            $reply[0] = 0x15
            for ($i = 0; $i -lt 3; $i++) {
                $null = $socket.Send($reply, $reply.Length, [Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 41794))
            }
        } finally { $socket.Dispose() }
    }
}
try {
    $rows = @(Find-CrestronDevice -Cidr '127.0.0.2/32' -WaitSec 2)
    $sender | Wait-Job | Receive-Job -ErrorAction Stop
    if ($rows.Count -ne 1 -or $rows[0].IP -ne '127.0.0.2' -or $rows[0].MatchedSig -notmatch 'TSW-1070') {
        throw 'UDP integration failed: missing panel, duplicate reply, or CIDR leak.'
    }
    # Socket disposal must allow a subsequent scan to bind immediately.
    $socket = [Net.Sockets.UdpClient]::new(41794)
    $socket.Dispose()
    'UDP receiver, compact panel reply, duplicate handling, CIDR filtering, and cleanup checks passed.'
} finally {
    $sender | Stop-Job
    $sender | Remove-Job
    Remove-Module CrestronAdminBootstrap
}
