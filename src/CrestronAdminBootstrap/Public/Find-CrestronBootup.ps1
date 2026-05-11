function Find-CrestronBootup {
    <#
    .SYNOPSIS
        Scans subnets for 4-Series Crestron devices on the initial create-admin page.
    .DESCRIPTION
        Reads CIDRs from a file, probes each IP in parallel using curl.exe over
        HTTPS, and returns devices whose /createUser.html matches the bootup
        page signatures. Optionally writes results to CSV. No changes made to
        any device — read-only.
    .PARAMETER CidrFile
        Path to a text file containing one CIDR per line. '#' for comments.
    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 4.
    .PARAMETER Throttle
        Maximum parallel workers. Default 64.
    .PARAMETER OutputCsv
        Optional output CSV path. If omitted, results are only returned to the pipeline.
    .EXAMPLE
        Find-CrestronBootup -CidrFile .\subnets.txt
    .EXAMPLE
        Find-CrestronBootup -CidrFile .\subnets.txt -OutputCsv .\results.csv -Throttle 128
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CidrFile,
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
    if (-not (Test-Path $CidrFile)) {
        throw "CIDR file not found: $CidrFile"
    }

    # Parse CIDRs (skip blanks and # comments)
    $cidrs = Get-Content $CidrFile |
        ForEach-Object { ($_ -split '#')[0].Trim() } |
        Where-Object   { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' }

    if (-not $cidrs) {
        throw "No valid CIDRs found in $CidrFile"
    }

    # Expand to IPs
    $targets = foreach ($c in $cidrs) { Expand-Cidr -Cidr $c }
    $targets = $targets | Select-Object -Unique

    Write-Host "Loaded $($cidrs.Count) subnet(s) -> $($targets.Count) hosts." -ForegroundColor Cyan
    Write-Host "Probing..." -ForegroundColor Cyan

    # Pass the private probe function as source text so it can cross the
        # parallel runspace boundary (PS 7 disallows scriptblock $using: vars).
        $probeText = (Get-Command Test-CrestronBootupPage).Definition

        $results = $targets | ForEach-Object -ThrottleLimit $Throttle -Parallel {
            # Recreate the function inside this runspace from its source text
            ${function:Test-CrestronBootupPage} = $using:probeText
            Test-CrestronBootupPage -IP $_ -TimeoutSec $using:TimeoutSec
        } | Where-Object { $_ } | Sort-Object { [version]$_.IP }

    if ($results) {
        Write-Host "`nFound $($results.Count) device(s) on bootup page." -ForegroundColor Green
        if ($OutputCsv) {
            $results | Export-Csv -NoTypeInformation -Path $OutputCsv
            Write-Host "Saved to: $OutputCsv" -ForegroundColor Green
        }
    } else {
        Write-Host "`nNo matching devices found." -ForegroundColor Yellow
    }

    $results
}