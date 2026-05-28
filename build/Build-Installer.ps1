<#
.SYNOPSIS
    Publishes the .NET app and then compiles the Inno Setup installer.

.PARAMETER Version
    Version string (e.g. "0.13.7"). Reads from the .csproj if omitted.

.PARAMETER IsccPath
    Full path to ISCC.exe. Auto-detected from default Inno Setup install
    locations if omitted.

.EXAMPLE
    .\build\Build-Installer.ps1
    .\build\Build-Installer.ps1 -Version 0.14.0
#>
[CmdletBinding()]
param(
    [string]$Version  = '',
    [string]$IsccPath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# ── Locate Inno Setup compiler ────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    $candidates = @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe',
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        'C:\Program Files (x86)\Inno Setup 5\ISCC.exe'
    )
    $IsccPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $IsccPath -or -not (Test-Path $IsccPath)) {
    Write-Error @'
Inno Setup compiler (ISCC.exe) was not found.

Install Inno Setup 6 from https://jrsoftware.org/isinfo.php, then re-run.
'@
    exit 1
}

# ── Read version from .csproj if not supplied ─────────────────────────────────
if ([string]::IsNullOrWhiteSpace($Version)) {
    $csproj = Join-Path $repoRoot 'src\CrestronAdminBootstrap.Desktop\CrestronAdminBootstrap.Desktop.csproj'
    [xml]$xml = Get-Content $csproj -Raw
    $Version  = ($xml.Project.PropertyGroup | ForEach-Object { $_.Version } | Where-Object { $_ }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = '0.0.0' }
    Write-Host "Version read from .csproj: $Version"
}

# ── Publish the .NET app ──────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Publishing .NET app ===' -ForegroundColor Cyan
$publishScript = Join-Path $PSScriptRoot 'Publish-Desktop.ps1'
& $publishScript -Version $Version
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ── Verify publish output exists ──────────────────────────────────────────────
$publishDir = Join-Path $repoRoot 'dist\desktop-win-x64'
$exe = Join-Path $publishDir 'CrestronBootstrap.exe'
if (-not (Test-Path $exe)) {
    Write-Error "Publish output not found at $exe"
    exit 1
}

# ── Compile installer ─────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== Building installer ===' -ForegroundColor Cyan
$issFile = Join-Path $repoRoot 'installer\CrestronAdminBootstrap.iss'
& $IsccPath "/DAppVersion=$Version" $issFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "Inno Setup failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# ── Report results ────────────────────────────────────────────────────────────
$installer = Join-Path $repoRoot "dist\CrestronAdminBootstrap-Setup-v$Version-win-x64.exe"
$zipPath   = Join-Path $repoRoot "dist\CrestronAdminBootstrap-$Version-win-x64.zip"

Write-Host ''
Write-Host '=== Done ===' -ForegroundColor Green

$results = @()
if (Test-Path $installer) {
    $info = Get-Item $installer
    $results += [pscustomobject]@{ File = $info.Name; SizeMB = [math]::Round($info.Length / 1MB, 2) }
}
if (Test-Path $zipPath) {
    $info = Get-Item $zipPath
    $results += [pscustomobject]@{ File = $info.Name; SizeMB = [math]::Round($info.Length / 1MB, 2) }
}
$results | Format-Table -AutoSize
