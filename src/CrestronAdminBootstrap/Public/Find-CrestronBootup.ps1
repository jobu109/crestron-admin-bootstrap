function Find-CrestronBootup {
    <#
    .SYNOPSIS
        Scans subnets for 4-Series Crestron devices on the initial create-admin page.
    .DESCRIPTION
        Reads CIDRs from a file, discovers devices via UDP, then probes replies over
        HTTPS, and returns devices whose /createUser.html matches the bootup
        page signatures. Optionally writes results to CSV. No changes made to
        any device — read-only.
    .PARAMETER CidrFile
        Path to a text file containing one CIDR per line. '#' for comments.
    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 4.
    .PARAMETER Throttle
        Maximum parallel workers. Default 64.
    .PARAMETER FullScan
        Probe every host instead of UDP discovery. Slower; supports routed networks
        and devices with AutoDiscovery disabled.
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
        [string]$OutputCsv,
        [switch]$FullScan
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

    # Full sweeps are explicit: never silently scan 65,534 hosts after no replies.
    $targets = @(if ($FullScan) {
        @($cidrs | ForEach-Object { Expand-Cidr -Cidr $_ } | Select-Object -Unique)
    } else {
        @(Find-CrestronDevice -Cidr $cidrs | Select-Object -ExpandProperty IP)
    })
    Write-Host "Checking $(@($targets).Count) candidate device(s) for first-boot pages." -ForegroundColor Cyan
    # Pass the private probe function as source text so it can cross the
        # parallel runspace boundary (PS 7 disallows scriptblock $using: vars).
        $probeText = (Get-Command Test-CrestronBootupPage).Definition

        $results = $targets | ForEach-Object -ThrottleLimit $Throttle -Parallel {
            # Recreate the function inside this runspace from its source text
            ${function:Test-CrestronBootupPage} = $using:probeText
            Test-CrestronBootupPage -IP $_ -TimeoutSec $using:TimeoutSec
        } | Where-Object { $_ } | Sort-Object { [version]$_.IP }

    # Replace previous results even when this scan finds no matching devices.
    if ($OutputCsv) {
        '"IP","BootupPage","MatchedSig","ScannedAt"' | Set-Content -LiteralPath $OutputCsv
        if ($results) { $results | Export-Csv -NoTypeInformation -LiteralPath $OutputCsv }
    }
    if ($results) {
        Write-Host "`nFound $($results.Count) device(s) on bootup page." -ForegroundColor Green
        if ($OutputCsv) {
            Write-Host "Saved to: $OutputCsv" -ForegroundColor Green
        }
    } else {
        Write-Host "`nNo matching devices found." -ForegroundColor Yellow
    }

    $results
}
