<#
.SYNOPSIS
    Bootstrap installer for CrestronAdminBootstrap.

.DESCRIPTION
    Intended to be invoked via:
        iex (irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1)

    Performs the following steps:
      1. Confirms PowerShell 7+ (offers to install via winget if missing).
      2. Downloads the module from the chosen release tag or branch.
      3. Installs into the user's PowerShell modules folder.
      4. Imports and lists the exported commands.

.PARAMETER Version
    Release tag to install (e.g. 'v0.1.0'). Defaults to the latest published release.

.PARAMETER Branch
    Branch name to install from instead of a release tag (e.g. 'main').
    Useful for trying unreleased changes. Overrides -Version.

.PARAMETER Scope
    Install scope: 'CurrentUser' (default, no admin) or 'AllUsers' (requires admin).

.PARAMETER Force
    Skip prompts. Overwrites any existing install of the same version.

.EXAMPLE
    # Standard install (latest release)
    iex (irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1)

.EXAMPLE
    # Pin to a specific version
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1))) -Version v0.1.0

.EXAMPLE
    # Track the main branch
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1))) -Branch main
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Branch,
    [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Repo       = 'jobu109/crestron-admin-bootstrap'
$ModuleName = 'CrestronAdminBootstrap'

function Write-Step ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok   ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# ---- 1. PowerShell 7 check ---------------------------------------------------
Write-Step "Checking PowerShell version"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warn "This module requires PowerShell 7+. Detected: $($PSVersionTable.PSVersion)"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $answer = if ($Force) { 'Y' } else { Read-Host "Install PowerShell 7 now via winget? (Y/N)" }
        if ($answer -match '^[Yy]') {
            winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
            Write-Warn "PowerShell 7 installed. Open a 'PowerShell 7' window and rerun this installer."
            return
        } else {
            throw "Cannot continue without PowerShell 7."
        }
    } else {
        throw "PowerShell 7 not installed and winget is not available. Install PS7 manually: https://aka.ms/powershell"
    }
}
Write-Ok "PS $($PSVersionTable.PSVersion) detected."

# ---- 2. Resolve source (release tag vs branch) -------------------------------
Write-Step "Resolving source"
$ref = $null
if ($Branch) {
    $ref = $Branch
    Write-Ok "Using branch '$Branch'."
} else {
    if (-not $Version) {
        try {
            $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
                                        -Headers @{ 'User-Agent' = 'CrestronAdminBootstrap-Installer' }
            $Version = $latest.tag_name
            Write-Ok "Latest release: $Version"
        } catch {
            Write-Warn "Could not query latest release ($($_.Exception.Message)). Falling back to branch 'main'."
            $ref = 'main'
        }
    }
    if (-not $ref) { $ref = $Version }
}

# ---- 3. Download zipball -----------------------------------------------------
Write-Step "Downloading $Repo @ $ref"
$tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "cabs-$([Guid]::NewGuid())") -Force
$zip = Join-Path $tmp 'source.zip'
$zipUrl = "https://codeload.github.com/$Repo/zip/refs/heads/$ref"
if ($Version -and -not $Branch) {
    # Tag-based zip URL
    $zipUrl = "https://codeload.github.com/$Repo/zip/refs/tags/$ref"
}

try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
    Write-Ok "Downloaded $([math]::Round((Get-Item $zip).Length/1KB,1)) KB."
} catch {
    throw "Download failed from $zipUrl : $($_.Exception.Message)"
}

# ---- 4. Extract --------------------------------------------------------------
Write-Step "Extracting"
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$extractedRoot = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
$moduleSrc = Join-Path $extractedRoot.FullName "src\$ModuleName"
if (-not (Test-Path (Join-Path $moduleSrc "$ModuleName.psd1"))) {
    throw "Module manifest not found at expected location: $moduleSrc"
}

# Determine version to install (from manifest, not the tag — they may differ)
$manifest = Import-PowerShellDataFile -Path (Join-Path $moduleSrc "$ModuleName.psd1")
$moduleVersion = $manifest.ModuleVersion
Write-Ok "Module version $moduleVersion."

# ---- 5. Choose install path --------------------------------------------------
Write-Step "Installing to $Scope scope"
$destBase = if ($Scope -eq 'AllUsers') {
    Join-Path $env:ProgramFiles 'PowerShell\Modules'
} else {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
}
$dest = Join-Path $destBase "$ModuleName\$moduleVersion"

if (Test-Path $dest) {
    if (-not $Force) {
        $answer = Read-Host "Existing install found at $dest. Overwrite? (Y/N)"
        if ($answer -notmatch '^[Yy]') {
            Write-Warn "Aborted. Existing install untouched."
            return
        }
    }
    Remove-Item -Recurse -Force $dest
}

New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -Path (Join-Path $moduleSrc '*') -Destination $dest -Recurse -Force
Write-Ok "Installed to $dest"

# ---- 6. Verify ---------------------------------------------------------------
Write-Step "Verifying import"
Import-Module $ModuleName -Force
$exported = Get-Command -Module $ModuleName
Write-Ok "Loaded $($exported.Count) function(s):"
$exported | ForEach-Object { Write-Host "      $($_.Name)" }

# ---- 7. Cleanup --------------------------------------------------------------
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Try it:" -ForegroundColor Green
Write-Host "  Find-CrestronBootup -CidrFile .\subnets.txt"