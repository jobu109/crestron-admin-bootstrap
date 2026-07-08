function Invoke-CrestronSshCommand {
    <#
    .SYNOPSIS
        Sends a single command through the Crestron SSH console.
    .DESCRIPTION
        4-Series processors commonly expose the Toolbox/Text Console over SSH
        rather than raw telnet. Uses Windows OpenSSH with a short-lived askpass
        helper so the password is not placed on the ssh.exe command line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$Command,
        [int]$Port = 22,
        [int]$TimeoutSec = 10
    )

    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ssh -or [string]::IsNullOrWhiteSpace("$($ssh.Source)")) {
        throw "ssh.exe was not found. Install Windows OpenSSH Client or enable the device telnet console."
    }

    $password = $Credential.GetNetworkCredential().Password
    $askPass = Join-Path ([IO.Path]::GetTempPath()) "cabs-askpass-$([Guid]::NewGuid().ToString('N')).cmd"

    function ConvertTo-CabsCmdEchoText {
        param([string]$Value)

        if ($null -eq $Value) { return '' }

        $text = $Value
        foreach ($pair in @(
            @('^', '^^'),
            @('%', '%%'),
            @('&', '^&'),
            @('<', '^<'),
            @('>', '^>'),
            @('|', '^|')
        )) {
            $text = $text.Replace($pair[0], $pair[1])
        }

        return $text
    }

    try {
        $askPassBody = "@echo off`r`necho $(ConvertTo-CabsCmdEchoText $password)"
        Set-Content -LiteralPath $askPass -Value $askPassBody -Encoding ASCII -Force

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = "$($ssh.Source)"
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $startInfo.Environment['SSH_ASKPASS'] = $askPass
        $startInfo.Environment['SSH_ASKPASS_REQUIRE'] = 'force'
        $startInfo.Environment['DISPLAY'] = 'cabs'

        foreach ($arg in @(
            '-o', 'BatchMode=no',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'PreferredAuthentications=password,keyboard-interactive',
            '-o', 'PubkeyAuthentication=no',
            '-p', "$Port",
            "$($Credential.UserName)@$IP",
            $Command
        )) {
            [void]$startInfo.ArgumentList.Add($arg)
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)
        if (-not $process) {
            throw "Could not start ssh.exe."
        }

        $timeoutMs = [Math]::Max(5000, $TimeoutSec * 1000)
        if (-not $process.WaitForExit($timeoutMs)) {
            try { $process.Kill($true) } catch { }
            throw "SSH command '$Command' timed out on $IP."
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $output = "$stdout$stderr"

        if ($process.ExitCode -ne 0) {
            $clean = ($output -replace '\s+', ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($clean)) {
                $clean = "ssh.exe exited with code $($process.ExitCode)."
            }
            throw "SSH command '$Command' failed on ${IP}: $clean"
        }

        [pscustomobject]@{
            IP        = $IP
            Port      = $Port
            Command   = $Command
            Success   = $true
            Output    = $output
            Timestamp = (Get-Date).ToString('s')
        }
    }
    finally {
        Remove-Item -LiteralPath $askPass -Force -ErrorAction SilentlyContinue
    }
}
