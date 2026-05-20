<#
.SYNOPSIS
    Bootstrapper that becomes CrestronBootstrap.exe.

.DESCRIPTION
    PS2EXE can only target Windows PowerShell 5.1, but the
    CrestronAdminBootstrap module requires PowerShell 7. This bootstrapper
    is a thin PS 5.1 stub that:
      1. Confirms PowerShell 7 is installed (offers winget install if not)
      2. Extracts the bundled CrestronAdminBootstrap module when present
         (falls back to an installed module only for older builds)
      3. Picks UI mode:
         - default: WPF GUI (Gui.ps1)
         - '--text' command-line arg: text menu (Launcher.ps1)
      4. Extracts the selected script (embedded as base64) to a temp file and
         spawns pwsh.exe to run it.
    Both script contents are injected at build time by Build-Exe.ps1.
#>

$ErrorActionPreference = 'Stop'

# {{LAUNCHER_BASE64}}, {{GUI_BASE64}}, and {{MODULE_ZIP_BASE64}} are replaced at build time.
$LauncherBase64  = '__LAUNCHER_BASE64_PLACEHOLDER__'
$GuiBase64       = '__GUI_BASE64_PLACEHOLDER__'
$ModuleZipBase64 = '__MODULE_ZIP_BASE64_PLACEHOLDER__'

function Write-Step ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok   ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Pause-Exit ($code = 0) {
    Write-Host ""
    Read-Host "Press Enter to close"
    exit $code
}

function Test-EmbeddedPayload ($b64) {
    return -not ([string]::IsNullOrWhiteSpace($b64) -or $b64.Length -lt 16 -or $b64 -like '__*_PLACEHOLDER__')
}

# ---- UI mode selection -------------------------------------------------------
$mode = 'gui'
if ($args -contains '--text' -or $args -contains '-text' -or $args -contains '/text') {
    $mode = 'text'
}

# ---- 1. Locate pwsh (PS 7) ---------------------------------------------------
Write-Step 'Checking for PowerShell 7'

$pwshExe = $null
$candidates = @(
    "$env:ProgramFiles\PowerShell\7\pwsh.exe",
    "$env:LOCALAPPDATA\Microsoft\PowerShell\7\pwsh.exe",
    "$env:LOCALAPPDATA\Programs\PowerShell\7\pwsh.exe"
)
foreach ($c in $candidates) {
    if (Test-Path $c) { $pwshExe = $c; break }
}
if (-not $pwshExe) {
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { $pwshExe = $cmd.Source }
}

if (-not $pwshExe) {
    Write-Warn 'PowerShell 7 is not installed.'
    Write-Host ''
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $ans = Read-Host 'Install PowerShell 7 now via winget? (Y/N)'
        if ($ans -match '^[Yy]') {
            try {
                Start-Process winget -ArgumentList @(
                    'install','--id','Microsoft.PowerShell',
                    '--source','winget',
                    '--accept-package-agreements','--accept-source-agreements'
                ) -Wait -NoNewWindow
            } catch {
                Write-Warn "winget install failed: $($_.Exception.Message)"
                Pause-Exit 1
            }
            foreach ($c in $candidates) {
                if (Test-Path $c) { $pwshExe = $c; break }
            }
            if (-not $pwshExe) {
                Write-Warn 'PowerShell 7 still not found after install. Open a new shell and rerun this app.'
                Pause-Exit 1
            }
        } else {
            Write-Host 'Install PowerShell 7 manually from https://aka.ms/powershell then rerun.'
            Pause-Exit 1
        }
    } else {
        Write-Host 'winget is not available. Install PowerShell 7 manually from https://aka.ms/powershell then rerun.'
        Pause-Exit 1
    }
}
Write-Ok "Found: $pwshExe"

# ---- 2. Module available? ----------------------------------------------------
Write-Step 'Checking CrestronAdminBootstrap module'

$hasBundledModule = Test-EmbeddedPayload $ModuleZipBase64
if ($hasBundledModule) {
    Write-Ok 'Bundled module payload found.'
} else {
    $modCheck = & $pwshExe -NoProfile -Command "[bool](Get-Module -ListAvailable CrestronAdminBootstrap)" 2>$null
    if ($modCheck -ne 'True') {
        Write-Warn 'Module is not installed for PowerShell 7, and this executable has no bundled module.'
        $ans = Read-Host 'Install it now from GitHub? (Y/N)'
        if ($ans -match '^[Yy]') {
            $installCmd = 'iex (irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1)'
            & $pwshExe -NoProfile -Command $installCmd
            $modCheck = & $pwshExe -NoProfile -Command "[bool](Get-Module -ListAvailable CrestronAdminBootstrap)" 2>$null
            if ($modCheck -ne 'True') {
                Write-Warn 'Install appears to have failed.'
                Pause-Exit 1
            }
            Write-Ok 'Module installed.'
        } else {
            Pause-Exit 1
        }
    } else {
        Write-Ok 'Installed module fallback found.'
    }
}

# ---- 3. Extract selected script and hand off to pwsh -------------------------
$selectedB64  = if ($mode -eq 'gui') { $GuiBase64 } else { $LauncherBase64 }
$selectedName = if ($mode -eq 'gui') { 'Gui.ps1' }  else { 'Launcher.ps1' }
Write-Step "Launching $($mode.ToUpper()) ($selectedName)"

if (-not (Test-EmbeddedPayload $selectedB64)) {
    Write-Warn "No embedded $selectedName payload found. This .exe was built without the $mode script."
    if ($mode -eq 'gui' -and (Test-EmbeddedPayload $LauncherBase64)) {
        Write-Warn 'Falling back to text menu.'
        $selectedB64  = $LauncherBase64
        $selectedName = 'Launcher.ps1'
        $mode = 'text'
    } else {
        Pause-Exit 1
    }
}

# Resolve directory the user invoked the .exe from
$exeDir = $null
try {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exePath) { $exeDir = Split-Path -Parent $exePath }
} catch { }
if ([string]::IsNullOrWhiteSpace($exeDir)) {
    $exeDir = (Get-Location).Path
}

$tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cabs-launcher-$([Guid]::NewGuid())") -Force
$scriptPath = Join-Path $tmp $selectedName
$moduleManifestPath = $null

try {
    if ($hasBundledModule) {
        Write-Step 'Extracting bundled module'
        $moduleZipPath = Join-Path $tmp 'CrestronAdminBootstrap.zip'
        $moduleRoot = Join-Path $tmp 'module'
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
        [IO.File]::WriteAllBytes($moduleZipPath, [Convert]::FromBase64String($ModuleZipBase64))

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($moduleZipPath, $moduleRoot)

        $manifest = Get-ChildItem -Path $moduleRoot -Recurse -Filter 'CrestronAdminBootstrap.psd1' |
            Select-Object -First 1
        if (-not $manifest) {
            throw 'Bundled module did not contain CrestronAdminBootstrap.psd1.'
        }

        $moduleManifestPath = $manifest.FullName
        Write-Ok "Bundled module: $moduleManifestPath"
    }

    [IO.File]::WriteAllBytes($scriptPath, [Convert]::FromBase64String($selectedB64))

    $pwshArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-WorkingDirectory', $exeDir
    )

    if ($moduleManifestPath) {
        $pwshArgs += @('-ModuleManifestPath', $moduleManifestPath)
    }

    # GUI mode: hide pwsh's console (only the WPF window is visible).
    # Text mode: launch pwsh with a normal window so the user can see the menu.
    if ($mode -eq 'gui') {
        $proc = Start-Process -FilePath $pwshExe -ArgumentList $pwshArgs `
                              -Wait -WindowStyle Hidden -PassThru
    } else {
        $proc = Start-Process -FilePath $pwshExe -ArgumentList $pwshArgs `
                              -Wait -PassThru
    }
    exit $proc.ExitCode
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
