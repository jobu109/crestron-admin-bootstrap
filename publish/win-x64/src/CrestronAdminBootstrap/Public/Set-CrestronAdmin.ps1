function Set-CrestronAdmin {
    <#
    .SYNOPSIS
        Provisions the initial admin account on 4-Series Crestron devices found
        by Find-CrestronBootup.
    .DESCRIPTION
        Reads the scanner CSV (or an explicit list of IPs), prompts for
        credentials once, asks for confirmation, then POSTs the create-admin
        payload to /Device/Authentication on each device in parallel.
    .PARAMETER InputCsv
        Path to a CSV produced by Find-CrestronBootup. The script uses rows
        where BootupPage equals 'True'.
    .PARAMETER IP
        Alternatively, one or more IP addresses passed directly (skips CSV).
    .PARAMETER Credential
        Optional PSCredential. If omitted, you'll be prompted interactively.
    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 10.
    .PARAMETER Throttle
        Maximum parallel workers. Default 32.
    .PARAMETER ResultsCsv
        Optional output CSV path for the provisioning results.
    .PARAMETER Force
        Skip the final YES confirmation prompt. Use with care.
    .EXAMPLE
        Set-CrestronAdmin -InputCsv .\crestron-bootup.csv
    .EXAMPLE
        Set-CrestronAdmin -IP 172.22.0.21,172.22.0.22 -ResultsCsv .\provisioned.csv
    #>
    [CmdletBinding(DefaultParameterSetName = 'FromCsv')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromCsv')]
        [string]$InputCsv,

        [Parameter(Mandatory, ParameterSetName = 'FromIPs')]
        [string[]]$IP,

        [pscredential]$Credential,
        [int]$TimeoutSec     = 10,
        [int]$Throttle       = 32,
        [string]$ResultsCsv,
        [switch]$Force
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+. Launch pwsh and rerun."
    }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw "curl.exe not found on PATH."
    }

    # Resolve target list
    if ($PSCmdlet.ParameterSetName -eq 'FromCsv') {
        if (-not (Test-Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }
        $rows = Import-Csv $InputCsv | Where-Object { $_.IP -and $_.BootupPage -eq 'True' }
        if (-not $rows) { throw "No devices with BootupPage=True in $InputCsv" }
        $targets = $rows | Select-Object -ExpandProperty IP
    } else {
        $targets = $IP
    }

    Write-Host "`nLoaded $($targets.Count) device(s):" -ForegroundColor Cyan
    $targets | ForEach-Object { Write-Host "  $_" }

    # Credentials
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Admin account to set on ALL devices listed above"
    }
    if (-not $Credential -or -not $Credential.UserName) {
        throw "No credentials provided. Aborted."
    }

    $adminUser = $Credential.UserName
    $adminPass = $Credential.GetNetworkCredential().Password
    if ([string]::IsNullOrEmpty($adminPass)) { throw "Password is empty. Aborted." }
    if ($adminPass.Length -lt 8) {
        Write-Warning "Password is short (<8 chars). Crestron may reject it."
    }

    # Final confirmation
    if (-not $Force) {
        Write-Host "`n=== ABOUT TO PROVISION $($targets.Count) DEVICE(S) ===" -ForegroundColor Yellow
        Write-Host "Username: $adminUser" -ForegroundColor Yellow
        Write-Host "Password: $('*' * $adminPass.Length) ($($adminPass.Length) chars)" -ForegroundColor Yellow
        $confirm = Read-Host "`nType YES (uppercase) to proceed"
        if ($confirm -cne 'YES') {
            Write-Host "Aborted." -ForegroundColor Red
            return
        }
    }

    # Build JSON body once, write to a temp file so password isn't on the command line
    $payload = @{
        Device = @{
            Authentication = @{
                AuthenticationState = @{
                    AdminUsername = $adminUser
                    AdminPassword = $adminPass
                    IsEnabled     = $true
                }
            }
        }
    } | ConvertTo-Json -Compress -Depth 6

    $bodyFile = New-TemporaryFile
    Set-Content -Path $bodyFile -Value $payload -Encoding UTF8 -NoNewline

    Write-Host "`nProvisioning..." -ForegroundColor Cyan

    try {
        $results = $targets | ForEach-Object -ThrottleLimit $Throttle -Parallel {
            $ip       = $_
            $timeout  = $using:TimeoutSec
            $bodyPath = $using:bodyFile
            $url      = "https://$ip/Device/Authentication"

            $out = & curl.exe -k -s --max-time $timeout `
                -X POST `
                -H "Content-Type: application/json" `
                -H "Accept: application/json" `
                -H "X-Requested-With: XMLHttpRequest" `
                -H "Referer: https://$ip/createUser.html" `
                -H "Origin: https://$ip" `
                --data-binary "@$bodyPath" `
                -w "`n__HTTP_STATUS__:%{http_code}" `
                $url 2>$null

            $text   = ($out -join "`n")
            $status = if ($text -match '__HTTP_STATUS__:(\d+)') { [int]$Matches[1] } else { 0 }
            $body   = $text -replace "`n?__HTTP_STATUS__:\d+$", ''

            $ok = ($status -ge 200 -and $status -lt 300)

            [pscustomobject]@{
                IP        = $ip
                Status    = $status
                Success   = $ok
                Response  = ($body -replace '\s+', ' ').Substring(0, [Math]::Min(200, $body.Length))
                Timestamp = (Get-Date).ToString('s')
            }
        }
    } finally {
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    }

    $results = $results | Sort-Object { [version]$_.IP }
    $okCount  = ($results | Where-Object Success).Count
    $badCount = $results.Count - $okCount

    Write-Host "`nDone. $okCount succeeded, $badCount failed." -ForegroundColor Green
    if ($ResultsCsv) {
        $results | Export-Csv -NoTypeInformation -Path $ResultsCsv
        Write-Host "Results saved to: $ResultsCsv" -ForegroundColor Green
    }
    if ($badCount -gt 0) {
        Write-Host "Failed devices:" -ForegroundColor Yellow
        $results | Where-Object { -not $_.Success } | Format-Table IP, Status, Response -AutoSize -Wrap
    }

    $results
}