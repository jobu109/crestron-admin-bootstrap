<#
.SYNOPSIS
    Builds and signs CrestronBootstrap.exe.

.DESCRIPTION
    PS2EXE only targets Windows PowerShell 5.1, but the module needs PS 7.
    To bridge that, this build process:
      1. Reads wrapper\CrestronBootstrap.Launcher.ps1 (the PS 7 menu UI).
      2. Base64-encodes it and injects it into a copy of
         wrapper\CrestronBootstrap.Bootstrapper.ps1 (the PS 5.1 stub) as a
         placeholder replacement.
      3. Compiles the merged bootstrapper into dist\CrestronBootstrap.exe via
         ps2exe.
      4. Signs the .exe with the configured code-signing cert.

    Temporarily adds dist\ to Microsoft Defender exclusions during build,
    because PS2EXE output is heuristically flagged. The exclusion is removed
    when the build completes (or fails). Requires elevation.

.PARAMETER OutputDir
    Directory to write the .exe to. Default: dist\ at the repo root.

.PARAMETER Version
    Version string embedded in the .exe metadata. Default: from module manifest.

.PARAMETER CertSubject
    Subject of the code-signing cert. Default: 'CN=jobu109 Code Signing'.

.PARAMETER SkipSigning
    Build but skip signing. Defender will likely quarantine it.

.PARAMETER NoIcon
    Skip embedding wrapper\app.ico.
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$Version,
    [string]$CertSubject = 'CN=jobu109 Code Signing',
    [switch]$SkipSigning,
    [switch]$NoIcon
)

$ErrorActionPreference = 'Stop'

# Resolve paths
$ScriptRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot         = Split-Path -Parent $ScriptRoot
$LauncherPath     = Join-Path $ScriptRoot 'CrestronBootstrap.Launcher.ps1'
$BootstrapperPath = Join-Path $ScriptRoot 'CrestronBootstrap.Bootstrapper.ps1'
$Manifest         = Join-Path $RepoRoot 'src\CrestronAdminBootstrap\CrestronAdminBootstrap.psd1'
$IconPath         = Join-Path $ScriptRoot 'app.ico'

if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'dist' }
$ExePath = Join-Path $OutputDir 'CrestronBootstrap.exe'

foreach ($p in @($LauncherPath, $BootstrapperPath, $Manifest)) {
    if (-not (Test-Path $p)) { throw "Required file not found: $p" }
}

if (-not $Version) {
    $manifestData = Import-PowerShellDataFile -Path $Manifest
    $Version = $manifestData.ModuleVersion
}

# Resolve signing cert before doing anything destructive
$cert = $null
if (-not $SkipSigning) {
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object { $_.Subject -eq $CertSubject } |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1
    if (-not $cert) {
        throw "No code-signing certificate found with subject '$CertSubject'. Generate one or pass -SkipSigning."
    }
}

Write-Host '==> Build settings' -ForegroundColor Cyan
Write-Host "    Launcher     : $LauncherPath"
Write-Host "    Bootstrapper : $BootstrapperPath"
Write-Host "    Output       : $ExePath"
Write-Host "    Version      : $Version"
if ($cert) {
    Write-Host "    Cert         : $($cert.Subject) (thumbprint $($cert.Thumbprint))"
} else {
    Write-Host '    Cert         : (signing skipped)'
}

# Embed the launcher into a copy of the bootstrapper
Write-Host '==> Embedding launcher' -ForegroundColor Cyan
$launcherBytes  = [IO.File]::ReadAllBytes($LauncherPath)
$launcherB64    = [Convert]::ToBase64String($launcherBytes)
$bootstrapText  = Get-Content -Path $BootstrapperPath -Raw
if ($bootstrapText -notmatch '__LAUNCHER_BASE64_PLACEHOLDER__') {
    throw "Bootstrapper is missing __LAUNCHER_BASE64_PLACEHOLDER__ marker."
}
$mergedText     = $bootstrapText.Replace('__LAUNCHER_BASE64_PLACEHOLDER__', $launcherB64)

$tempBuildDir = Join-Path $env:TEMP "cabs-build-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempBuildDir -Force | Out-Null
$mergedScript = Join-Path $tempBuildDir 'CrestronBootstrap.Merged.ps1'
Set-Content -Path $mergedScript -Value $mergedText -Encoding UTF8 -NoNewline
Write-Host "    Merged script: $mergedScript ($([math]::Round((Get-Item $mergedScript).Length/1KB,1)) KB)"

# Defender exclusion (requires admin)
$exclusionAdded = $false
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
    if ($isAdmin) {
        try {
            Add-MpPreference -ExclusionPath $OutputDir -ErrorAction Stop
            $exclusionAdded = $true
            Write-Host "==> Added Defender exclusion for $OutputDir" -ForegroundColor Cyan
        } catch {
            Write-Warning "Could not add Defender exclusion: $($_.Exception.Message)."
        }
    } else {
        Write-Warning 'Not running as admin; skipping Defender exclusion. If the .exe disappears after build, rerun from an elevated PS 7.'
    }
}

try {
    # Ensure ps2exe is available
    if (-not (Get-Module -ListAvailable ps2exe)) {
        Write-Host '==> Installing ps2exe module' -ForegroundColor Cyan
        Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ps2exe -Force

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $ps2exeArgs = @{
        InputFile    = $mergedScript
        OutputFile   = $ExePath
        Title        = 'Crestron Admin Bootstrap'
        Description  = 'Bulk-provision Crestron 4-Series admin accounts'
        Company      = 'Michael Floyd'
        Product      = 'CrestronAdminBootstrap'
        Copyright    = '(c) 2026 Michael Floyd, MIT License'
        Version      = "$Version.0"
        NoConsole    = $false
        NoOutput     = $false
        NoError      = $false
        RequireAdmin = $false
    }
    if (-not $NoIcon -and (Test-Path $IconPath)) {
        $ps2exeArgs.IconFile = $IconPath
        Write-Host "    Icon         : $IconPath"
    }

    Write-Host '==> Building' -ForegroundColor Cyan
    Invoke-ps2exe @ps2exeArgs

    if (-not (Test-Path $ExePath)) {
        throw 'Build did not produce an executable (possibly quarantined by Defender).'
    }
    $size = [math]::Round((Get-Item $ExePath).Length / 1KB, 1)
    Write-Host "==> Built $ExePath ($size KB)" -ForegroundColor Green

    # Sign
    if ($cert) {
        Write-Host '==> Signing' -ForegroundColor Cyan
        $sigResult = Set-AuthenticodeSignature `
            -FilePath $ExePath `
            -Certificate $cert `
            -TimestampServer 'http://timestamp.digicert.com' `
            -HashAlgorithm SHA256
        if ($sigResult.Status -ne 'Valid') {
            throw "Signing failed. Status: $($sigResult.Status). $($sigResult.StatusMessage)"
        }
        Write-Host "    Signature    : $($sigResult.Status)" -ForegroundColor Green

        $verify = Get-AuthenticodeSignature -FilePath $ExePath
        Write-Host "    Verify       : $($verify.Status) ($($verify.SignerCertificate.Subject))"
    }

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
    if ($cert) {
        Write-Host 'Distribute the .exe alongside signing\jobu109-codesigning.cer.'
        Write-Host 'End users: install the .cer into Cert:\CurrentUser\TrustedPublisher (and Root for full trust).'
    }
} finally {
    Remove-Item $tempBuildDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($exclusionAdded) {
        try {
            Remove-MpPreference -ExclusionPath $OutputDir -ErrorAction Stop
            Write-Host "==> Removed Defender exclusion for $OutputDir" -ForegroundColor Cyan
        } catch {
            Write-Warning "Could not remove Defender exclusion: $($_.Exception.Message). Remove manually via Windows Security."
        }
    }
}