<#
.SYNOPSIS
    Menu-driven launcher for CrestronAdminBootstrap. Bundled into
    CrestronBootstrap.exe by wrapper\Build-Exe.ps1.

.DESCRIPTION
    Presents a simple numbered menu:
      [1] Scan a subnet list
      [2] Provision from last scan
      [3] Verify provisioning
      [4] Full workflow (scan -> provision -> verify)
      [Q] Quit

    Designed for techs who shouldn't have to remember PowerShell syntax.
    All work happens in the current working directory so CSVs end up next
    to the .exe.
#>
[CmdletBinding()]
param(
    [string]$WorkingDirectory = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

# Normalize to an absolute path before anything else uses it
if (-not [IO.Path]::IsPathRooted($WorkingDirectory)) {
    $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
}

$ErrorActionPreference = 'Stop'

# ---- Module discovery --------------------------------------------------------
function Initialize-Module {
    if (-not (Get-Module -ListAvailable CrestronAdminBootstrap)) {
        Write-Host "CrestronAdminBootstrap module is not installed." -ForegroundColor Yellow
        Write-Host "Run the installer first:" -ForegroundColor Yellow
        Write-Host "  iex (irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1)" -ForegroundColor Cyan
        Pause-Return
        exit 1
    }
    Import-Module CrestronAdminBootstrap -Force
}

function Pause-Return {
    Write-Host ""
    Read-Host "Press Enter to return to the menu"
}

# ---- Working files -----------------------------------------------------------
$SubnetsFile  = Join-Path $WorkingDirectory 'subnets.txt'
$ScanCsv      = Join-Path $WorkingDirectory 'crestron-bootup.csv'
$ProvisionCsv = Join-Path $WorkingDirectory 'crestron-provisioned.csv'
$VerifyCsv    = Join-Path $WorkingDirectory 'crestron-verified.csv'

# ---- Menu actions ------------------------------------------------------------
function Read-Subnets {
    <#
    .SYNOPSIS
        Prompts the user for CIDRs and writes them to subnets.txt.
        Pre-fills 172.22.0.0/24 as the default for an empty list.
    #>
    Write-Host ""
    Write-Host "Enter one CIDR per line. Press Enter on a blank line to finish."
    Write-Host "Press Enter with no input on the first line to accept the default."
    Write-Host ""

    $lines = @()
    $first = $true
    while ($true) {
        if ($first) {
            $defaultCidr = '172.22.0.0/24'
            $entry = Read-Host "  CIDR [$defaultCidr]"
            if ([string]::IsNullOrWhiteSpace($entry)) {
                if ($lines.Count -eq 0) { $entry = $defaultCidr } else { break }
            }
            $first = $false
        } else {
            $entry = Read-Host '  CIDR'
            if ([string]::IsNullOrWhiteSpace($entry)) { break }
        }

        if ($entry -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') {
            Write-Host "    Not a valid CIDR (expected like 10.10.20.0/24). Skipped." -ForegroundColor Yellow
            continue
        }
        $lines += $entry
    }

    if ($lines.Count -eq 0) {
        return $null
    }

    $lines | Set-Content -Path $SubnetsFile -Encoding UTF8
    Write-Host ""
    Write-Host "Saved $($lines.Count) CIDR(s) to $SubnetsFile" -ForegroundColor Green
    return $SubnetsFile
}

function Invoke-Scan {
    Clear-Host
    Write-Host "=== Scan ===" -ForegroundColor Cyan

    # If subnets.txt exists, offer to reuse it
    if (Test-Path $SubnetsFile) {
        Write-Host ""
        Write-Host "Existing subnets list:" -ForegroundColor Cyan
        Get-Content $SubnetsFile | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        $ans = Read-Host "Use this list? (Y/N)"
        if ($ans -notmatch '^[Yy]') {
            $result = Read-Subnets
            if (-not $result) {
                Write-Host "No CIDRs entered. Cancelled." -ForegroundColor Yellow
                Pause-Return
                return
            }
        }
    } else {
        $result = Read-Subnets
        if (-not $result) {
            Write-Host "No CIDRs entered. Cancelled." -ForegroundColor Yellow
            Pause-Return
            return
        }
    }

    try {
        Find-CrestronBootup -CidrFile $SubnetsFile -OutputCsv $ScanCsv | Out-Null
        if (Test-Path $ScanCsv) {
            Write-Host ""
            Write-Host "Results saved to: $ScanCsv" -ForegroundColor Green
        }
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause-Return
}

function Invoke-EditSubnets {
    Clear-Host
    Write-Host "=== Edit subnets list ===" -ForegroundColor Cyan

    if (Test-Path $SubnetsFile) {
        Write-Host ""
        Write-Host "Current subnets:" -ForegroundColor Cyan
        Get-Content $SubnetsFile | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host ""
        Write-Host "No subnets.txt yet." -ForegroundColor Yellow
    }

    Read-Subnets | Out-Null
    Pause-Return
}

function Invoke-Provision {
    Clear-Host
    Write-Host "=== Provision ===" -ForegroundColor Cyan
    if (-not (Test-Path $ScanCsv)) {
        Write-Host "No scan results found at:" -ForegroundColor Yellow
        Write-Host "  $ScanCsv"
        Write-Host "Run [1] Scan first." -ForegroundColor Yellow
        Pause-Return
        return
    }
    try {
        Set-CrestronAdmin -InputCsv $ScanCsv -ResultsCsv $ProvisionCsv | Out-Null
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause-Return
}

function Invoke-Verify {
    Clear-Host
    Write-Host "=== Verify ===" -ForegroundColor Cyan
    if (-not (Test-Path $ProvisionCsv)) {
        Write-Host "No provisioning results found at:" -ForegroundColor Yellow
        Write-Host "  $ProvisionCsv"
        Write-Host "Run [2] Provision first." -ForegroundColor Yellow
        Pause-Return
        return
    }
    try {
        Start-Sleep -Seconds 2
        Test-CrestronAdmin -InputCsv $ProvisionCsv -OutputCsv $VerifyCsv | Out-Null
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause-Return
}

function Invoke-FullWorkflow {
    Invoke-Scan
    if (-not (Test-Path $ScanCsv)) { return }
    $found = Import-Csv $ScanCsv
    if (-not $found) {
        Write-Host "Scan produced no targets. Nothing to provision." -ForegroundColor Yellow
        Pause-Return
        return
    }
    $proceed = Read-Host "Proceed to provisioning $($found.Count) device(s)? (Y/N)"
    if ($proceed -notmatch '^[Yy]') { return }
    Invoke-Provision
    if (-not (Test-Path $ProvisionCsv)) { return }
    $proceed = Read-Host "Proceed to verification? (Y/N)"
    if ($proceed -notmatch '^[Yy]') { return }
    Invoke-Verify
}

# ---- Main menu loop ----------------------------------------------------------
function Show-Menu {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Crestron 4-Series Admin Bootstrap" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Working directory: $WorkingDirectory"
    Write-Host ""
    Write-Host "  [1] Scan a subnet (prompts for CIDRs, or reuses subnets.txt)"
    Write-Host "  [2] Provision from last scan"
    Write-Host "  [3] Verify provisioning"
    Write-Host "  [4] Full workflow (scan -> provision -> verify)"
    Write-Host "  [E] Edit subnets list"
    Write-Host ""
    Write-Host "  [Q] Quit"
    Write-Host ""
}

Initialize-Module
Set-Location $WorkingDirectory

while ($true) {
    Show-Menu
    $choice = Read-Host "Select an option"
    switch ($choice.Trim().ToUpper()) {
        '1' { Invoke-Scan }
        '2' { Invoke-Provision }
        '3' { Invoke-Verify }
        '4' { Invoke-FullWorkflow }
        'E' { Invoke-EditSubnets }
        'Q' { Write-Host "Goodbye."; return }
        default {
            Write-Host "Unknown option: $choice" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}