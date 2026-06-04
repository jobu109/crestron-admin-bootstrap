function Invoke-CrestronTelnetCommand {
    <#
    .SYNOPSIS
        Sends a single command through the Crestron text console over TCP.
    .DESCRIPTION
        Used as a fallback for settings that are exposed by console command but
        not by the CresNext web API. Tries port 41795 (Crestron 4-Series console)
        first, then falls back to port 23 (standard telnet). Handles the common
        username and password prompts, sends the requested command, then exits.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$Command,
        [int[]]$Ports = @(41795, 23),
        [int]$TimeoutSec = 10
    )

    # Try each port in order; use a short per-port timeout so a refused/filtered
    # port does not stall the whole operation.
    $perPortSec = [Math]::Min(5, $TimeoutSec)
    $client = $null
    $connectedPort = 0

    foreach ($tryPort in $Ports) {
        $tryClient = [System.Net.Sockets.TcpClient]::new()
        $isLast = ($tryPort -eq $Ports[-1])
        $waitSec = if ($isLast) { $TimeoutSec } else { $perPortSec }

        try {
            $async = $tryClient.BeginConnect($IP, $tryPort, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($waitSec))) {
                $tryClient.EndConnect($async)
                $client = $tryClient
                $connectedPort = $tryPort
                break
            }
        }
        catch { }

        try { $tryClient.Dispose() } catch { }
    }

    if (-not $client) {
        $portList = $Ports -join ', '
        throw "Could not connect to console on ${IP} (tried ports: $portList)."
    }

    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 750
        $stream.WriteTimeout = 2000
        $encoding = [System.Text.Encoding]::ASCII

        function Read-CrestronTelnetText {
            param(
                [System.Net.Sockets.NetworkStream]$Stream,
                [int]$MaxMilliseconds = 2500
            )

            $deadline = [DateTime]::UtcNow.AddMilliseconds($MaxMilliseconds)
            $buffer = New-Object byte[] 4096
            $builder = [System.Text.StringBuilder]::new()

            while ([DateTime]::UtcNow -lt $deadline) {
                if (-not $Stream.DataAvailable) {
                    Start-Sleep -Milliseconds 100
                    continue
                }

                try {
                    $read = $Stream.Read($buffer, 0, $buffer.Length)
                }
                catch {
                    break
                }

                if ($read -le 0) {
                    break
                }

                for ($i = 0; $i -lt $read; $i++) {
                    $b = $buffer[$i]

                    # Drop telnet negotiation/control bytes and keep readable text.
                    if ($b -eq 255) {
                        $i += 2
                        continue
                    }

                    if ($b -eq 0) { continue }
                    if ($b -lt 32 -and $b -notin 9,10,13) { continue }

                    [void]$builder.Append([char]$b)
                }

                $deadline = [DateTime]::UtcNow.AddMilliseconds(400)
            }

            $builder.ToString()
        }

        function Write-CrestronTelnetLine {
            param(
                [System.Net.Sockets.NetworkStream]$Stream,
                [System.Text.Encoding]$Encoding,
                [string]$Line
            )

            $bytes = $Encoding.GetBytes("$Line`r`n")
            $Stream.Write($bytes, 0, $bytes.Length)
            $Stream.Flush()
        }

        $output = Read-CrestronTelnetText -Stream $stream
        $user = $Credential.UserName
        $pass = $Credential.GetNetworkCredential().Password

        if ($output -match '(?i)(login|username|user\s*name|user:|name:)') {
            Write-CrestronTelnetLine -Stream $stream -Encoding $encoding -Line $user
            $output += Read-CrestronTelnetText -Stream $stream
        }

        if ($output -match '(?i)password') {
            Write-CrestronTelnetLine -Stream $stream -Encoding $encoding -Line $pass
            $output += Read-CrestronTelnetText -Stream $stream
        }

        if ($output -match '(?i)(invalid|incorrect|failed|denied).{0,40}(login|password|credential|auth)') {
            throw "Telnet authentication failed on $IP."
        }

        Write-CrestronTelnetLine -Stream $stream -Encoding $encoding -Line $Command
        $output += Read-CrestronTelnetText -Stream $stream -MaxMilliseconds ([Math]::Max(2500, $TimeoutSec * 1000))

        if ($output -match '(?i)(invalid\s+command|unknown\s+command|syntax\s+error|command\s+not\s+found)') {
            throw "Telnet command '$Command' was rejected by $IP."
        }

        try {
            Write-CrestronTelnetLine -Stream $stream -Encoding $encoding -Line 'exit'
            $output += Read-CrestronTelnetText -Stream $stream -MaxMilliseconds 500
        }
        catch { }

        [pscustomobject]@{
            IP        = $IP
            Port      = $connectedPort
            Command   = $Command
            Success   = $true
            Output    = $output
            Timestamp = (Get-Date).ToString('s')
        }
    }
    finally {
        try { $client.Close() } catch { }
    }
}
