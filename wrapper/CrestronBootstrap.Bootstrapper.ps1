<#
.SYNOPSIS
    Bootstrapper that becomes CrestronBootstrap.exe.

.DESCRIPTION
    PS2EXE can only target Windows PowerShell 5.1, but the
    CrestronAdminBootstrap module requires PowerShell 7. This bootstrapper
    is a thin PS 5.1 stub that:
      1. Confirms PowerShell 7 is installed (offers winget install if not)
      2. Confirms the CrestronAdminBootstrap module is installed
         (offers to run the install one-liner if not)
      3. Extracts an embedded launcher script to a temp file and spawns
         pwsh.exe to run it
    The launcher script content is injected at build time by Build-Exe.ps1
    via a placeholder.
#>

$ErrorActionPreference = 'Stop'

# {{LAUNCHER_BASE64}} — replaced at build time by Build-Exe.ps1
$LauncherBase64 = '__LAUNCHER_BASE64_PLACEHOLDER__'

function Write-Step ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok   ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Pause-Exit ($code = 0) {
    Write-Host ""
    Read-Host "Press Enter to close"
    exit $code
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

# ---- 2. Module installed? ----------------------------------------------------
Write-Step 'Checking CrestronAdminBootstrap module'

# Ask pwsh whether the module is available — has to be queried under PS 7,
# because that's the module path that matters.
$modCheck = & $pwshExe -NoProfile -Command "[bool](Get-Module -ListAvailable CrestronAdminBootstrap)" 2>$null
if ($modCheck -ne 'True') {
    Write-Warn 'Module is not installed for PowerShell 7.'
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
    Write-Ok 'Module is installed.'
}

# ---- 3. Extract launcher and run it under pwsh -------------------------------
Write-Step 'Launching menu'

$tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cabs-launcher-$([Guid]::NewGuid())") -Force
$launcherPath = Join-Path $tmp 'Launcher.ps1'
try {
    [IO.File]::WriteAllBytes($launcherPath, [Convert]::FromBase64String($LauncherBase64))

# Resolve the directory the user is running the .exe from. PS2EXE built
    # executables don't expose MyInvocation.MyCommand.Path, so prefer the
    # .NET process path; fall back to Get-Location.
    $exeDir = $null
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath) { $exeDir = Split-Path -Parent $exePath }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($exeDir)) {
        $exeDir = (Get-Location).Path
    }

    # Hand off to pwsh in the SAME console window. The PS2EXE host has a
    # console handle that can't be manipulated (Clear-Host fails), so we
    # exit our process and let pwsh take over the window cleanly.
    # Using cmd /c keeps the window attached for the user.
    $pwshArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $launcherPath,
        '-WorkingDirectory', $exeDir
    )
    $proc = Start-Process -FilePath $pwshExe -ArgumentList $pwshArgs -Wait -NoNewWindow -PassThru
    exit $proc.ExitCode
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}