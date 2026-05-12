function Set-CrestronSettings {
    <#
    .SYNOPSIS
        Applies blanket configuration sections to a Crestron 4-Series device.
        NTP/timezone, XiO Cloud toggle, and auto-update can be sent in a
        single combined POST.
    .DESCRIPTION
        Builds a partial CresNext payload from the supplied parameters and
        POSTs to /Device. The device merges the payload with current config;
        properties not supplied are not changed.

        Auto-update payload shape is selected automatically from
        $Session.DeviceFamily:
          - TouchPanel  -> Device.AutoUpdateMaster.IsEnabled (simple on/off)
          - other       -> Device.FeatureConfig.Avf.AvfAutoUpdate (schedule etc.)

        The CresNext API returns HTTP 200 even on partial failures. This
        cmdlet parses every per-result StatusId in the response and treats
        any StatusId outside {0 = OK, 1 = OK-reboot-required} as a failure
        for that section.

    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.

    .PARAMETER Ntp
        Hashtable: TimeZone (3-digit string), NtpServer (string),
        NtpEnabled (bool, default $true). Example:
          @{ TimeZone='010'; NtpServer='time.google.com' }

    .PARAMETER Cloud
        $true to enable XiO Cloud, $false to disable.

    .PARAMETER AutoUpdate
        Hashtable describing auto-update config:
          Enabled           (bool)             - both families
          ManifestUrl       (string)           - ControlSystem only
          DayOfWeek         (Daily/Monday/...) - ControlSystem only
          TimeOfDay         ('HH:mm')          - ControlSystem only
          PollIntervalMin   (int, minutes)     - ControlSystem only
        Touchscreens accept only Enabled.

    .PARAMETER TimeoutSec
        Per-request timeout in seconds. Default 30.

    .OUTPUTS
        PSCustomObject: IP, Status, Success, AppliedSections (string[]),
        SectionResults (per-section detail), Response (truncated body),
        Timestamp.

    .EXAMPLE
        $session = Connect-CrestronDevice -IP 172.22.0.21 -Credential $cred
        Set-CrestronSettings -Session $session `
            -Ntp @{ TimeZone='010'; NtpServer='time.google.com' } `
            -Cloud $false `
            -AutoUpdate @{ Enabled=$true }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [hashtable]$Ntp,
        [Nullable[bool]]$Cloud,
        [hashtable]$AutoUpdate,
        [int]$TimeoutSec = 30
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }
    if (-not $Ntp -and -not $PSBoundParameters.ContainsKey('Cloud') -and -not $AutoUpdate) {
        throw "Provide at least one of -Ntp, -Cloud, -AutoUpdate."
    }

    $deviceBody = @{}
    $sections   = @()

    # ---- NTP + TimeZone -----------------------------------------------------
    if ($Ntp) {
        $tz = $Ntp.TimeZone
        if ($tz -and $tz -notmatch '^\d{3}$') {
            throw "Ntp.TimeZone must be a 3-digit string (e.g. '010'). Got: '$tz'"
        }
        $ntpEnabled = if ($null -ne $Ntp.NtpEnabled) { [bool]$Ntp.NtpEnabled } else { $true }
        $clock = @{}
        if ($tz) { $clock.TimeZone = $tz }
        if ($Ntp.NtpServer) {
            $clock.Ntp = @{
                IsEnabled             = $ntpEnabled
                ServersCurrentKeyList = @('Server1')
                Servers = @{
                    Server1 = @{
                        Address    = [string]$Ntp.NtpServer
                        Port       = 123
                        AuthMethod = 'NONE'
                        AuthKey    = ''
                        AuthKeyId  = 0
                    }
                }
            }
        } elseif ($null -ne $Ntp.NtpEnabled) {
            $clock.Ntp = @{ IsEnabled = $ntpEnabled }
        }
        $deviceBody.SystemClock = $clock
        $sections += 'SystemClock'
    }

    # ---- XiO Cloud ----------------------------------------------------------
    if ($PSBoundParameters.ContainsKey('Cloud') -and $null -ne $Cloud) {
        $deviceBody.CloudSettings = @{
            XioCloud = @{ IsEnabled = [bool]$Cloud }
        }
        $sections += 'CloudSettings'
    }

    # ---- Auto-update (family-aware) -----------------------------------------
    if ($AutoUpdate) {
        $enabled = if ($null -ne $AutoUpdate.Enabled) { [bool]$AutoUpdate.Enabled } else { $true }
        $family  = $Session.DeviceFamily

        if ($family -eq 'TouchPanel') {
            $deviceBody.AutoUpdateMaster = @{ IsEnabled = $enabled }
            $sections += 'AutoUpdateMaster'

            $ignored = @('ManifestUrl','DayOfWeek','TimeOfDay','PollIntervalMin') |
                        Where-Object { $AutoUpdate.ContainsKey($_) }
            if ($ignored.Count -gt 0) {
                Write-Warning "DeviceFamily=TouchPanel ignores AutoUpdate fields: $($ignored -join ', '). Only Enabled is applied."
            }
        } else {
            # Default to ControlSystem shape when family is unknown or anything
            # other than TouchPanel. Older docs target FeatureConfig.Avf.AvfAutoUpdate.
            $avfAuto = @{ IsAutoUpdateEnabled = $enabled }
            if ($AutoUpdate.ManifestUrl) { $avfAuto.AutoUpdateManifestURL = [string]$AutoUpdate.ManifestUrl }
            if ($AutoUpdate.DayOfWeek -or $AutoUpdate.TimeOfDay -or $AutoUpdate.PollIntervalMin) {
                $schedule = @{}
                if ($AutoUpdate.DayOfWeek)       { $schedule.DayOfWeek    = [string]$AutoUpdate.DayOfWeek }
                if ($AutoUpdate.TimeOfDay)       { $schedule.TimeOfDay    = [string]$AutoUpdate.TimeOfDay }
                if ($AutoUpdate.PollIntervalMin) { $schedule.PollInterval = [int]$AutoUpdate.PollIntervalMin }
                $avfAuto.AutoUpdateSchedule = $schedule
            }
            if ($enabled -and -not $AutoUpdate.ManifestUrl) {
                Write-Warning "AutoUpdate.Enabled is true but no ManifestUrl provided. The device may reject the payload."
            }
            $deviceBody.FeatureConfig = @{
                Avf = @{
                    IsEnabled     = $true
                    AvfAutoUpdate = $avfAuto
                }
            }
            $sections += 'FeatureConfig.Avf.AvfAutoUpdate'
        }
    }

    $payload = @{ Device = $deviceBody }

    $apiResult = Invoke-CrestronApi -Session $Session -Path '/Device' -Method POST `
                                    -Body $payload -TimeoutSec $TimeoutSec

    # Parse per-section results from CresNext "Actions[].Results[].StatusId".
    # 0 = OK, 1 = OK (reboot required), anything else = failure.
    $sectionResults = @()
    $overallSuccess = $true

    if ($apiResult.BodyJson -and $apiResult.BodyJson.Actions) {
        foreach ($action in $apiResult.BodyJson.Actions) {
            foreach ($r in @($action.Results)) {
                $rPath = "$($r.Path)$(if ($r.Property) { '.' + $r.Property } else { '' })"
                $sid   = [int]$r.StatusId
                $rOk   = $sid -in 0,1
                if (-not $rOk) { $overallSuccess = $false }
                $sectionResults += [pscustomobject]@{
                    Path       = $rPath
                    StatusId   = $sid
                    StatusInfo = $r.StatusInfo
                    Ok         = $rOk
                }
            }
        }
    } else {
        # No parseable JSON — fall back to HTTP status alone
        $overallSuccess = $apiResult.Success
    }

    # If HTTP itself failed, overall failure regardless of body content
    if (-not $apiResult.Success) { $overallSuccess = $false }

    $bodyPreview = if ($apiResult.Body) {
        $clean = ($apiResult.Body -replace '\s+', ' ').Trim()
        $clean.Substring(0, [Math]::Min(300, $clean.Length))
    } else { '' }

    [pscustomobject]@{
        IP              = $Session.IP
        Status          = $apiResult.Status
        Success         = $overallSuccess
        AppliedSections = $sections
        SectionResults  = $sectionResults
        Response        = $bodyPreview
        Timestamp       = (Get-Date).ToString('s')
    }
}