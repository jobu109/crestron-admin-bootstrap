function Test-CrestronAdmin {
    <#
    .SYNOPSIS
        Verifies that previously-provisioned 4-Series Crestron devices are no
        longer on the create-admin bootup page.
    .DESCRIPTION
        Reads a CSV of IPs (typically the results CSV from Set-CrestronAdmin)
        and re-probes each one. A device is considered Verified when its
        /createUser.html no longer matches the bootup-page signatures, meaning
        the admin account is set and the device has moved past first-boot.
    .PARAMETER InputCsv
        Path to a CSV containing an IP column. Typically the ResultsCsv from
        Set-CrestronAdmin, but any CSV with IP works. If a Success column is
        present, only rows where Success='True' are tested by default.
    .PARAMETER IP
        Alternatively, one or more IP addresses passed directly (skips CSV).
    .PARAMETER IncludeFailed
        When reading a Set-CrestronAdmin results CSV, also test rows where
        Success='False'. Useful to confirm failed provisioning attempts
        truly didn't take.
    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 4.
    .PARAMETER Throttle
        Maximum parallel workers. Default 64.
    .PARAMETER OutputCsv
        Optional output CSV path for the verification results.
    .EXAMPLE
        Test-CrestronAdmin -InputCsv .\crestron-provisioned.csv
    .EXAMPLE
        Test-CrestronAdmin -IP 172.22.0.21,172.22.0.22
    #>
    [CmdletBinding(DefaultParameterSetName = 'FromCsv')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromCsv')]
        [string]$InputCsv,

        [Parameter(Mandatory, ParameterSetName = 'FromIPs')]
        [string[]]$IP,

        [switch]$IncludeFailed,
        [int]$TimeoutSec = 4,
        [int]$Throttle   = 64,
        [string]$OutputCsv
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
        $rows = Import-Csv $InputCsv
        if (-not $rows) { throw "Input CSV is empty: $InputCsv" }

        # If the CSV looks like a Set-CrestronAdmin results CSV (has Success
        # column), filter to successes by default
        $hasSuccessCol = $rows[0].PSObject.Properties.Name -contains 'Success'
        if ($hasSuccessCol -and -not $IncludeFailed) {
            $rows = $rows | Where-Object { $_.Success -eq 'True' }
        }
        $targets = $rows | Where-Object { $_.IP } | Select-Object -ExpandProperty IP
    } else {
        $targets = $IP
    }

    if (-not $targets) { throw "No targets to verify." }

    Write-Host "Verifying $($targets.Count) device(s)..." -ForegroundColor Cyan

    # Pass the private probe function as source text across parallel runspaces
    # (PS 7 disallows scriptblock $using: vars). Same pattern as Find-CrestronBootup.
    $probeText = (Get-Command Test-CrestronBootupPage).Definition

    $results = $targets | ForEach-Object -ThrottleLimit $Throttle -Parallel {
        ${function:Test-CrestronBootupPage} = $using:probeText
        $ip = $_
        $hit = Test-CrestronBootupPage -IP $ip -TimeoutSec $using:TimeoutSec

        # If the probe returns $null, the device is NOT on the bootup page → verified
        # If the probe returns a match, the device IS still on the bootup page → not verified
        if ($null -eq $hit) {
            [pscustomobject]@{
                IP        = $ip
                Verified  = $true
                State     = 'PastBootup'
                Detail    = 'createUser.html no longer matches bootup signatures'
                CheckedAt = (Get-Date).ToString('s')
            }
        } else {
            [pscustomobject]@{
                IP        = $ip
                Verified  = $false
                State     = 'StillOnBootup'
                Detail    = "Matched signature: $($hit.MatchedSig)"
                CheckedAt = (Get-Date).ToString('s')
            }
        }
    } | Sort-Object { [version]$_.IP }

    $okCount  = ($results | Where-Object Verified).Count
    $badCount = $results.Count - $okCount

    Write-Host "`n$okCount verified past bootup, $badCount still on bootup page." -ForegroundColor $(if ($badCount -eq 0) { 'Green' } else { 'Yellow' })
    if ($OutputCsv) {
        $results | Export-Csv -NoTypeInformation -Path $OutputCsv
        Write-Host "Results saved to: $OutputCsv" -ForegroundColor Green
    }
    if ($badCount -gt 0) {
        Write-Host "Devices still on bootup page:" -ForegroundColor Yellow
        $results | Where-Object { -not $_.Verified } | Format-Table IP, Detail -AutoSize
    }

    $results
}