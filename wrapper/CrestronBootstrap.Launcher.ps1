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
function Invoke-Scan {
    Clear-Host
    Write-Host "=== Scan ===" -ForegroundColor Cyan
    if (-not (Test-Path $SubnetsFile)) {
        Write-Host "No subnets.txt found in:" -ForegroundColor Yellow
        Write-Host "  $WorkingDirectory"
        Write-Host ""
        Write-Host "Create a subnets.txt file with one CIDR per line, e.g.:" -ForegroundColor Yellow
        Write-Host "  10.10.20.0/24"
        Write-Host "  10.10.21.0/24"
        Pause-Return
        return
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
    Write-Host "  [1] Scan a subnet list (subnets.txt -> crestron-bootup.csv)"
    Write-Host "  [2] Provision from last scan"
    Write-Host "  [3] Verify provisioning"
    Write-Host "  [4] Full workflow (scan -> provision -> verify)"
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
        'Q' { Write-Host "Goodbye."; return }
        default {
            Write-Host "Unknown option: $choice" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}