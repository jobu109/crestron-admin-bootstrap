<#
.SYNOPSIS
    End-to-end workflow example for CrestronAdminBootstrap.

.DESCRIPTION
    Walks through scan -> review -> provision -> verify. This script is meant
    as a reference: copy what you need into your own session rather than
    running it blind. It will prompt before any destructive step.

.NOTES
    Run from a folder containing your subnets.txt (or edit the path below).
    Requires the CrestronAdminBootstrap module to be installed and PS 7+.
#>

[CmdletBinding()]
param(
    [string]$SubnetsFile  = '.\subnets.txt',
    [string]$ScanCsv      = '.\crestron-bootup.csv',
    [string]$ProvisionCsv = '.\crestron-provisioned.csv',
    [string]$VerifyCsv    = '.\crestron-verified.csv'
)

# --- Sanity checks ------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Requires PowerShell 7+. Launch pwsh and rerun."
}
if (-not (Get-Module -ListAvailable CrestronAdminBootstrap)) {
    throw "CrestronAdminBootstrap module not installed. Run the install one-liner first."
}
Import-Module CrestronAdminBootstrap

if (-not (Test-Path $SubnetsFile)) {
    throw "Subnets file not found: $SubnetsFile. Copy examples/subnets.example.txt and edit."
}

# --- 1. Scan ------------------------------------------------------------------
Write-Host "`n=== Step 1: Scan ===" -ForegroundColor Cyan
Find-CrestronBootup -CidrFile $SubnetsFile -OutputCsv $ScanCsv | Out-Null

if (-not (Test-Path $ScanCsv)) {
    Write-Host "No devices found on the bootup page. Nothing to do." -ForegroundColor Yellow
    return
}

# --- 2. Review ----------------------------------------------------------------
Write-Host "`n=== Step 2: Review ===" -ForegroundColor Cyan
$found = Import-Csv $ScanCsv
$found | Format-Table IP, MatchedSig, ScannedAt -AutoSize

$proceed = Read-Host "`nProvision these $($found.Count) device(s)? (Y/N)"
if ($proceed -notmatch '^[Yy]') {
    Write-Host "Stopped before provisioning. CSV is at $ScanCsv" -ForegroundColor Yellow
    return
}

# --- 3. Provision -------------------------------------------------------------
Write-Host "`n=== Step 3: Provision ===" -ForegroundColor Cyan
# Set-CrestronAdmin will prompt for credentials and require a final YES.
Set-CrestronAdmin -InputCsv $ScanCsv -ResultsCsv $ProvisionCsv | Out-Null

if (-not (Test-Path $ProvisionCsv)) {
    Write-Host "Provisioning aborted or produced no results." -ForegroundColor Yellow
    return
}

# --- 4. Verify ----------------------------------------------------------------
Write-Host "`n=== Step 4: Verify ===" -ForegroundColor Cyan
# Give devices a moment to settle after the POST
Start-Sleep -Seconds 5
Test-CrestronAdmin -InputCsv $ProvisionCsv -OutputCsv $VerifyCsv | Out-Null

Write-Host "`nWorkflow complete. Artifacts:" -ForegroundColor Green
Write-Host "  Scan results        : $ScanCsv"
Write-Host "  Provisioning results: $ProvisionCsv"
Write-Host "  Verification        : $VerifyCsv"