function ConvertFrom-CrestronDiscoveryReply {
    param([byte[]]$Data, [string]$IP)
    if ($Data.Length -le 10 -or $Data[0] -ne 0x15) { return }
    # The ten-byte envelope precedes NUL-separated device fields. Field lengths
    # and version punctuation vary across processors and touch panels. Firmware
    # is descriptive metadata, not a condition for discovering a device.
    $fields = @([Text.Encoding]::ASCII.GetString($Data, 10, $Data.Length - 10).Split([char]0) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^[\x20-\x7e]+$' -and $_ -match '[a-zA-Z]' })
    # Ignore empty packets and padded queries containing only the sender name.
    if ($fields.Count -eq 0) { return }
    if ($fields.Count -eq 1 -and $fields[0] -notmatch '\[[^\]]*\d[^\]]*\]') { return }
    $info = $fields -join ' | '
    [pscustomobject]@{
        IP = $IP
        MatchedSig = "Crestron UDP discovery: $info"
        ScannedAt = (Get-Date).ToString('s')
    }
}
