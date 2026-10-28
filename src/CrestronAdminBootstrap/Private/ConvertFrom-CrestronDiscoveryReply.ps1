function ConvertFrom-CrestronDiscoveryReply {
    param([byte[]]$Data, [string]$IP)
    if ($Data.Length -lt 272) { return }
    # Replies contain a 256-byte name followed by device/firmware information.
    # Validate the information block to reject queries and unrelated UDP traffic.
    $info = [Text.Encoding]::ASCII.GetString($Data, 266, [Math]::Min(128, $Data.Length - 266)).Split([char]0)[0].Trim()
    if ($info -notmatch '^[\x20-\x7e]+$' -or $info -notmatch '\[v[0-9]' ) { return }
    [pscustomobject]@{
        IP = $IP
        MatchedSig = "Crestron UDP discovery: $info"
        ScannedAt = (Get-Date).ToString('s')
    }
}
