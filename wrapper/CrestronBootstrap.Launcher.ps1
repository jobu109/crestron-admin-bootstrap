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
$SettingsCsv  = Join-Path $WorkingDirectory 'crestron-settings.csv'

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

function Read-TimeZone {
    $zones = Get-CrestronTimeZones
    Write-Host ""
    Write-Host "Common time zones:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $zones.Count; $i++) {
        $row = "  [{0,2}] {1}  {2}" -f ($i + 1), $zones[$i].Code, $zones[$i].Name
        Write-Host $row
    }
    Write-Host "  [ R] Enter a raw 3-digit code instead"
    Write-Host ""

    while ($true) {
        $sel = Read-Host "Select time zone (number, or R for raw, default 5 = Central)"
        if ([string]::IsNullOrWhiteSpace($sel)) { return $zones[4].Code }   # 010 Central
        if ($sel -match '^[Rr]$') {
            $raw = Read-Host "  3-digit code"
            if ($raw -match '^\d{3}$') { return $raw }
            Write-Host "    Not a 3-digit code. Try again." -ForegroundColor Yellow
            continue
        }
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $zones.Count) {
            return $zones[[int]$sel - 1].Code
        }
        Write-Host "    Invalid selection. Try again." -ForegroundColor Yellow
    }
}

function Read-NtpConfig {
    Write-Host "--- NTP / Time Zone ---" -ForegroundColor Cyan
    $apply = Read-Host "Apply NTP + time zone? (Y/N)"
    if ($apply -notmatch '^[Yy]') { return $null }

    $defaultServer = 'time.google.com'
    $server = Read-Host "  NTP server [$defaultServer]"
    if ([string]::IsNullOrWhiteSpace($server)) { $server = $defaultServer }

    $tzCode = Read-TimeZone

    @{ TimeZone = $tzCode; NtpServer = $server; NtpEnabled = $true }
}

function Read-CloudConfig {
    Write-Host ""
    Write-Host "--- XiO Cloud ---" -ForegroundColor Cyan
    $apply = Read-Host "Apply XiO Cloud toggle? (Y/N)"
    if ($apply -notmatch '^[Yy]') { return $null }

    while ($true) {
        $ans = Read-Host "  Enable XiO Cloud? (Y/N)"
        if ($ans -match '^[Yy]') { return $true }
        if ($ans -match '^[Nn]') { return $false }
        Write-Host "    Please answer Y or N." -ForegroundColor Yellow
    }
}

function Read-AutoUpdateConfig {
    Write-Host ""
    Write-Host "--- Auto-Update ---" -ForegroundColor Cyan
    Write-Host "NOTE: this targets the 4-Series control-system shape." -ForegroundColor Yellow
    Write-Host "Touchscreens may use a different object path; verify against one" -ForegroundColor Yellow
    Write-Host "device before applying to many." -ForegroundColor Yellow
    $apply = Read-Host "Apply auto-update settings? (Y/N)"
    if ($apply -notmatch '^[Yy]') { return $null }

    while ($true) {
        $ans = Read-Host "  Enable auto-update? (Y/N)"
        if ($ans -match '^[Yy]') { $enabled = $true; break }
        if ($ans -match '^[Nn]') { $enabled = $false; break }
        Write-Host "    Please answer Y or N." -ForegroundColor Yellow
    }
    if (-not $enabled) { return @{ Enabled = $false } }

    $manifestUrl = Read-Host "  Manifest URL (required, e.g. https://updates.example.com/avf.mft)"
    if ([string]::IsNullOrWhiteSpace($manifestUrl)) {
        Write-Host "    Manifest URL required when enabling. Skipping auto-update." -ForegroundColor Yellow
        return $null
    }

    $day = Read-Host "  Day of week (Daily/Monday/.../Sunday) [Daily]"
    if ([string]::IsNullOrWhiteSpace($day)) { $day = 'Daily' }
    $time = Read-Host "  Time of day (HH:mm 24-hour) [03:00]"
    if ([string]::IsNullOrWhiteSpace($time)) { $time = '03:00' }
    $pollStr = Read-Host "  Poll interval in minutes [60]"
    $poll = if ($pollStr -match '^\d+$') { [int]$pollStr } else { 60 }

    @{
        Enabled         = $true
        ManifestUrl     = $manifestUrl
        DayOfWeek       = $day
        TimeOfDay       = $time
        PollIntervalMin = $poll
    }
}

function Invoke-Configure {
    Clear-Host
    Write-Host "=== Configure settings on provisioned devices ===" -ForegroundColor Cyan

    if (-not (Test-Path $ProvisionCsv)) {
        Write-Host "No provisioning results found at:" -ForegroundColor Yellow
        Write-Host "  $ProvisionCsv"
        Write-Host "Run [2] Provision first, or supply a CSV from a previous run." -ForegroundColor Yellow
        Pause-Return
        return
    }

    $targets = Import-Csv $ProvisionCsv | Where-Object { $_.IP -and $_.Success -eq 'True' }
    if (-not $targets) {
        Write-Host "No provisioned devices (Success=True) in $ProvisionCsv." -ForegroundColor Yellow
        Pause-Return
        return
    }

    Write-Host ""
    Write-Host "Will configure $($targets.Count) device(s):" -ForegroundColor Cyan
    $targets | ForEach-Object { Write-Host "  $($_.IP)" }

    # Credentials (same as those set by Set-CrestronAdmin)
    $cred = Get-Credential -Message "Admin credentials previously set on these devices"
    if (-not $cred -or -not $cred.UserName) {
        Write-Host "No credentials provided. Cancelled." -ForegroundColor Yellow
        Pause-Return
        return
    }

    # Collect settings
    $ntp        = Read-NtpConfig
    $cloud      = Read-CloudConfig
    $autoUpdate = Read-AutoUpdateConfig

    if (-not $ntp -and ($null -eq $cloud) -and -not $autoUpdate) {
        Write-Host "No settings selected. Cancelled." -ForegroundColor Yellow
        Pause-Return
        return
    }

    # Summary
    Write-Host ""
    Write-Host "=== Summary ===" -ForegroundColor Yellow
    if ($ntp)        { Write-Host "  NTP/TimeZone : server=$($ntp.NtpServer), tz=$($ntp.TimeZone)" -ForegroundColor Yellow }
    if ($null -ne $cloud) { Write-Host "  XiO Cloud    : $(if ($cloud) {'ENABLE'} else {'DISABLE'})" -ForegroundColor Yellow }
    if ($autoUpdate) {
        if ($autoUpdate.Enabled) {
            Write-Host "  Auto-Update  : ENABLE, $($autoUpdate.ManifestUrl), $($autoUpdate.DayOfWeek) $($autoUpdate.TimeOfDay), poll=$($autoUpdate.PollIntervalMin)m" -ForegroundColor Yellow
        } else {
            Write-Host "  Auto-Update  : DISABLE" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    $confirm = Read-Host "Type YES (uppercase) to apply to all $($targets.Count) device(s)"
    if ($confirm -cne 'YES') {
        Write-Host "Cancelled." -ForegroundColor Red
        Pause-Return
        return
    }

    # Apply (in parallel, each worker connects fresh — sessions can't cross runspaces)
    $ips    = $targets | Select-Object -ExpandProperty IP
    $user   = $cred.UserName
    $pass   = $cred.GetNetworkCredential().Password
    $ntpArg = $ntp
    $cloArg = $cloud
    $auArg  = $autoUpdate

    Write-Host ""
    Write-Host "Applying..." -ForegroundColor Cyan

    $connectText = (Get-Command Connect-CrestronDevice).Definition
    $applyText   = (Get-Command Set-CrestronSettings).Definition
    $invokeText  = (Get-Command Invoke-CrestronApi).Definition

    $results = $ips | ForEach-Object -ThrottleLimit 16 -Parallel {
        ${function:Connect-CrestronDevice} = $using:connectText
        ${function:Set-CrestronSettings}   = $using:applyText
        ${function:Invoke-CrestronApi}     = $using:invokeText

        $ip = $_
        try {
            $sec  = ConvertTo-SecureString $using:pass -AsPlainText -Force
            $cred = [pscredential]::new($using:user, $sec)
            $sess = Connect-CrestronDevice -IP $ip -Credential $cred

            $callArgs = @{ Session = $sess }
            if ($using:ntpArg)            { $callArgs.Ntp        = $using:ntpArg }
            if ($null -ne $using:cloArg)  { $callArgs.Cloud      = $using:cloArg }
            if ($using:auArg)             { $callArgs.AutoUpdate = $using:auArg }

            $r = Set-CrestronSettings @callArgs
            if (Test-Path $sess.CookieJarPath) { Remove-Item $sess.CookieJarPath -Force -ErrorAction SilentlyContinue }
            $r
        } catch {
            [pscustomobject]@{
                IP              = $ip
                Status          = 0
                Success         = $false
                AppliedSections = @()
                Response        = "ERROR: $($_.Exception.Message)"
                Timestamp       = (Get-Date).ToString('s')
            }
        }
    } | Sort-Object { [version]$_.IP }

    $okCount  = ($results | Where-Object Success).Count
    $badCount = $results.Count - $okCount

    Write-Host ""
    Write-Host "Done. $okCount succeeded, $badCount failed." -ForegroundColor Green
    $results | Export-Csv -NoTypeInformation -Path $SettingsCsv
    Write-Host "Results saved to: $SettingsCsv" -ForegroundColor Green
    if ($badCount -gt 0) {
        $results | Where-Object { -not $_.Success } | Format-Table IP, Status, Response -AutoSize -Wrap
    }
    Pause-Return
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
    Write-Host "  [5] Configure settings on provisioned devices (NTP, Cloud, Auto-Update)"
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
        '5' { Invoke-Configure }
        'E' { Invoke-EditSubnets }
        'Q' { Write-Host "Goodbye."; return }
        default {
            Write-Host "Unknown option: $choice" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}