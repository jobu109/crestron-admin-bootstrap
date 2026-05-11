function Test-CrestronBootupPage {
    <#
    .SYNOPSIS
        Probes a single IP to determine if it's a 4-Series Crestron device
        sitting on the initial create-admin (bootup) page.
    .DESCRIPTION
        Performs a quick TCP knock on 443, then fetches /createUser.html via
        curl.exe and matches against signatures unique to the 4-Series
        create-admin form. Returns a PSCustomObject on match, $null otherwise.
    .PARAMETER IP
        Target IP address.
    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 4.
    .PARAMETER Signatures
        Strings that must appear in /createUser.html to count as a match.
    .EXAMPLE
        Test-CrestronBootupPage -IP 172.22.0.21
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IP,
        [int]$TimeoutSec = 4,
        [string[]]$Signatures = @(
            'cred_createuser_btn',
            'cred_userid_inputtext',
            'id="createuser"',
            'createUser.html'
        )
    )

    # Fast TCP knock on 443 — skip dead IPs cheaply
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $iar = $tcp.BeginConnect($IP, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(1500)) {
            $tcp.Close()
            return $null
        }
        $tcp.EndConnect($iar)
        $tcp.Close()
    } catch {
        return $null
    }

    # Pull the create-admin page via curl.exe (avoids .NET TLS callback issues
    # in parallel runspaces — see note in module README)
    $body = & curl.exe -k -s --max-time $TimeoutSec "https://$IP/createUser.html" 2>$null
    if (-not $body) { return $null }
    $body = $body -join "`n"

    # Signature match
    $matchedSig = $null
    foreach ($s in $Signatures) {
        if ($body -match [regex]::Escape($s)) {
            $matchedSig = $s
            break
        }
    }
    if (-not $matchedSig) { return $null }

    [pscustomobject]@{
        IP         = $IP
        BootupPage = $true
        MatchedSig = $matchedSig
        ScannedAt  = (Get-Date).ToString('s')
    }
}