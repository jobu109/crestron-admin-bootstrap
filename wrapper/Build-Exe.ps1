<#
.SYNOPSIS
    Builds CrestronBootstrap.exe from the launcher script using PS2EXE.

.DESCRIPTION
    Installs the ps2exe module if missing, then compiles
    wrapper\CrestronBootstrap.Launcher.ps1 into a single .exe at
    dist\CrestronBootstrap.exe.

    The resulting .exe still requires PowerShell 7 and curl.exe on the target
    machine. PS2EXE wraps the script as a console-host launcher; it does NOT
    bundle a PowerShell runtime.

.PARAMETER OutputDir
    Directory to write the .exe to. Default: dist\ at the repo root.

.PARAMETER Version
    Version string embedded in the .exe metadata. Default: pulled from the
    module manifest.

.PARAMETER NoIcon
    Skip embedding an icon. Default behavior is to embed wrapper\app.ico if
    present.
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$Version,
    [switch]$NoIcon
)

$ErrorActionPreference = 'Stop'

# Resolve paths relative to this script
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptRoot
$Launcher   = Join-Path $ScriptRoot 'CrestronBootstrap.Launcher.ps1'
$Manifest   = Join-Path $RepoRoot 'src\CrestronAdminBootstrap\CrestronAdminBootstrap.psd1'
$IconPath   = Join-Path $ScriptRoot 'app.ico'

if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'dist' }
$ExePath = Join-Path $OutputDir 'CrestronBootstrap.exe'

if (-not (Test-Path $Launcher))  { throw "Launcher not found: $Launcher" }
if (-not (Test-Path $Manifest))  { throw "Module manifest not found: $Manifest" }

# Pull version from manifest if not provided
if (-not $Version) {
    $manifestData = Import-PowerShellDataFile -Path $Manifest
    $Version = $manifestData.ModuleVersion
}

Write-Host "==> Build settings" -ForegroundColor Cyan
Write-Host "    Launcher : $Launcher"
Write-Host "    Output   : $ExePath"
Write-Host "    Version  : $Version"

# Ensure ps2exe is available
if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host "==> Installing ps2exe module" -ForegroundColor Cyan
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force

# Prep output dir
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Build args for Invoke-ps2exe
$ps2exeArgs = @{
    InputFile   = $Launcher
    OutputFile  = $ExePath
    Title       = 'Crestron Admin Bootstrap'
    Description = 'Bulk-provision Crestron 4-Series admin accounts'
    Company     = 'Michael Floyd'
    Product     = 'CrestronAdminBootstrap'
    Copyright   = '(c) 2026 Michael Floyd, MIT License'
    Version     = "$Version.0"
    NoConsole   = $false        # We want the console UI
    NoOutput    = $false
    NoError     = $false
    RequireAdmin = $false
}

if (-not $NoIcon -and (Test-Path $IconPath)) {
    $ps2exeArgs.IconFile = $IconPath
    Write-Host "    Icon     : $IconPath"
} elseif (-not $NoIcon) {
    Write-Host "    Icon     : (none; place wrapper\app.ico to embed one)"
}

Write-Host "==> Building" -ForegroundColor Cyan
Invoke-ps2exe @ps2exeArgs

if (Test-Path $ExePath) {
    $size = [math]::Round((Get-Item $ExePath).Length / 1KB, 1)
    Write-Host "==> Built $ExePath ($size KB)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Heads-up: PS2EXE binaries are commonly flagged by antivirus." -ForegroundColor Yellow
    Write-Host "If distributing, consider code-signing or documenting an AV exception."
} else {
    throw "Build did not produce an executable."
}