using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using CrestronAdminBootstrap.Desktop.Models;

namespace CrestronAdminBootstrap.Desktop.Services;

public sealed class PowerShellBackend
{
    private const string JsonStart = "__CABS_JSON_BEGIN__";
    private const string JsonEnd = "__CABS_JSON_END__";

    private readonly string _repoRoot;
    private readonly string _moduleManifest;
    private readonly string _settingsPath;
    private readonly string _dataRoot;
    private readonly string _pwshPath;

    public PowerShellBackend()
    {
        _repoRoot = RepoLocator.FindRepoRoot();
        _moduleManifest = Path.Combine(_repoRoot, "src", "CrestronAdminBootstrap", "CrestronAdminBootstrap.psd1");
        _settingsPath = RepoLocator.FindSettingsPath(_repoRoot);
        _dataRoot = Path.GetDirectoryName(_settingsPath) ?? _repoRoot;
        _pwshPath = FindPowerShell();
    }

    public string RepoRoot => _repoRoot;

    public string SettingsPath => _settingsPath;

    public string DataRoot => _dataRoot;

    public async Task<IReadOnlyList<ScanDeviceRow>> ScanReachableDevicesAsync(
        IEnumerable<string> cidrs,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var cleanCidrs = cidrs
            .Select(c => c.Trim())
            .Where(c => !string.IsNullOrWhiteSpace(c))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (cleanCidrs.Length == 0)
        {
            return Array.Empty<ScanDeviceRow>();
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var cidrFile = Path.Combine(tempDir, "reachable-subnets.txt");
        var outputCsv = Path.Combine(_dataRoot, "crestron-reachable.csv");
        await File.WriteAllLinesAsync(cidrFile, cleanCidrs, cancellationToken).ConfigureAwait(false);
        await File.WriteAllLinesAsync(Path.Combine(_dataRoot, "subnets.txt"), cleanCidrs, cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'

            function Expand-CabsCidr {
                param([Parameter(Mandatory)][string]$Cidr)

                $base, $bits = $Cidr -split '/'
                $bits = [int]$bits
                $bytes = ([IPAddress]$base).GetAddressBytes()
                [Array]::Reverse($bytes)
                $start = [BitConverter]::ToUInt32($bytes, 0)
                $mask = if ($bits -eq 0) { [uint32]0 } else { ([uint32]::MaxValue -shl (32 - $bits)) -band [uint32]::MaxValue }
                $network = $start -band $mask
                $count = [uint64][math]::Pow(2, 32 - $bits)
                $lo = if ($count -le 2) { [uint64]0 } else { [uint64]1 }
                $hi = if ($count -le 2) { $count - 1 } else { $count - 2 }

                for ([uint64]$i = $lo; $i -le $hi; $i++) {
                    $b = [BitConverter]::GetBytes([uint32]($network + $i))
                    [Array]::Reverse($b)
                    ([IPAddress]$b).ToString()
                }
            }

            $cidrs = @(Get-Content '{{EscapePowerShellString(cidrFile)}}' | Where-Object { $_ -and $_.Trim() })
            $targets = @($cidrs | ForEach-Object { Expand-CabsCidr $_ } | Sort-Object -Unique)
            Write-Output "Scanning $($targets.Count) candidate IP(s) for reachable Crestron/AirMedia devices..."

            $rows = @($targets | ForEach-Object -ThrottleLimit 64 -Parallel {
                $ip = $_
                $signals = @()
                $scannedAt = (Get-Date).ToString('s')
                $probeTargets = @(
                    "https://$ip/",
                    "http://$ip/",
                    "https://$ip/userlogin.html",
                    "https://$ip/Device/DeviceInfo"
                )

                foreach ($url in $probeTargets) {
                    $jar = Join-Path ([IO.Path]::GetTempPath()) "cabs-probe-$([Guid]::NewGuid()).txt"
                    $headers = Join-Path ([IO.Path]::GetTempPath()) "cabs-probe-$([Guid]::NewGuid()).headers"

                    try {
                        $body = & curl.exe -k -s -L -D $headers -c $jar --connect-timeout 1 --max-time 3 $url 2>$null
                        $headerText = if (Test-Path -LiteralPath $headers) {
                            Get-Content -LiteralPath $headers -Raw -ErrorAction SilentlyContinue
                        }
                        else {
                            ''
                        }
                        $bodyText = if ($body) { ($body -join "`n") } else { '' }
                        $probeText = "$headerText`n$bodyText"

                        if ((Test-Path -LiteralPath $jar) -and (Select-String -Path $jar -Pattern 'TRACKID' -Quiet)) {
                            $signals += 'TRACKID'
                        }

                        if ($probeText -match '(?i)\bAirMedia\b|AM[-_ ]?3?200|AM[-_ ]?\d{3,4}') {
                            $signals += 'AirMedia'
                        }

                        if ($probeText -match '(?i)\bCrestron\b|CresNext|CREST-XSRF-TOKEN|userlogin\.html|createUser\.html') {
                            $signals += 'Crestron'
                        }

                        if ($probeText -match '(?i)"DeviceInfo"|DeviceInfo|Device\.DeviceInfo') {
                            $signals += 'DeviceInfo'
                        }

                        if ($signals.Count -gt 0) {
                            break
                        }
                    }
                    catch { }
                    finally {
                        Remove-Item $jar -Force -ErrorAction SilentlyContinue
                        Remove-Item $headers -Force -ErrorAction SilentlyContinue
                    }
                }

                [pscustomobject]@{
                    IP = $ip
                    Reachable = ($signals.Count -gt 0)
                    MatchedSig = (@($signals | Sort-Object -Unique) -join ', ')
                    ScannedAt = $scannedAt
                }
            })

            $reachable = @($rows | Where-Object Reachable | Sort-Object IP)
            $reachable | Select-Object IP,MatchedSig,ScannedAt | Export-Csv -NoTypeInformation -Path '{{EscapePowerShellString(outputCsv)}}'

            $payload = [pscustomobject]@{
                Success = $true
                Count = $reachable.Count
                Rows = @($reachable | Select-Object IP,MatchedSig,ScannedAt)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 8
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            progress?.Report($"Scanning {cleanCidrs.Length} subnet(s) for reachable devices...");
            var json = await RunJsonScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<ScanResultDto>(json, JsonOptions);
            return result?.Rows?
                .Where(r => !string.IsNullOrWhiteSpace(r.IP))
                .Select(r => new ScanDeviceRow
                {
                    Selected = true,
                    IP = r.IP ?? "",
                    MatchedSig = r.MatchedSig ?? "",
                    ScannedAt = r.ScannedAt ?? ""
                })
                .ToArray() ?? Array.Empty<ScanDeviceRow>();
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<IReadOnlyList<ScanDeviceRow>> ScanBootupAsync(
        IEnumerable<string> cidrs,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var cleanCidrs = cidrs
            .Select(c => c.Trim())
            .Where(c => !string.IsNullOrWhiteSpace(c))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (cleanCidrs.Length == 0)
        {
            return Array.Empty<ScanDeviceRow>();
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var cidrFile = Path.Combine(tempDir, "subnets.txt");
        var outputCsv = Path.Combine(_dataRoot, "crestron-bootup.csv");
        await File.WriteAllLinesAsync(cidrFile, cleanCidrs, cancellationToken).ConfigureAwait(false);
        await File.WriteAllLinesAsync(Path.Combine(_dataRoot, "subnets.txt"), cleanCidrs, cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            Import-Module '{{EscapePowerShellString(_moduleManifest)}}' -Force
            $rows = @(Find-CrestronBootup -CidrFile '{{EscapePowerShellString(cidrFile)}}' -OutputCsv '{{EscapePowerShellString(outputCsv)}}' -Throttle 64 6>$null)
            $payload = [pscustomobject]@{
                Success = $true
                Count = $rows.Count
                Rows = @($rows | Select-Object IP,MatchedSig,ScannedAt)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 8
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            progress?.Report($"Scanning {cleanCidrs.Length} subnet(s)...");
            var json = await RunJsonScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<ScanResultDto>(json, JsonOptions);
            return result?.Rows?
                .Where(r => !string.IsNullOrWhiteSpace(r.IP))
                .Select(r => new ScanDeviceRow
                {
                    Selected = true,
                    IP = r.IP ?? "",
                    MatchedSig = r.MatchedSig ?? "",
                    ScannedAt = r.ScannedAt ?? ""
                })
                .ToArray() ?? Array.Empty<ScanDeviceRow>();
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<IReadOnlyList<ProvisionDeviceRow>> ProvisionAdminAsync(
        IEnumerable<string> ips,
        string username,
        string password,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var cleanIps = ips
            .Select(ip => ip.Trim())
            .Where(ip => !string.IsNullOrWhiteSpace(ip))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (cleanIps.Length == 0)
        {
            return Array.Empty<ProvisionDeviceRow>();
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var ipsFile = Path.Combine(tempDir, "provision-ips.json");
        var credentialFile = Path.Combine(tempDir, "provision-credential.json");
        var resultsCsv = Path.Combine(_dataRoot, "crestron-provisioned.csv");
        await File.WriteAllTextAsync(ipsFile, JsonSerializer.Serialize(cleanIps), cancellationToken).ConfigureAwait(false);
        await File.WriteAllTextAsync(credentialFile, JsonSerializer.Serialize(new { Username = username, Password = password }), cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            Import-Module '{{EscapePowerShellString(_moduleManifest)}}' -Force
            $provisionCredential = Get-Content '{{EscapePowerShellString(credentialFile)}}' -Raw | ConvertFrom-Json
            if (-not $provisionCredential.Username -or -not $provisionCredential.Password) {
                throw 'Provisioning username/password is required.'
            }
            $secure = ConvertTo-SecureString ([string]$provisionCredential.Password) -AsPlainText -Force
            $credential = [pscredential]::new([string]$provisionCredential.Username, $secure)
            $ips = @(Get-Content '{{EscapePowerShellString(ipsFile)}}' -Raw | ConvertFrom-Json)
            $rows = @(Set-CrestronAdmin -IP $ips -Credential $credential -Force -ResultsCsv '{{EscapePowerShellString(resultsCsv)}}' 6>$null)
            $normalizedRows = @($rows | ForEach-Object {
                [pscustomobject]@{
                    IP = "$($_.IP)"
                    Status = "$($_.Status)"
                    Success = [bool]$_.Success
                    Response = "$($_.Response)"
                    Timestamp = "$($_.Timestamp)"
                }
            })
            $payload = [pscustomobject]@{
                Success = $true
                Count = $normalizedRows.Count
                Rows = @($normalizedRows)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 8
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            progress?.Report($"Provisioning {cleanIps.Length} device(s)...");
            var json = await RunJsonScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<ProvisionResultDto>(json, JsonOptions);
            return result?.Rows?
                .Where(r => !string.IsNullOrWhiteSpace(r.IP))
                .Select(r => new ProvisionDeviceRow
                {
                    Selected = true,
                    IP = r.IP ?? "",
                    Status = r.Status ?? "",
                    Success = r.Success?.ToString() ?? "",
                    Response = r.Response ?? "",
                    Timestamp = r.Timestamp ?? ""
                })
                .ToArray() ?? Array.Empty<ProvisionDeviceRow>();
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<IReadOnlyList<BlanketDeviceRow>> FetchBlanketCapabilitiesAsync(
        IEnumerable<string> ips,
        string? credUsername,
        string? credPassword,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var cleanIps = ips
            .Select(ip => ip.Trim())
            .Where(ip => !string.IsNullOrWhiteSpace(ip))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (cleanIps.Length == 0)
        {
            return Array.Empty<BlanketDeviceRow>();
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var ipsFile = Path.Combine(tempDir, "blanket-ips.json");
        var credBlock = BuildCredentialBlock(credUsername, credPassword);
        await File.WriteAllTextAsync(ipsFile, JsonSerializer.Serialize(cleanIps), cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            Import-Module '{{EscapePowerShellString(_moduleManifest)}}' -Force
            {{credBlock}}
            $ips = @(Get-Content '{{EscapePowerShellString(ipsFile)}}' -Raw | ConvertFrom-Json)
            $manifest = '{{EscapePowerShellString(_moduleManifest)}}'

            $rows = @($ips | ForEach-Object -ThrottleLimit 16 -Parallel {
                $ip = $_
                try {
                    Import-Module $using:manifest -Force -ErrorAction Stop
                    $sec = ConvertTo-SecureString $using:userPass -AsPlainText -Force
                    $cred = [pscredential]::new($using:userName, $sec)
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred
                    try {
                        $caps = Get-CrestronDeviceCapabilities -Session $sess
                        [pscustomobject]@{
                            IP = $ip
                            Model = "$($caps.Model)"
                            Hostname = "$($caps.Hostname)"
                            CurrentDeviceMode = "$($caps.CurrentDeviceMode)"
                            AvApiFamily = "$($caps.AvApiFamily)"
                            AvApiVersion = "$($caps.AvApiVersion)"
                            SupportsAvSettings = [bool]$caps.SupportsAvSettings
                            SupportsGlobalEdid = [bool]$caps.SupportsGlobalEdid
                            EdidNames = (@($caps.EdidNames) -join '|')
                            SupportsNtp = [bool]$caps.SupportsNtp
                            SupportsCloud = [bool]$caps.SupportsCloud
                            SupportsFusion = [bool]$caps.SupportsFusion
                            SupportsAutoUpdate = [bool]$caps.SupportsAutoUpdate
                            SupportsDisplaySettings = [bool]$caps.SupportsDisplaySettings
                            SupportsToolbarSettings = [bool]$caps.SupportsToolbarSettings
                            SupportsAvFrameworkSettings = [bool]$caps.SupportsAvFrameworkSettings
                            CapabilitiesFetched = $true
                            Status = 'OK'
                            Detail = 'Capabilities fetched'
                            NeedsReboot = $false
                            Timestamp = (Get-Date).ToString('s')
                        }
                    }
                    finally {
                        Disconnect-CrestronDevice -Session $sess -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    [pscustomobject]@{
                        IP = $ip
                        Model = ''
                        Hostname = ''
                        CurrentDeviceMode = ''
                        AvApiFamily = ''
                        AvApiVersion = ''
                        SupportsAvSettings = $false
                        SupportsGlobalEdid = $false
                        EdidNames = ''
                        SupportsNtp = $false
                        SupportsCloud = $false
                        SupportsFusion = $false
                        SupportsAutoUpdate = $false
                        SupportsDisplaySettings = $false
                        SupportsToolbarSettings = $false
                        SupportsAvFrameworkSettings = $false
                        CapabilitiesFetched = $false
                        Status = 'Error'
                        Detail = "ERROR: $($_.Exception.Message)"
                        NeedsReboot = $false
                        Timestamp = (Get-Date).ToString('s')
                    }
                }
            })

            $payload = [pscustomobject]@{
                Success = $true
                Count = $rows.Count
                Rows = @($rows | Select-Object IP,Model,Hostname,CurrentDeviceMode,AvApiFamily,AvApiVersion,SupportsAvSettings,SupportsGlobalEdid,EdidNames,SupportsNtp,SupportsCloud,SupportsFusion,SupportsAutoUpdate,SupportsDisplaySettings,SupportsToolbarSettings,SupportsAvFrameworkSettings,CapabilitiesFetched,Status,Detail,NeedsReboot,Timestamp)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 8
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            progress?.Report($"Fetching capabilities for {cleanIps.Length} device(s)...");
            var json = await RunJsonScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<BlanketResultDto>(json, JsonOptions);
            return result?.Rows?.Select(ToBlanketRow).ToArray() ?? Array.Empty<BlanketDeviceRow>();
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<IReadOnlyList<BlanketDeviceRow>> ApplyBlanketSettingsAsync(
        IEnumerable<BlanketDeviceRow> rows,
        BlanketApplyOptions options,
        string? credUsername,
        string? credPassword,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var cleanRows = rows
            .Where(row => !string.IsNullOrWhiteSpace(row.IP))
            .Select(row => new BlanketRowDto
            {
                IP = row.IP,
                Model = row.Model,
                Hostname = row.Hostname,
                CurrentDeviceMode = row.CurrentDeviceMode,
                AvApiFamily = row.AvApiFamily,
                AvApiVersion = row.AvApiVersion,
                SupportsAvSettings = row.SupportsAvSettings,
                SupportsGlobalEdid = row.SupportsGlobalEdid,
                EdidNames = row.EdidNames,
                SupportsNtp = row.SupportsNtp,
                SupportsCloud = row.SupportsCloud,
                SupportsFusion = row.SupportsFusion,
                SupportsAutoUpdate = row.SupportsAutoUpdate,
                SupportsDisplaySettings = row.SupportsDisplaySettings,
                SupportsToolbarSettings = row.SupportsToolbarSettings,
                SupportsAvFrameworkSettings = row.SupportsAvFrameworkSettings,
                CapabilitiesFetched = row.CapabilitiesFetched
            })
            .ToArray();
        if (cleanRows.Length == 0)
        {
            return Array.Empty<BlanketDeviceRow>();
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var rowsFile = Path.Combine(tempDir, "blanket-rows.json");
        var optionsFile = Path.Combine(tempDir, "blanket-options.json");
        var resultsCsv = Path.Combine(_dataRoot, "crestron-settings.csv");
        var credBlock = BuildCredentialBlock(credUsername, credPassword);
        await File.WriteAllTextAsync(rowsFile, JsonSerializer.Serialize(cleanRows), cancellationToken).ConfigureAwait(false);
        await File.WriteAllTextAsync(optionsFile, JsonSerializer.Serialize(options), cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            Import-Module '{{EscapePowerShellString(_moduleManifest)}}' -Force
            {{credBlock}}
            $rows = @(Get-Content '{{EscapePowerShellString(rowsFile)}}' -Raw | ConvertFrom-Json)
            $options = Get-Content '{{EscapePowerShellString(optionsFile)}}' -Raw | ConvertFrom-Json
            $manifest = '{{EscapePowerShellString(_moduleManifest)}}'

            function Test-CabsNeedsReboot($result) {
                if ($null -eq $result) { return $false }
                if ($result.PSObject.Properties.Name -contains 'NeedsReboot' -and [bool]$result.NeedsReboot) { return $true }
                if ($result.SectionResults) {
                    foreach ($sectionResult in @($result.SectionResults)) {
                        if ([int]$sectionResult.StatusId -eq 1) { return $true }
                        if ("$($sectionResult.StatusInfo)" -match '(?i)reboot|restart|power cycle') { return $true }
                    }
                }
                if ("$($result.Response)" -match '(?i)reboot|restart|power cycle') { return $true }
                return $false
            }

            $outRows = @($rows | ForEach-Object -ThrottleLimit 12 -Parallel {
                $row = $_
                $options = $using:options
                function Test-CabsNeedsReboot($result) {
                    if ($null -eq $result) { return $false }
                    if ($result.PSObject.Properties.Name -contains 'NeedsReboot' -and [bool]$result.NeedsReboot) { return $true }
                    if ($result.SectionResults) {
                        foreach ($sectionResult in @($result.SectionResults)) {
                            if ([int]$sectionResult.StatusId -eq 1) { return $true }
                            if ("$($sectionResult.StatusInfo)" -match '(?i)reboot|restart|power cycle') { return $true }
                        }
                    }
                    if ("$($result.Response)" -match '(?i)reboot|restart|power cycle') { return $true }
                    return $false
                }

                try {
                    Import-Module $using:manifest -Force -ErrorAction Stop
                    $sec = ConvertTo-SecureString $using:userPass -AsPlainText -Force
                    $cred = [pscredential]::new($using:userName, $sec)
                    $sess = Connect-CrestronDevice -IP $row.IP -Credential $cred
                    $sections = @()
                    $details = @()
                    $success = $true
                    $needsReboot = $false
                    try {
                        $settingsArgs = @{ Session = $sess }
                        if ([bool]$options.ApplyNtp) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsNtp) {
                                $details += 'NTP=skipped unsupported'
                            }
                            else {
                                $settingsArgs.Ntp = @{
                                    TimeZone = "$($options.TimeZoneCode)"
                                    NtpServer = "$($options.NtpServer)"
                                    NtpEnabled = $true
                                }
                            }
                        }
                        if ([bool]$options.ApplyCloud) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsCloud) {
                                $details += 'Cloud=skipped unsupported'
                            }
                            else {
                                $settingsArgs.Cloud = [bool]$options.CloudEnabled
                            }
                        }
                        if ([bool]$options.ApplyFusion) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsFusion) {
                                $details += 'Fusion=skipped unsupported'
                            }
                            else {
                                $settingsArgs.Fusion = [bool]$options.FusionEnabled
                            }
                        }
                        if ([bool]$options.ApplyAutoUpdate) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsAutoUpdate) {
                                $details += 'AutoUpdate=skipped unsupported'
                            }
                            else {
                                $settingsArgs.AutoUpdate = @{ Enabled = [bool]$options.AutoUpdateEnabled }
                            }
                        }
                        if ($settingsArgs.Keys.Count -gt 1) {
                            $result = Set-CrestronSettings @settingsArgs
                            $success = $success -and [bool]$result.Success
                            $sections += @($result.AppliedSections)
                            $details += "Settings=$(if([bool]$result.Success){'OK'}else{'Failed'})"
                            if (Test-CabsNeedsReboot $result) { $needsReboot = $true }
                        }

                        if ([bool]$options.ApplyDisplay) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsDisplaySettings) {
                                $details += 'Display=skipped unsupported'
                            }
                            else {
                                $displayArgs = @{
                                    Session = $sess
                                    AutoBrightness = [bool]$options.AutoBrightnessEnabled
                                    ScreensaverEnabled = [bool]$options.ScreensaverEnabled
                                    StandbyTimeout = [int]$options.StandbyTimeout
                                }
                                if (-not [bool]$options.AutoBrightnessEnabled) {
                                    $displayArgs.Brightness = [int]$options.Brightness
                                }
                                if (-not [bool]$row.CapabilitiesFetched -or [bool]$row.SupportsToolbarSettings) {
                                    $displayArgs.ToolbarEnabled = [bool]$options.ToolbarEnabled
                                }
                                $displayResult = Set-CrestronDisplaySettings @displayArgs
                                $success = $success -and [bool]$displayResult.Success
                                $sections += @($displayResult.AppliedSections)
                                $details += "Display=$(if([bool]$displayResult.Success){'OK'}else{'Failed'})"
                                if (Test-CabsNeedsReboot $displayResult) { $needsReboot = $true }
                            }
                        }

                        if ([bool]$options.ApplyAvFramework) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsAvFrameworkSettings) {
                                $details += 'AVFramework=skipped unsupported'
                            }
                            else {
                                $avfResult = Set-CrestronAvFrameworkSettings -Session $sess -Enabled ([bool]$options.AvFrameworkEnabled)
                                $success = $success -and [bool]$avfResult.Success
                                $sections += @($avfResult.AppliedSections)
                                $details += "AVFramework=$(if([bool]$avfResult.Success){'OK'}else{'Failed'})"
                                if (Test-CabsNeedsReboot $avfResult) { $needsReboot = $true }
                            }
                        }

                        if ([bool]$options.ApplyInputHdcp) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsAvSettings) {
                                $details += 'InputHdcp=skipped unsupported'
                            }
                            else {
                                $inHdcpResult = Set-CrestronInputHdcp -Session $sess -Mode "$($options.InputHdcpMode)"
                                $success = $success -and [bool]$inHdcpResult.Success
                                $sections += 'InputHdcp'
                                $details += "InputHdcp=$(if([bool]$inHdcpResult.Success){'OK'}else{'Failed'})"
                                if (Test-CabsNeedsReboot $inHdcpResult) { $needsReboot = $true }
                            }
                        }

                        if ([bool]$options.ApplyOutputHdcp) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsAvSettings) {
                                $details += 'OutputHdcp=skipped unsupported'
                            }
                            else {
                                $outHdcpResult = Set-CrestronOutputHdcp -Session $sess -Mode "$($options.OutputHdcpMode)"
                                $success = $success -and [bool]$outHdcpResult.Success
                                $sections += 'OutputHdcp'
                                $details += "OutputHdcp=$(if([bool]$outHdcpResult.Success){'OK'}else{'Failed'})"
                                if (Test-CabsNeedsReboot $outHdcpResult) { $needsReboot = $true }
                            }
                        }

                        if ([bool]$options.ApplyOutputResolution) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsAvSettings) {
                                $details += 'OutputResolution=skipped unsupported'
                            }
                            else {
                                $outResResult = Set-CrestronOutputResolution -Session $sess -Resolution "$($options.OutputResolution)"
                                $success = $success -and [bool]$outResResult.Success
                                $sections += 'OutputResolution'
                                $details += "OutputResolution=$(if([bool]$outResResult.Success){'OK'}else{'Failed'})"
                                if (Test-CabsNeedsReboot $outResResult) { $needsReboot = $true }
                            }
                        }

                        if ([bool]$options.ApplyGlobalEdid) {
                            if ([bool]$row.CapabilitiesFetched -and -not [bool]$row.SupportsGlobalEdid) {
                                $details += "GlobalEdid=skipped unsupported ($($row.AvApiFamily) $($row.AvApiVersion))"
                            }
                            else {
                                $edidResult = Set-CrestronGlobalEdid -Session $sess -EdidName "$($options.GlobalEdidName)" -EdidType "$($options.GlobalEdidType)"
                                $success = $success -and [bool]$edidResult.Success
                                $sections += 'GlobalEdid'
                                $details += "GlobalEdid=$(if([bool]$edidResult.Success){'OK'}else{'Failed'})"
                                if (Test-CabsNeedsReboot $edidResult) { $needsReboot = $true }
                            }
                        }

                        [pscustomobject]@{
                            IP = $row.IP
                            Model = "$($row.Model)"
                            Hostname = "$($row.Hostname)"
                            CurrentDeviceMode = "$($row.CurrentDeviceMode)"
                            AvApiFamily = "$($row.AvApiFamily)"
                            AvApiVersion = "$($row.AvApiVersion)"
                            SupportsAvSettings = [bool]$row.SupportsAvSettings
                            SupportsGlobalEdid = [bool]$row.SupportsGlobalEdid
                            EdidNames = "$($row.EdidNames)"
                            SupportsNtp = [bool]$row.SupportsNtp
                            SupportsCloud = [bool]$row.SupportsCloud
                            SupportsFusion = [bool]$row.SupportsFusion
                            SupportsAutoUpdate = [bool]$row.SupportsAutoUpdate
                            SupportsDisplaySettings = [bool]$row.SupportsDisplaySettings
                            SupportsToolbarSettings = [bool]$row.SupportsToolbarSettings
                            SupportsAvFrameworkSettings = [bool]$row.SupportsAvFrameworkSettings
                            CapabilitiesFetched = [bool]$row.CapabilitiesFetched
                            Status = if ($success) { 'OK' } else { 'Failed' }
                            Detail = ($details -join '; ')
                            NeedsReboot = $needsReboot
                            Timestamp = (Get-Date).ToString('s')
                        }
                    }
                    finally {
                        Disconnect-CrestronDevice -Session $sess -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    [pscustomobject]@{
                        IP = $row.IP
                        Model = "$($row.Model)"
                        Hostname = "$($row.Hostname)"
                        CurrentDeviceMode = "$($row.CurrentDeviceMode)"
                        AvApiFamily = "$($row.AvApiFamily)"
                        AvApiVersion = "$($row.AvApiVersion)"
                        SupportsAvSettings = [bool]$row.SupportsAvSettings
                        SupportsGlobalEdid = [bool]$row.SupportsGlobalEdid
                        EdidNames = "$($row.EdidNames)"
                        SupportsNtp = [bool]$row.SupportsNtp
                        SupportsCloud = [bool]$row.SupportsCloud
                        SupportsFusion = [bool]$row.SupportsFusion
                        SupportsAutoUpdate = [bool]$row.SupportsAutoUpdate
                        SupportsDisplaySettings = [bool]$row.SupportsDisplaySettings
                        SupportsToolbarSettings = [bool]$row.SupportsToolbarSettings
                        SupportsAvFrameworkSettings = [bool]$row.SupportsAvFrameworkSettings
                        CapabilitiesFetched = [bool]$row.CapabilitiesFetched
                        Status = 'Error'
                        Detail = "ERROR: $($_.Exception.Message)"
                        NeedsReboot = $false
                        Timestamp = (Get-Date).ToString('s')
                    }
                }
            })

            $outRows | Select-Object IP,Model,Hostname,CurrentDeviceMode,AvApiFamily,AvApiVersion,SupportsAvSettings,SupportsGlobalEdid,EdidNames,SupportsNtp,SupportsCloud,SupportsFusion,SupportsAutoUpdate,SupportsDisplaySettings,SupportsToolbarSettings,SupportsAvFrameworkSettings,CapabilitiesFetched,Status,Detail,NeedsReboot,Timestamp |
                Export-Csv -NoTypeInformation -Path '{{EscapePowerShellString(resultsCsv)}}'
            $payload = [pscustomobject]@{
                Success = $true
                Count = $outRows.Count
                Rows = @($outRows | Select-Object IP,Model,Hostname,CurrentDeviceMode,AvApiFamily,AvApiVersion,SupportsAvSettings,SupportsGlobalEdid,EdidNames,SupportsNtp,SupportsCloud,SupportsFusion,SupportsAutoUpdate,SupportsDisplaySettings,SupportsToolbarSettings,SupportsAvFrameworkSettings,CapabilitiesFetched,Status,Detail,NeedsReboot,Timestamp)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 8
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            progress?.Report($"Applying blanket settings to {cleanRows.Length} device(s)...");
            var json = await RunJsonScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<BlanketResultDto>(json, JsonOptions);
            return result?.Rows?.Select(ToBlanketRow).ToArray() ?? Array.Empty<BlanketDeviceRow>();
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<PerDeviceStateResult> FetchPerDeviceStateAsync(
        IEnumerable<string> ips,
        string? credUsername,
        string? credPassword,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var cleanIps = ips
            .Select(ip => ip.Trim())
            .Where(ip => !string.IsNullOrWhiteSpace(ip))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (cleanIps.Length == 0)
        {
            return EmptyPerDeviceStateResult;
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var ipsFile = Path.Combine(tempDir, "perdevice-ips.json");
        var credBlock = BuildCredentialBlock(credUsername, credPassword);
        var resultsCsv = Path.Combine(_dataRoot, "crestron-perdevice.csv");
        await File.WriteAllTextAsync(ipsFile, JsonSerializer.Serialize(cleanIps), cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            Import-Module '{{EscapePowerShellString(_moduleManifest)}}' -Force
            {{credBlock}}
            $ips = @(Get-Content '{{EscapePowerShellString(ipsFile)}}' -Raw | ConvertFrom-Json)
            $manifest = '{{EscapePowerShellString(_moduleManifest)}}'

            $rows = @($ips | ForEach-Object -ThrottleLimit 16 -Parallel {
                $ip = $_
                function Convert-CabsToggleText($Value) {
                    if ($null -eq $Value) { return 'N/A' }
                    if ([bool]$Value) { return 'Enabled' }
                    return 'Disabled'
                }
                function Convert-CabsInputHdcpMode($Value) {
                    $text = "$Value".Trim()
                    switch -Regex ($text) {
                        '^HDCP\s*1(\.x|\.4)?$' { return 'HDCP 1.4' }
                        '^HDCP\s*2(\.x|\.0|\.2)?$' { return 'HDCP 2.x' }
                        '^Never\s*Authenticate$' { return 'Never Authenticate' }
                        '^Disabled$' { return 'Never Authenticate' }
                        '^Enabled$' { return 'Auto' }
                        '^Auto$' { return 'Auto' }
                        default { if ([string]::IsNullOrWhiteSpace($text)) { 'N/A' } else { $text } }
                    }
                }
                function Convert-CabsOutputHdcpMode($Value) {
                    $text = "$Value".Trim()
                    switch -Regex ($text) {
                        '^Follow\s*Input$' { return 'FollowInput' }
                        '^Force\s*Highest$' { return 'ForceHighest' }
                        '^Never\s*Authenticate$' { return 'NeverAuthenticate' }
                        '^Auto$' { return 'Auto' }
                        default { if ([string]::IsNullOrWhiteSpace($text)) { 'N/A' } else { $text } }
                    }
                }

                try {
                    Import-Module $using:manifest -Force -ErrorAction Stop
                    $sec = ConvertTo-SecureString $using:userPass -AsPlainText -Force
                    $cred = [pscredential]::new($using:userName, $sec)
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred

                    try {
                        $state = Get-CrestronDeviceState -Session $sess
                        $dnsArr = @($state.DnsServers)
                        $dns1 = if ($dnsArr.Count -ge 1) { "$($dnsArr[0])" } else { '' }
                        $model = "$($sess.Model)"
                        if ([string]::IsNullOrWhiteSpace($model)) { $model = "$($state.Model)" }
                        $modelKey = $model.Trim().ToUpperInvariant()
                        $modelLooksDisplayCapable = $modelKey -match '^(TS|TSW|TSS|TST|DGE)(-|$)'
                        $supportsDisplay = [bool]$state.SupportsDisplaySettings -or $modelLooksDisplayCapable
                        $supportsToolbar = [bool]$state.SupportsToolbarSettings -or ($modelLooksDisplayCapable -and $null -ne $state.CurrentToolbarEnabled)
                        $autoBrightness = if ($supportsDisplay) { Convert-CabsToggleText $state.CurrentAutoBrightness } else { 'N/A' }
                        $brightness = if ($supportsDisplay -and $null -ne $state.CurrentBrightness) { "$($state.CurrentBrightness)" } else { 'N/A' }
                        $screensaver = if ($supportsDisplay) { Convert-CabsToggleText $state.CurrentScreensaverEnabled } else { 'N/A' }
                        $standby = if ($supportsDisplay -and $null -ne $state.CurrentStandbyTimeout) { "$($state.CurrentStandbyTimeout)" } else { 'N/A' }
                        $toolbar = if ($supportsToolbar) { Convert-CabsToggleText $state.CurrentToolbarEnabled } else { 'N/A' }
                        $avFramework = if ([bool]$state.SupportsAvFrameworkSettings) { Convert-CabsToggleText $state.CurrentAvFrameworkEnabled } else { 'N/A' }
                        $hostname = "$($state.Hostname)"
                        $dhcp = [bool]$state.EthernetLanDhcp
                        $ipMode = if ($dhcp) { 'DHCP' } else { 'Static' }
                        $currentIp = "$($state.EthernetLanIP)"
                        $currentSubnet = "$($state.EthernetLanSubnet)"
                        $currentGateway = "$($state.EthernetLanGateway)"
                        $ipId = "$($state.CurrentIpId)"
                        $csAddr = "$($state.CurrentControlSystemAddr)"
                        $avRows = @()
                        $multicastRows = @()
                        $controlSubnetRows = @()
                        $supportsAvRoutingBool = $false
                        $autoInputRouting = 'N/A'

                        try {
                            $av = Get-CrestronAvSettings -Session $sess
                            if ($av) {
                                if ([string]::IsNullOrWhiteSpace($model)) { $model = "$($av.Model)" }
                                $modelKey = "$model".Trim().ToUpperInvariant()
                                $isNvx = $modelKey -match '^DM-NVX'
                                $modelIsDecoderOnly = $modelKey -match '^DM-NVX-D\d'
                                $modelIsEncoderOnly = $modelKey -match '^DM-NVX-E\d'
                                $effectiveSupportsTransmit = [bool]$av.SupportsStreamTransmit -and -not $modelIsDecoderOnly
                                $effectiveSupportsReceive = [bool]$av.SupportsStreamReceive -and -not $modelIsEncoderOnly
                                $supportsAvMulticast = $isNvx -and ($effectiveSupportsTransmit -or $effectiveSupportsReceive)
                                $supportsAvSettings = -not [string]::IsNullOrWhiteSpace("$($av.AvApiFamily)") -and "$($av.AvApiFamily)" -ne 'None'
                                $edidNames = @($av.EdidNames | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | Sort-Object -Unique)
                                $supportsAvRoutingBool = [bool]$av.SupportsAvRouting
                                $autoInputRouting = if ($supportsAvRoutingBool -and $null -ne $av.AutomaticInputRouting) {
                                    Convert-CabsToggleText $av.AutomaticInputRouting
                                } else { 'N/A' }
                                $inputs = @($av.Inputs)

                                if ($supportsAvMulticast) {
                                    $txStreams = @($av.TransmitMulticastAddresses)
                                    $rxStreams = @($av.ReceiveMulticastAddresses)
                                    $txMulticast = if ($txStreams.Count -gt 0) { "$($txStreams[0].MulticastAddress)" } else { '' }
                                    $rxMulticast = if ($rxStreams.Count -gt 0) { "$($rxStreams[0].MulticastAddress)" } else { '' }
                                    $multicastMode = "$($state.CurrentDeviceMode)"

                                    if ($multicastMode -notin @('Transmitter','Receiver')) {
                                        $multicastMode = "$($av.DeviceMode)"
                                    }

                                    if ($multicastMode -notin @('Transmitter','Receiver')) {
                                        if ($effectiveSupportsTransmit -and -not $effectiveSupportsReceive) {
                                            $multicastMode = 'Transmitter'
                                        }
                                        elseif ($effectiveSupportsReceive -and -not $effectiveSupportsTransmit) {
                                            $multicastMode = 'Receiver'
                                        }
                                        else {
                                            $multicastMode = 'N/A'
                                        }
                                    }

                                    $multicastDirection = switch ($multicastMode) {
                                        'Transmitter' { 'Transmit'; break }
                                        'Receiver' { 'Receive'; break }
                                        default { '' }
                                    }
                                    $currentMulticast = if ($multicastDirection -eq 'Transmit') {
                                        $txMulticast
                                    }
                                    elseif ($multicastDirection -eq 'Receive') {
                                        $rxMulticast
                                    }
                                    else {
                                        ''
                                    }

                                    $modeOptions = @()
                                    if ($effectiveSupportsTransmit) { $modeOptions += 'Transmitter' }
                                    if ($effectiveSupportsReceive) { $modeOptions += 'Receiver' }
                                    if ($modeOptions.Count -eq 0 -and $multicastMode -in @('Transmitter','Receiver')) { $modeOptions += $multicastMode }

                                    $supportsModeChange = [bool]$state.SupportsModeChange -and $effectiveSupportsTransmit -and $effectiveSupportsReceive
                                    $multicastRows += [pscustomobject]@{
                                        IP = $ip
                                        Model = $model
                                        Hostname = $hostname
                                        Direction = $multicastDirection
                                        CurrentDeviceMode = $multicastMode
                                        DeviceMode = $multicastMode
                                        SupportsModeChange = $supportsModeChange
                                        StreamIndex = 0
                                        CurrentMulticastAddress = if ([string]::IsNullOrWhiteSpace($currentMulticast)) { 'N/A' } else { $currentMulticast }
                                        NewMulticastAddress = if ([string]::IsNullOrWhiteSpace($currentMulticast)) { 'N/A' } else { $currentMulticast }
                                        SupportsAvMulticast = $supportsAvMulticast
                                        DeviceModeOptions = @($modeOptions | Sort-Object -Unique)
                                    }
                                }

                                if ($isNvx -and -not $modelIsDecoderOnly) {
                                    for ($i = 0; $i -lt $inputs.Count; $i++) {
                                        $inputItem = $inputs[$i]
                                        $inputEdidNames = @($inputItem.EdidOptions | Where-Object {
                                            -not [string]::IsNullOrWhiteSpace("$_")
                                        } | Sort-Object -Unique)
                                        if ($inputEdidNames.Count -eq 0) { $inputEdidNames = $edidNames }
                                        $currentEdid = "$($inputItem.CurrentEdid)"
                                        $inputEdidNames = @(@($currentEdid) + @($inputEdidNames) |
                                            Where-Object { -not [string]::IsNullOrWhiteSpace("$_") -and "$_" -ne 'N/A' } |
                                            Sort-Object -Unique)
                                        $currentInputHdcp = Convert-CabsInputHdcpMode $inputItem.HdcpReceiverCapability
                                        $portTypeUpper = "$($inputItem.PortType)".Trim().ToUpperInvariant()
                                        $rawInputLabel = "$($inputItem.InputName)".Trim()
                                        $inputLabel = if ([string]::IsNullOrWhiteSpace($rawInputLabel) -or $rawInputLabel -imatch '^(input|in)\d+$') {
                                            if ($portTypeUpper) { "$portTypeUpper In $($i + 1)" } else { "Input $($i + 1)" }
                                        } else { $rawInputLabel }
                                        $rowSupportsAvRouting = ($i -eq 0) -and $supportsAvRoutingBool
                                        $avRows += [pscustomobject]@{
                                            RowKind = 'Input'
                                            IP = $ip; Model = $model; Hostname = $hostname
                                            PortLabel = $inputLabel
                                            PortType = $portTypeUpper
                                            InputIndex = $i
                                            OutputIndex = -1
                                            SupportsInputHdcp = [bool]$supportsAvSettings
                                            SupportsEdidEdit = (($inputEdidNames.Count -gt 0) -or -not [string]::IsNullOrWhiteSpace($currentEdid))
                                            CurrentEdid = $currentEdid
                                            NewEdidName = if ([string]::IsNullOrWhiteSpace($currentEdid) -or $currentEdid -eq 'N/A') { '' } else { $currentEdid }
                                            EdidNameOptions = @($inputEdidNames)
                                            CurrentInputHdcp = $currentInputHdcp
                                            NewInputHdcp = $currentInputHdcp
                                            SupportsAvRouting = $rowSupportsAvRouting
                                            CurrentAutoInputRouting = if ($rowSupportsAvRouting) { $autoInputRouting } else { 'N/A' }
                                            NewAutoInputRouting = if ($rowSupportsAvRouting) { $autoInputRouting } else { 'N/A' }
                                        }
                                    }
                                }

                                if ($isNvx -and -not $modelIsEncoderOnly) {
                                    $outputs = @($av.Outputs)
                                    for ($i = 0; $i -lt $outputs.Count; $i++) {
                                        $outputItem = $outputs[$i]
                                        $currentOutputHdcp = Convert-CabsOutputHdcpMode $outputItem.HdcpTransmitterMode
                                        $currentOutputResolution = "$($outputItem.Resolution)"
                                        $outPortTypeUpper = "$($outputItem.PortType)".Trim().ToUpperInvariant()
                                        $rawOutputLabel = "$($outputItem.OutputName)".Trim()
                                        $outputLabel = if ([string]::IsNullOrWhiteSpace($rawOutputLabel) -or $rawOutputLabel -imatch '^(output|out)\d+$') {
                                            if ($outPortTypeUpper) { "$outPortTypeUpper Out $($i + 1)" } else { "Output $($i + 1)" }
                                        } else { $rawOutputLabel }
                                        $resolutionOptions = @(
                                            $currentOutputResolution,
                                            'Auto',
                                            '3840x2160@60',
                                            '3840x2160@30',
                                            '1920x1080@60',
                                            '1920x1080@30',
                                            '1280x720@60'
                                        ) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") -and "$_" -ne 'N/A' } | Sort-Object -Unique

                                        $avRows += [pscustomobject]@{
                                            RowKind = 'Output'
                                            IP = $ip; Model = $model; Hostname = $hostname
                                            PortLabel = $outputLabel
                                            PortType = $outPortTypeUpper
                                            InputIndex = -1
                                            OutputIndex = $i
                                            SupportsOutputHdcp = [bool]$supportsAvSettings
                                            SupportsOutputResolution = [bool]$supportsAvSettings
                                            CurrentOutputHdcp = $currentOutputHdcp
                                            NewOutputHdcp = $currentOutputHdcp
                                            CurrentOutputResolution = if ([string]::IsNullOrWhiteSpace($currentOutputResolution)) { 'N/A' } else { $currentOutputResolution }
                                            NewOutputResolution = if ([string]::IsNullOrWhiteSpace($currentOutputResolution)) { 'N/A' } else { $currentOutputResolution }
                                            OutputResolutionOptions = @($resolutionOptions)
                                        }
                                    }
                                }
                            }
                        }
                        catch { }

                        try {
                            $controlSubnet = Get-CrestronControlSubnetSettings -Session $sess -Credential $cred

                            if ($controlSubnet -and [bool]$controlSubnet.SupportsControlSubnet) {
                                $controlIp = "$($controlSubnet.StaticIPAddress)"
                                if ([string]::IsNullOrWhiteSpace($controlIp)) { $controlIp = "$($controlSubnet.CurrentIPAddress)" }

                                $controlMask = "$($controlSubnet.StaticSubnetMask)"
                                if ([string]::IsNullOrWhiteSpace($controlMask)) { $controlMask = "$($controlSubnet.CurrentSubnetMask)" }

                                $controlGateway = "$($controlSubnet.StaticDefaultGateway)"
                                if ([string]::IsNullOrWhiteSpace($controlGateway)) { $controlGateway = "$($controlSubnet.DefaultGateway)" }

                                $currentMode = if ($null -eq $controlSubnet.IsDhcpEnabled) {
                                    'N/A'
                                }
                                elseif ([bool]$controlSubnet.IsDhcpEnabled) {
                                    'DHCP'
                                }
                                else {
                                    'Static'
                                }

                                $currentEnabled = Convert-CabsToggleText $controlSubnet.IsEnabled
                                $currentIgmpVersion = "$($controlSubnet.IgmpVersion)"
                                if ([string]::IsNullOrWhiteSpace($currentIgmpVersion)) { $currentIgmpVersion = 'N/A' }
                                $currentRouterAuto = Convert-CabsToggleText $controlSubnet.RouterAutomaticMode
                                $currentRouterIsolation = Convert-CabsToggleText $controlSubnet.RouterIsolationMode
                                $currentIgmpProxy = Convert-CabsToggleText $controlSubnet.IgmpProxyEnabled

                                $controlSubnetRows += [pscustomobject]@{
                                    IP = $ip
                                    Model = $model
                                    Hostname = $hostname
                                    SupportsControlSubnet = [bool]$controlSubnet.SupportsControlSubnet
                                    SupportsRouter = [bool]$controlSubnet.SupportsRouter
                                    SupportsIgmpVersion = [bool]$controlSubnet.SupportsIgmpVersion
                                    SupportsIgmpProxy = [bool]$controlSubnet.SupportsIgmpProxy
                                    CurrentEnabled = $currentEnabled
                                    NewEnabled = $currentEnabled
                                    CurrentDhcp = $controlSubnet.IsDhcpEnabled
                                    IPMode = $currentMode
                                    CurrentIPAddress = if ([string]::IsNullOrWhiteSpace($controlIp)) { 'N/A' } else { $controlIp }
                                    NewIPAddress = if ([string]::IsNullOrWhiteSpace($controlIp)) { 'N/A' } else { $controlIp }
                                    CurrentSubnetMask = if ([string]::IsNullOrWhiteSpace($controlMask)) { 'N/A' } else { $controlMask }
                                    NewSubnetMask = if ([string]::IsNullOrWhiteSpace($controlMask)) { 'N/A' } else { $controlMask }
                                    CurrentGateway = if ([string]::IsNullOrWhiteSpace($controlGateway)) { 'N/A' } else { $controlGateway }
                                    NewGateway = if ([string]::IsNullOrWhiteSpace($controlGateway)) { 'N/A' } else { $controlGateway }
                                    CurrentIgmpVersion = $currentIgmpVersion
                                    NewIgmpVersion = $currentIgmpVersion
                                    CurrentRouterAutomaticMode = $currentRouterAuto
                                    NewRouterAutomaticMode = $currentRouterAuto
                                    CurrentRouterPrefix = if ([string]::IsNullOrWhiteSpace("$($controlSubnet.RouterPrefix)")) { 'N/A' } else { "$($controlSubnet.RouterPrefix)" }
                                    NewRouterPrefix = if ([string]::IsNullOrWhiteSpace("$($controlSubnet.RouterPrefix)")) { 'N/A' } else { "$($controlSubnet.RouterPrefix)" }
                                    CurrentRouterOnlineDelay = if ([string]::IsNullOrWhiteSpace("$($controlSubnet.RouterOnlineDelay)")) { 'N/A' } else { "$($controlSubnet.RouterOnlineDelay)" }
                                    NewRouterOnlineDelay = if ([string]::IsNullOrWhiteSpace("$($controlSubnet.RouterOnlineDelay)")) { 'N/A' } else { "$($controlSubnet.RouterOnlineDelay)" }
                                    CurrentRouterIsolationMode = $currentRouterIsolation
                                    NewRouterIsolationMode = $currentRouterIsolation
                                    CurrentIgmpProxy = $currentIgmpProxy
                                    NewIgmpProxy = $currentIgmpProxy
                                    IgmpProxyPropertyName = "$($controlSubnet.IgmpProxyPropertyName)"
                                }
                            }
                        }
                        catch { }

                        $supportsNetworkWrite = if ($null -ne $state.SupportsNetwork) { [bool]$state.SupportsNetwork } else { $true }
                        $supportsNetworkRead = if ($state.PSObject.Properties.Name -contains 'SupportsNetworkRead') {
                            [bool]$state.SupportsNetworkRead
                        } else {
                            $supportsNetworkWrite
                        }

                        [pscustomobject]@{
                            IP = $ip
                            Model = $model
                            CurrentHostname = $hostname
                            NewHostname = if ($supportsNetworkRead) { $hostname } else { 'N/A' }
                            SupportsNetwork = $supportsNetworkWrite
                            SupportsIpTable = [bool]$state.SupportsIpTable
                            HasWifi = [bool]$state.HasWifi
                            SupportsDisplaySettings = [bool]$supportsDisplay
                            SupportsToolbarSettings = [bool]$supportsToolbar
                            SupportsAvFrameworkSettings = [bool]$state.SupportsAvFrameworkSettings
                            CurrentIPMode = if ($supportsNetworkRead) { $ipMode } else { 'N/A' }
                            IPMode = if ($supportsNetworkRead) { $ipMode } else { 'N/A' }
                            CurrentIP = $currentIp
                            NewIP = if ($supportsNetworkRead) { $currentIp } else { 'N/A' }
                            CurrentSubnet = $currentSubnet
                            SubnetMask = if ($supportsNetworkRead) { $currentSubnet } else { 'N/A' }
                            CurrentGateway = $currentGateway
                            Gateway = if ($supportsNetworkRead) { $currentGateway } else { 'N/A' }
                            CurrentDns1 = $dns1
                            PrimaryDns = if ($supportsNetworkRead) { $dns1 } else { 'N/A' }
                            CurrentDns2 = ''
                            SecondaryDns = ''
                            DisableWifi = $false
                            CurrentAutoBrightness = $autoBrightness
                            NewAutoBrightness = $autoBrightness
                            CurrentBrightness = $brightness
                            NewBrightness = $brightness
                            CurrentScreensaver = $screensaver
                            NewScreensaver = $screensaver
                            CurrentStandbyTimeout = $standby
                            NewStandbyTimeout = $standby
                            CurrentToolbar = $toolbar
                            NewToolbar = $toolbar
                            CurrentAvFramework = $avFramework
                            NewAvFramework = $avFramework
                            CurrentIpId = $ipId
                            NewIpId = if ([bool]$state.SupportsIpTable -and -not [string]::IsNullOrWhiteSpace($ipId)) { $ipId } else { 'N/A' }
                            CurrentControlSystemAddr = $csAddr
                            NewControlSystemAddr = if ([bool]$state.SupportsIpTable -and -not [string]::IsNullOrWhiteSpace($csAddr)) { $csAddr } else { 'N/A' }
                            Status = 'OK'
                            Detail = 'OK'
                            NeedsReboot = $false
                            Timestamp = (Get-Date).ToString('s')
                            AvRows = @($avRows)
                            MulticastRows = @($multicastRows)
                            ControlSubnetRows = @($controlSubnetRows)
                        }
                    }
                    finally {
                        Disconnect-CrestronDevice -Session $sess -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    [pscustomobject]@{
                        IP = $ip
                        Status = 'Error'
                        Detail = "ERROR: $($_.Exception.Message)"
                        Timestamp = (Get-Date).ToString('s')
                    }
                }
            })
            $avRows = @($rows | ForEach-Object { @($_.AvRows) })
            $multicastRows = @($rows | ForEach-Object { @($_.MulticastRows) })
            $controlSubnetRows = @($rows | ForEach-Object { @($_.ControlSubnetRows) })

            $rows | Select-Object IP,Model,CurrentHostname,NewHostname,SupportsNetwork,SupportsIpTable,HasWifi,SupportsDisplaySettings,SupportsToolbarSettings,SupportsAvFrameworkSettings,IPMode,CurrentIP,NewIP,CurrentSubnet,SubnetMask,CurrentGateway,Gateway,CurrentDns1,PrimaryDns,CurrentDns2,SecondaryDns,DisableWifi,CurrentAutoBrightness,NewAutoBrightness,CurrentBrightness,NewBrightness,CurrentScreensaver,NewScreensaver,CurrentStandbyTimeout,NewStandbyTimeout,CurrentToolbar,NewToolbar,CurrentAvFramework,NewAvFramework,CurrentIpId,NewIpId,CurrentControlSystemAddr,NewControlSystemAddr,Status,Detail,NeedsReboot,Timestamp |
                Export-Csv -NoTypeInformation -Path '{{EscapePowerShellString(resultsCsv)}}'
            $payload = [pscustomobject]@{
                Success = $true
                Count = $rows.Count
                Rows = @($rows | Select-Object IP,Model,CurrentHostname,NewHostname,SupportsNetwork,SupportsIpTable,HasWifi,SupportsDisplaySettings,SupportsToolbarSettings,SupportsAvFrameworkSettings,IPMode,CurrentIP,NewIP,CurrentSubnet,SubnetMask,CurrentGateway,Gateway,CurrentDns1,PrimaryDns,CurrentDns2,SecondaryDns,DisableWifi,CurrentAutoBrightness,NewAutoBrightness,CurrentBrightness,NewBrightness,CurrentScreensaver,NewScreensaver,CurrentStandbyTimeout,NewStandbyTimeout,CurrentToolbar,NewToolbar,CurrentAvFramework,NewAvFramework,CurrentIpId,NewIpId,CurrentControlSystemAddr,NewControlSystemAddr,Status,Detail,NeedsReboot,Timestamp)
                AvRows = @($avRows)
                MulticastRows = @($multicastRows)
                ControlSubnetRows = @($controlSubnetRows)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 8
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            progress?.Report($"Fetching per-device state for {cleanIps.Length} device(s)...");
            var json = await RunJsonScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<PerDeviceResultDto>(json, JsonOptions);
            return ToPerDeviceStateResult(result);
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<PerDeviceStateResult> ApplyPerDeviceChangesAsync(
        IEnumerable<PerDeviceDeviceRow> rows,
        IEnumerable<PerDeviceAvRow> avRows,
        IEnumerable<PerDeviceMulticastRow> multicastRows,
        IEnumerable<PerDeviceControlSubnetRow> controlSubnetRows,
        string? credUsername,
        string? credPassword,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var cleanRows = rows
            .Where(row => !string.IsNullOrWhiteSpace(row.IP))
            .Select(row => new
            {
                row.IP,
                row.Model,
                row.CurrentHostname,
                row.NewHostname,
                row.SupportsNetwork,
                row.SupportsIpTable,
                row.HasWifi,
                row.SupportsDisplaySettings,
                row.SupportsToolbarSettings,
                row.SupportsAvFrameworkSettings,
                row.CurrentIPMode,
                row.IPMode,
                row.CurrentIP,
                row.NewIP,
                row.CurrentSubnet,
                row.SubnetMask,
                row.CurrentGateway,
                row.Gateway,
                row.CurrentDns1,
                row.PrimaryDns,
                row.CurrentDns2,
                row.SecondaryDns,
                row.DisableWifi,
                row.CurrentAutoBrightness,
                row.NewAutoBrightness,
                row.CurrentBrightness,
                row.NewBrightness,
                row.CurrentScreensaver,
                row.NewScreensaver,
                row.CurrentStandbyTimeout,
                row.NewStandbyTimeout,
                row.CurrentToolbar,
                row.NewToolbar,
                row.CurrentAvFramework,
                row.NewAvFramework,
                row.CurrentIpId,
                row.NewIpId,
                row.CurrentControlSystemAddr,
                row.NewControlSystemAddr,
                row.Status,
                row.Detail,
                row.NeedsReboot,
                row.Timestamp
            })
            .ToArray();
        var cleanAvRows = avRows
            .Where(row => !string.IsNullOrWhiteSpace(row.IP))
            .Select(row => new
            {
                row.IP, row.Model, row.Hostname, row.RowKind, row.PortLabel, row.PortType,
                row.InputIndex, row.OutputIndex,
                row.SupportsEdidEdit, row.SupportsInputHdcp,
                row.CurrentEdid, row.NewEdidName,
                EdidNameOptions = row.EdidNameOptions.ToArray(),
                row.CurrentInputHdcp, row.NewInputHdcp,
                row.SupportsOutputHdcp, row.SupportsOutputResolution,
                row.CurrentOutputHdcp, row.NewOutputHdcp,
                row.CurrentOutputResolution, row.NewOutputResolution,
                OutputResolutionOptions = row.OutputResolutionOptions.ToArray(),
                row.SupportsAvRouting, row.CurrentAutoInputRouting, row.NewAutoInputRouting
            })
            .ToArray();
        var cleanMulticastRows = multicastRows
            .Where(row => !string.IsNullOrWhiteSpace(row.IP))
            .Select(row => new
            {
                row.IP,
                row.Model,
                row.Hostname,
                row.Direction,
                row.CurrentDeviceMode,
                row.DeviceMode,
                row.SupportsModeChange,
                row.StreamIndex,
                row.CurrentMulticastAddress,
                row.NewMulticastAddress,
                row.SupportsAvMulticast,
                DeviceModeOptions = row.DeviceModeOptions.ToArray()
            })
            .ToArray();
        var cleanControlSubnetRows = controlSubnetRows
            .Where(row => !string.IsNullOrWhiteSpace(row.IP))
            .Select(row => new
            {
                row.IP,
                row.Model,
                row.Hostname,
                row.SupportsControlSubnet,
                row.SupportsRouter,
                row.SupportsIgmpVersion,
                row.SupportsIgmpProxy,
                row.CurrentEnabled,
                row.NewEnabled,
                row.CurrentDhcp,
                row.IPMode,
                row.CurrentIPAddress,
                row.NewIPAddress,
                row.CurrentSubnetMask,
                row.NewSubnetMask,
                row.CurrentGateway,
                row.NewGateway,
                row.CurrentIgmpVersion,
                row.NewIgmpVersion,
                row.CurrentRouterAutomaticMode,
                row.NewRouterAutomaticMode,
                row.CurrentRouterPrefix,
                row.NewRouterPrefix,
                row.CurrentRouterOnlineDelay,
                row.NewRouterOnlineDelay,
                row.CurrentRouterIsolationMode,
                row.NewRouterIsolationMode,
                row.CurrentIgmpProxy,
                row.NewIgmpProxy,
                row.IgmpProxyPropertyName
            })
            .ToArray();

        if (cleanRows.Length == 0)
        {
            return EmptyPerDeviceStateResult;
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var rowsFile = Path.Combine(tempDir, "perdevice-rows.json");
        var avRowsFile = Path.Combine(tempDir, "perdevice-av-rows.json");
        var multicastRowsFile = Path.Combine(tempDir, "perdevice-multicast-rows.json");
        var controlSubnetRowsFile = Path.Combine(tempDir, "perdevice-control-subnet-rows.json");
        var credBlock = BuildCredentialBlock(credUsername, credPassword);
        var resultsCsv = Path.Combine(_dataRoot, "crestron-perdevice.csv");
        await File.WriteAllTextAsync(rowsFile, JsonSerializer.Serialize(cleanRows), cancellationToken).ConfigureAwait(false);
        await File.WriteAllTextAsync(avRowsFile, JsonSerializer.Serialize(cleanAvRows), cancellationToken).ConfigureAwait(false);
        await File.WriteAllTextAsync(multicastRowsFile, JsonSerializer.Serialize(cleanMulticastRows), cancellationToken).ConfigureAwait(false);
        await File.WriteAllTextAsync(controlSubnetRowsFile, JsonSerializer.Serialize(cleanControlSubnetRows), cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            Import-Module '{{EscapePowerShellString(_moduleManifest)}}' -Force
            {{credBlock}}
            $rowsIn = @(Get-Content '{{EscapePowerShellString(rowsFile)}}' -Raw | ConvertFrom-Json)
            $avRowsIn = @(Get-Content '{{EscapePowerShellString(avRowsFile)}}' -Raw | ConvertFrom-Json)
            $multicastRowsIn = @(Get-Content '{{EscapePowerShellString(multicastRowsFile)}}' -Raw | ConvertFrom-Json)
            $controlSubnetRowsIn = @(Get-Content '{{EscapePowerShellString(controlSubnetRowsFile)}}' -Raw | ConvertFrom-Json)
            $manifest = '{{EscapePowerShellString(_moduleManifest)}}'

            function Test-CabsValue($Value) {
                if ($null -eq $Value) { return $false }
                $text = "$Value".Trim()
                return -not [string]::IsNullOrWhiteSpace($text) -and $text -notin @('N/A','Keep')
            }

            function Convert-CabsToggle($Value) {
                if (-not (Test-CabsValue $Value)) { return $null }
                switch -Regex ("$Value") {
                    '^(?i)(enabled|enable|true|on|yes)$' { return $true }
                    '^(?i)(disabled|disable|false|off|no)$' { return $false }
                    default { return $null }
                }
            }

            function Test-CabsChanged($NewValue, $CurrentValue) {
                if (-not (Test-CabsValue $NewValue)) { return $false }
                return "$NewValue".Trim() -ne "$CurrentValue".Trim()
            }

            function Test-CabsNeedsReboot($result) {
                if ($null -eq $result) { return $false }
                if ($result.PSObject.Properties.Name -contains 'NeedsReboot' -and [bool]$result.NeedsReboot) { return $true }
                foreach ($section in @($result.SectionResults)) {
                    if ($section.StatusId -eq 1 -or "$($section.StatusInfo)" -match '(?i)reboot|restart|power cycle') { return $true }
                }
                return $false
            }

            $outRows = @($rowsIn | ForEach-Object -ThrottleLimit 8 -Parallel {
                $row = $_
                try {
                    Import-Module $using:manifest -Force -ErrorAction Stop
                    function Test-CabsValue($Value) {
                        if ($null -eq $Value) { return $false }
                        $text = "$Value".Trim()
                        return -not [string]::IsNullOrWhiteSpace($text) -and $text -notin @('N/A','Keep')
                    }
                    function Convert-CabsToggle($Value) {
                        if (-not (Test-CabsValue $Value)) { return $null }
                        switch -Regex ("$Value") {
                            '^(?i)(enabled|enable|true|on|yes)$' { return $true }
                            '^(?i)(disabled|disable|false|off|no)$' { return $false }
                            default { return $null }
                        }
                    }
                    function Test-CabsChanged($NewValue, $CurrentValue) {
                        if (-not (Test-CabsValue $NewValue)) { return $false }
                        return "$NewValue".Trim() -ne "$CurrentValue".Trim()
                    }
                    function Test-CabsNeedsReboot($result) {
                        if ($null -eq $result) { return $false }
                        if ($result.PSObject.Properties.Name -contains 'NeedsReboot' -and [bool]$result.NeedsReboot) { return $true }
                        foreach ($section in @($result.SectionResults)) {
                            if ($section.StatusId -eq 1 -or "$($section.StatusInfo)" -match '(?i)reboot|restart|power cycle') { return $true }
                        }
                        return $false
                    }

                    $sec = ConvertTo-SecureString $using:userPass -AsPlainText -Force
                    $cred = [pscredential]::new($using:userName, $sec)
                    $sess = Connect-CrestronDevice -IP "$($row.IP)" -Credential $cred
                    $success = $true
                    $needsReboot = $false
                    $details = New-Object System.Collections.Generic.List[string]

                    try {
                        if ([bool]$row.SupportsNetwork -and (Test-CabsChanged $row.NewHostname $row.CurrentHostname)) {
                            $r = Set-CrestronHostname -Session $sess -Hostname "$($row.NewHostname)" -TimeoutSec 10
                            $success = $success -and [bool]$r.Success
                            if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                            if ([bool]$r.Success) { $needsReboot = $true }
                            $details.Add("Hostname=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                            if ([bool]$r.Success) { $row.CurrentHostname = "$($row.NewHostname)" }
                        }

                        $displayArgs = @{ Session = $sess }
                        $hasDisplay = $false
                        $auto = Convert-CabsToggle $row.NewAutoBrightness
                        if ([bool]$row.SupportsDisplaySettings -and $null -ne $auto -and (Test-CabsChanged $row.NewAutoBrightness $row.CurrentAutoBrightness)) {
                            $displayArgs.AutoBrightness = [bool]$auto
                            $hasDisplay = $true
                        }
                        if ([bool]$row.SupportsDisplaySettings -and (Test-CabsChanged $row.NewBrightness $row.CurrentBrightness)) {
                            $displayArgs.Brightness = [int]"$($row.NewBrightness)"
                            $hasDisplay = $true
                        }
                        $screen = Convert-CabsToggle $row.NewScreensaver
                        if ([bool]$row.SupportsDisplaySettings -and $null -ne $screen -and (Test-CabsChanged $row.NewScreensaver $row.CurrentScreensaver)) {
                            $displayArgs.ScreensaverEnabled = [bool]$screen
                            $hasDisplay = $true
                        }
                        if ([bool]$row.SupportsDisplaySettings -and (Test-CabsChanged $row.NewStandbyTimeout $row.CurrentStandbyTimeout)) {
                            $displayArgs.StandbyTimeout = [int]"$($row.NewStandbyTimeout)"
                            $hasDisplay = $true
                        }
                        $toolbar = Convert-CabsToggle $row.NewToolbar
                        if ([bool]$row.SupportsToolbarSettings -and $null -ne $toolbar -and (Test-CabsChanged $row.NewToolbar $row.CurrentToolbar)) {
                            $displayArgs.ToolbarEnabled = [bool]$toolbar
                            $hasDisplay = $true
                        }
                        if ($hasDisplay) {
                            $r = Set-CrestronDisplaySettings @displayArgs
                            $success = $success -and [bool]$r.Success
                            if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                            $details.Add("Display=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                        }

                        $avf = Convert-CabsToggle $row.NewAvFramework
                        if ([bool]$row.SupportsAvFrameworkSettings -and $null -ne $avf -and (Test-CabsChanged $row.NewAvFramework $row.CurrentAvFramework)) {
                            $r = Set-CrestronAvFrameworkSettings -Session $sess -Enabled ([bool]$avf)
                            $success = $success -and [bool]$r.Success
                            if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                            $details.Add("AVFramework=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                        }

                        $avDevRow = @($using:avRowsIn | Where-Object { "$($_.IP)" -eq "$($row.IP)" -and "$($_.RowKind)" -eq 'Input' -and [bool]$_.SupportsAvRouting }) | Select-Object -First 1
                        if ($avDevRow -and [bool]$avDevRow.SupportsAvRouting -and (Test-CabsChanged $avDevRow.NewAutoInputRouting $avDevRow.CurrentAutoInputRouting)) {
                            $air = Convert-CabsToggle $avDevRow.NewAutoInputRouting
                            if ($null -ne $air) {
                                $r = Set-CrestronAutoInputRouting -Session $sess -Enabled ([bool]$air)
                                $success = $success -and [bool]$r.Success
                                if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                                if ([bool]$r.Success) {
                                    $details.Add("AutoInputRouting=OK")
                                } else {
                                    $sidInfo = ($r.SectionResults | ForEach-Object { "$($_.Path):$($_.StatusId)" }) -join ','
                                    $httpStatus = "$($r.Status)"
                                    $details.Add("AutoInputRouting=Failed(HTTP=$httpStatus$(if($sidInfo){';'+$sidInfo}))")
                                }
                            }
                        }

                        foreach ($inputRow in @($using:avRowsIn | Where-Object { "$($_.IP)" -eq "$($row.IP)" -and "$($_.RowKind)" -eq 'Input' })) {
                            if ([bool]$inputRow.SupportsInputHdcp -and (Test-CabsChanged $inputRow.NewInputHdcp $inputRow.CurrentInputHdcp)) {
                                $r = Set-CrestronInputHdcp -Session $sess -Mode "$($inputRow.NewInputHdcp)" -InputIndex ([int]$inputRow.InputIndex)
                                $success = $success -and [bool]$r.Success
                                if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                                $details.Add("Input $($inputRow.InputIndex) HDCP=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                                if ([bool]$r.Success) { $inputRow.CurrentInputHdcp = "$($inputRow.NewInputHdcp)" }
                            }

                            if ([bool]$inputRow.SupportsEdidEdit -and (Test-CabsChanged $inputRow.NewEdidName $inputRow.CurrentEdid)) {
                                $r = Set-CrestronInputEdid -Session $sess -EdidName "$($inputRow.NewEdidName)" -EdidType 'System' -InputIndex ([int]$inputRow.InputIndex)
                                $success = $success -and [bool]$r.Success
                                if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                                $details.Add("Input $($inputRow.InputIndex) EDID=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                                if ([bool]$r.Success) { $inputRow.CurrentEdid = "$($inputRow.NewEdidName)" }
                            }
                        }

                        foreach ($outputRow in @($using:avRowsIn | Where-Object { "$($_.IP)" -eq "$($row.IP)" -and "$($_.RowKind)" -eq 'Output' })) {
                            if ([bool]$outputRow.SupportsOutputHdcp -and (Test-CabsChanged $outputRow.NewOutputHdcp $outputRow.CurrentOutputHdcp)) {
                                $r = Set-CrestronOutputHdcp -Session $sess -Mode "$($outputRow.NewOutputHdcp)" -OutputIndex ([int]$outputRow.OutputIndex)
                                $success = $success -and [bool]$r.Success
                                if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                                $details.Add("Output $($outputRow.OutputIndex) HDCP=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                                if ([bool]$r.Success) { $outputRow.CurrentOutputHdcp = "$($outputRow.NewOutputHdcp)" }
                            }

                            if ([bool]$outputRow.SupportsOutputResolution -and (Test-CabsChanged $outputRow.NewOutputResolution $outputRow.CurrentOutputResolution)) {
                                $r = Set-CrestronOutputResolution -Session $sess -Resolution "$($outputRow.NewOutputResolution)" -OutputIndex ([int]$outputRow.OutputIndex)
                                $success = $success -and [bool]$r.Success
                                if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                                $details.Add("Output $($outputRow.OutputIndex) Resolution=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                                if ([bool]$r.Success) { $outputRow.CurrentOutputResolution = "$($outputRow.NewOutputResolution)" }
                            }
                        }

                        foreach ($mcRow in @($using:multicastRowsIn | Where-Object { "$($_.IP)" -eq "$($row.IP)" })) {
                            if (($mcRow.DeviceMode -in @('Transmitter','Receiver')) -and "$($mcRow.DeviceMode)" -ne "$($mcRow.CurrentDeviceMode)") {
                                if (-not [bool]$mcRow.SupportsModeChange) {
                                    $success = $false
                                    $details.Add("DeviceMode=skipped; unsupported")
                                }
                                else {
                                    $r = Set-CrestronDeviceMode -Session $sess -Mode "$($mcRow.DeviceMode)"
                                    $success = $success -and [bool]$r.Success
                                    if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                                    $details.Add("DeviceMode=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                                    if ([bool]$r.Success) { $mcRow.CurrentDeviceMode = "$($mcRow.DeviceMode)" }
                                }
                            }

                            if ([bool]$mcRow.SupportsAvMulticast -and (Test-CabsChanged $mcRow.NewMulticastAddress $mcRow.CurrentMulticastAddress)) {
                                $modeForMulticast = "$($mcRow.DeviceMode)"
                                if ($modeForMulticast -notin @('Transmitter','Receiver')) {
                                    $modeForMulticast = "$($mcRow.CurrentDeviceMode)"
                                }

                                $direction = switch ($modeForMulticast) {
                                    'Transmitter' { 'Transmit'; break }
                                    'Receiver' { 'Receive'; break }
                                    default { '' }
                                }

                                if ([string]::IsNullOrWhiteSpace($direction)) {
                                    $success = $false
                                    $details.Add('Multicast=skipped; TX/RX unavailable')
                                }
                                else {
                                    $streamIndex = if ($null -ne $mcRow.StreamIndex) { [int]$mcRow.StreamIndex } else { 0 }
                                    $r = Set-CrestronMulticastAddress -Session $sess -Direction $direction -MulticastAddress "$($mcRow.NewMulticastAddress)" -StreamIndex $streamIndex
                                    $success = $success -and [bool]$r.Success
                                    if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                                    $details.Add("Multicast=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                                    if ([bool]$r.Success) { $mcRow.CurrentMulticastAddress = "$($mcRow.NewMulticastAddress)" }
                                }
                            }
                        }

                        foreach ($controlRow in @($using:controlSubnetRowsIn | Where-Object { "$($_.IP)" -eq "$($row.IP)" })) {
                            try {
                                if (-not [bool]$controlRow.SupportsControlSubnet) {
                                    continue
                                }

                                $controlArgs = @{ Session = $sess }

                                $enabled = Convert-CabsToggle $controlRow.NewEnabled
                                if ($null -ne $enabled -and (Test-CabsChanged $controlRow.NewEnabled $controlRow.CurrentEnabled)) {
                                    $controlArgs.Enabled = [bool]$enabled
                                }

                                $currentControlMode = if ($null -eq $controlRow.CurrentDhcp) {
                                    'N/A'
                                }
                                elseif ([bool]$controlRow.CurrentDhcp) {
                                    'DHCP'
                                }
                                else {
                                    'Static'
                                }

                                $ipModeChanged = "$($controlRow.IPMode)" -in @('DHCP','Static') -and "$($controlRow.IPMode)" -ne $currentControlMode
                                $ipValueChanged =
                                    (Test-CabsChanged $controlRow.NewIPAddress $controlRow.CurrentIPAddress) -or
                                    (Test-CabsChanged $controlRow.NewSubnetMask $controlRow.CurrentSubnetMask) -or
                                    (Test-CabsChanged $controlRow.NewGateway $controlRow.CurrentGateway)

                                if ($ipModeChanged -or $ipValueChanged) {
                                    $controlArgs.IPMode = "$($controlRow.IPMode)"

                                    if ("$($controlRow.IPMode)" -eq 'Static') {
                                        $controlArgs.IPAddress = "$($controlRow.NewIPAddress)"
                                        $controlArgs.SubnetMask = "$($controlRow.NewSubnetMask)"
                                        $controlArgs.Gateway = "$($controlRow.NewGateway)"
                                    }
                                }

                                if ([bool]$controlRow.SupportsIgmpVersion -and "$($controlRow.NewIgmpVersion)" -in @('V2','V3') -and (Test-CabsChanged $controlRow.NewIgmpVersion $controlRow.CurrentIgmpVersion)) {
                                    $controlArgs.IgmpVersion = "$($controlRow.NewIgmpVersion)"
                                }

                                $routerAuto = Convert-CabsToggle $controlRow.NewRouterAutomaticMode
                                if ([bool]$controlRow.SupportsRouter -and $null -ne $routerAuto -and (Test-CabsChanged $controlRow.NewRouterAutomaticMode $controlRow.CurrentRouterAutomaticMode)) {
                                    $controlArgs.RouterAutomaticMode = [bool]$routerAuto
                                }

                                if ([bool]$controlRow.SupportsRouter -and (Test-CabsChanged $controlRow.NewRouterPrefix $controlRow.CurrentRouterPrefix)) {
                                    $controlArgs.RouterPrefix = "$($controlRow.NewRouterPrefix)"
                                }

                                if ([bool]$controlRow.SupportsRouter -and (Test-CabsChanged $controlRow.NewRouterOnlineDelay $controlRow.CurrentRouterOnlineDelay)) {
                                    $controlArgs.RouterOnlineDelay = [int]"$($controlRow.NewRouterOnlineDelay)"
                                }

                                $routerIsolation = Convert-CabsToggle $controlRow.NewRouterIsolationMode
                                if ([bool]$controlRow.SupportsRouter -and $null -ne $routerIsolation -and (Test-CabsChanged $controlRow.NewRouterIsolationMode $controlRow.CurrentRouterIsolationMode)) {
                                    $controlArgs.RouterIsolationMode = [bool]$routerIsolation
                                }

                                $igmpProxy = Convert-CabsToggle $controlRow.NewIgmpProxy
                                if ([bool]$controlRow.SupportsIgmpProxy -and $null -ne $igmpProxy -and (Test-CabsChanged $controlRow.NewIgmpProxy $controlRow.CurrentIgmpProxy)) {
                                    $controlArgs.IgmpProxyEnabled = [bool]$igmpProxy
                                    $controlArgs.IgmpProxyPropertyName = "$($controlRow.IgmpProxyPropertyName)"
                                    $controlArgs.Credential = $cred
                                }

                                if ($controlArgs.Count -gt 1) {
                                    $r = Set-CrestronControlSubnetSettings @controlArgs
                                    $success = $success -and [bool]$r.Success
                                    if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                                    $details.Add("ControlSubnet=$(if([bool]$r.Success){'OK'}else{'Failed'})")

                                    if ([bool]$r.Success) {
                                        if ($controlArgs.ContainsKey('Enabled')) { $controlRow.CurrentEnabled = "$($controlRow.NewEnabled)" }
                                        if ($controlArgs.ContainsKey('IPMode')) {
                                            $controlRow.CurrentDhcp = ("$($controlRow.IPMode)" -eq 'DHCP')
                                            if ("$($controlRow.IPMode)" -eq 'Static') {
                                                $controlRow.CurrentIPAddress = "$($controlRow.NewIPAddress)"
                                                $controlRow.CurrentSubnetMask = "$($controlRow.NewSubnetMask)"
                                                $controlRow.CurrentGateway = "$($controlRow.NewGateway)"
                                            }
                                        }
                                        if ($controlArgs.ContainsKey('IgmpVersion')) { $controlRow.CurrentIgmpVersion = "$($controlRow.NewIgmpVersion)" }
                                        if ($controlArgs.ContainsKey('RouterAutomaticMode')) { $controlRow.CurrentRouterAutomaticMode = "$($controlRow.NewRouterAutomaticMode)" }
                                        if ($controlArgs.ContainsKey('RouterPrefix')) { $controlRow.CurrentRouterPrefix = "$($controlRow.NewRouterPrefix)" }
                                        if ($controlArgs.ContainsKey('RouterOnlineDelay')) { $controlRow.CurrentRouterOnlineDelay = "$($controlRow.NewRouterOnlineDelay)" }
                                        if ($controlArgs.ContainsKey('RouterIsolationMode')) { $controlRow.CurrentRouterIsolationMode = "$($controlRow.NewRouterIsolationMode)" }
                                        if ($controlArgs.ContainsKey('IgmpProxyEnabled')) { $controlRow.CurrentIgmpProxy = "$($controlRow.NewIgmpProxy)" }
                                    }
                                }
                            }
                            catch {
                                $success = $false
                                $details.Add("ControlSubnet=ERR: $($_.Exception.Message)")
                            }
                        }

                        if ([bool]$row.SupportsIpTable -and
                            ((Test-CabsChanged $row.NewIpId $row.CurrentIpId) -or (Test-CabsChanged $row.NewControlSystemAddr $row.CurrentControlSystemAddr)) -and
                            (Test-CabsValue $row.NewIpId) -and (Test-CabsValue $row.NewControlSystemAddr)) {
                            $r = Set-CrestronIpTable -Session $sess -IpId "$($row.NewIpId)" -ControlSystemAddress "$($row.NewControlSystemAddr)"
                            $success = $success -and [bool]$r.Success
                            if (Test-CabsNeedsReboot $r) { $needsReboot = $true }
                            $details.Add("IpTable=$(if([bool]$r.Success){'OK'}else{'Failed'})")
                        }

                        $networkChanged = [bool]$row.SupportsNetwork -and (
                            (Test-CabsValue $row.IPMode -and "$($row.IPMode)" -in @('DHCP','Static') -and (
                                ("$($row.IPMode)" -ne "$($row.CurrentIPMode)") -or
                                (Test-CabsChanged $row.NewIP $row.CurrentIP) -or
                                (Test-CabsChanged $row.SubnetMask $row.CurrentSubnet) -or
                                (Test-CabsChanged $row.Gateway $row.CurrentGateway) -or
                                (Test-CabsChanged $row.PrimaryDns $row.CurrentDns1) -or
                                (Test-CabsChanged $row.SecondaryDns $row.CurrentDns2)
                            )) -or
                            ([bool]$row.HasWifi -and [bool]$row.DisableWifi)
                        )

                        if ($networkChanged) {
                            $netArgs = @{
                                Session = $sess
                                IPMode = "$($row.IPMode)"
                            }
                            if ("$($row.IPMode)" -eq 'Static') {
                                $netArgs.NewIP = "$($row.NewIP)"
                                $netArgs.SubnetMask = "$($row.SubnetMask)"
                                $netArgs.Gateway = "$($row.Gateway)"
                            }
                            if (Test-CabsValue $row.PrimaryDns) { $netArgs.PrimaryDns = "$($row.PrimaryDns)" }
                            if (Test-CabsValue $row.SecondaryDns) { $netArgs.SecondaryDns = "$($row.SecondaryDns)" }
                            if ([bool]$row.HasWifi -and [bool]$row.DisableWifi) { $netArgs.DisableWifi = $true }
                            $netArgs.TimeoutSec = 8
                            $r = Set-CrestronNetwork @netArgs
                            $success = $success -and [bool]$r.Success
                            $networkDetail = if ([bool]$r.Success) {
                                if ($r.PSObject.Properties.Name -contains 'ConnectionLostAccepted' -and [bool]$r.ConnectionLostAccepted) {
                                    'OK(connection moved)'
                                }
                                else {
                                    'OK'
                                }
                            }
                            else {
                                $statusText = "$($r.Status)"
                                $writePathText = "$($r.WritePath)"
                                if ([string]::IsNullOrWhiteSpace($statusText)) { $statusText = 'unknown' }
                                if ([string]::IsNullOrWhiteSpace($writePathText)) { $writePathText = 'unknown' }
                                "Failed(HTTP=$statusText; Path=$writePathText)"
                            }
                            $details.Add("Network=$networkDetail")
                        }

                        if ($details.Count -eq 0) {
                            $details.Add('No changes')
                        }

                        $row.Status = if ($success) { 'OK' } else { 'Failed' }
                        $row.Detail = ($details -join '; ')
                        $row.NeedsReboot = $needsReboot
                        $row.Timestamp = (Get-Date).ToString('s')
                        $row
                    }
                    finally {
                        Disconnect-CrestronDevice -Session $sess -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    $row.Status = 'Error'
                    $row.Detail = "ERROR: $($_.Exception.Message)"
                    $row.NeedsReboot = $false
                    $row.Timestamp = (Get-Date).ToString('s')
                    $row
                }
            })

            $outRows | Select-Object IP,Model,CurrentHostname,NewHostname,SupportsNetwork,SupportsIpTable,HasWifi,SupportsDisplaySettings,SupportsToolbarSettings,SupportsAvFrameworkSettings,IPMode,CurrentIP,NewIP,CurrentSubnet,SubnetMask,CurrentGateway,Gateway,CurrentDns1,PrimaryDns,CurrentDns2,SecondaryDns,DisableWifi,CurrentAutoBrightness,NewAutoBrightness,CurrentBrightness,NewBrightness,CurrentScreensaver,NewScreensaver,CurrentStandbyTimeout,NewStandbyTimeout,CurrentToolbar,NewToolbar,CurrentAvFramework,NewAvFramework,CurrentIpId,NewIpId,CurrentControlSystemAddr,NewControlSystemAddr,Status,Detail,NeedsReboot,Timestamp |
                Export-Csv -NoTypeInformation -Path '{{EscapePowerShellString(resultsCsv)}}'
            $payload = [pscustomobject]@{
                Success = $true
                Count = $outRows.Count
                Rows = @($outRows | Select-Object IP,Model,CurrentHostname,NewHostname,SupportsNetwork,SupportsIpTable,HasWifi,SupportsDisplaySettings,SupportsToolbarSettings,SupportsAvFrameworkSettings,IPMode,CurrentIP,NewIP,CurrentSubnet,SubnetMask,CurrentGateway,Gateway,CurrentDns1,PrimaryDns,CurrentDns2,SecondaryDns,DisableWifi,CurrentAutoBrightness,NewAutoBrightness,CurrentBrightness,NewBrightness,CurrentScreensaver,NewScreensaver,CurrentStandbyTimeout,NewStandbyTimeout,CurrentToolbar,NewToolbar,CurrentAvFramework,NewAvFramework,CurrentIpId,NewIpId,CurrentControlSystemAddr,NewControlSystemAddr,Status,Detail,NeedsReboot,Timestamp)
                AvRows = @($avRowsIn)
                MulticastRows = @($multicastRowsIn)
                ControlSubnetRows = @($controlSubnetRowsIn)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 8
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            progress?.Report($"Applying per-device changes to {cleanRows.Length} device(s)...");
            var json = await RunJsonScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<PerDeviceResultDto>(json, JsonOptions);
            return ToPerDeviceStateResult(result);
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<IReadOnlyList<RebootDeviceResult>> RebootDevicesAsync(
        IEnumerable<string> ips,
        string? credUsername,
        string? credPassword,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var cleanIps = ips
            .Select(ip => ip.Trim())
            .Where(ip => !string.IsNullOrWhiteSpace(ip))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (cleanIps.Length == 0)
        {
            return Array.Empty<RebootDeviceResult>();
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var ipFile = Path.Combine(tempDir, "reboot-ips.txt");
        var credBlock = BuildCredentialBlock(credUsername, credPassword);
        await File.WriteAllLinesAsync(ipFile, cleanIps, cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            Import-Module '{{EscapePowerShellString(_moduleManifest)}}' -Force
            {{credBlock}}
            $manifest = '{{EscapePowerShellString(_moduleManifest)}}'
            $ipsIn = @(Get-Content '{{EscapePowerShellString(ipFile)}}' | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)

            $rows = @($ipsIn | ForEach-Object -ThrottleLimit 8 -Parallel {
                $ip = "$_".Trim()
                try {
                    Import-Module $using:manifest -Force -ErrorAction Stop
                    $sec = ConvertTo-SecureString $using:userPass -AsPlainText -Force
                    $cred = [pscredential]::new($using:userName, $sec)
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred -TimeoutSec 5

                    try {
                        $result = Restart-CrestronDevice -Session $sess -TimeoutSec 5
                        [pscustomobject]@{
                            IP = $ip
                            Status = "$($result.Status)"
                            Success = [bool]$result.Success
                            Response = "$($result.Response)"
                            Timestamp = if ($result.Timestamp) { "$($result.Timestamp)" } else { (Get-Date).ToString('s') }
                        }
                    }
                    finally {
                        Disconnect-CrestronDevice -Session $sess -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    [pscustomobject]@{
                        IP = $ip
                        Status = 'Error'
                        Success = $false
                        Response = $_.Exception.Message
                        Timestamp = (Get-Date).ToString('s')
                    }
                }
            })

            $payload = [pscustomobject]@{
                Success = $true
                Count = $rows.Count
                Rows = @($rows | Select-Object IP,Status,Success,Response,Timestamp)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 5
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            progress?.Report($"Sending reboot commands to {cleanIps.Length} device(s)...");
            var json = await RunJsonScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<RebootResultDto>(json, JsonOptions);
            return result?.Rows?
                .Where(row => row is not null)
                .Select(row => new RebootDeviceResult(
                    row.IP ?? "",
                    row.Status ?? "",
                    row.Success == true,
                    row.Response ?? "",
                    row.Timestamp ?? ""))
                .ToArray() ?? Array.Empty<RebootDeviceResult>();
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<string> ProtectSettingsPasswordAsync(string password, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(password))
        {
            return "";
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var passwordFile = Path.Combine(tempDir, "settings-password.txt");
        await File.WriteAllTextAsync(passwordFile, password, cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            $plain = Get-Content '{{EscapePowerShellString(passwordFile)}}' -Raw
            $secure = ConvertTo-SecureString $plain -AsPlainText -Force
            $payload = [pscustomobject]@{
                ProtectedPassword = (ConvertFrom-SecureString $secure)
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 3
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            var json = await RunJsonScriptAsync(script, progress: null, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<ProtectedPasswordDto>(json, JsonOptions);
            return result?.ProtectedPassword ?? "";
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    public async Task<string> UnprotectSettingsPasswordAsync(string protectedPassword, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(protectedPassword))
        {
            return "";
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        var passwordFile = Path.Combine(tempDir, "settings-password-protected.txt");
        await File.WriteAllTextAsync(passwordFile, protectedPassword, cancellationToken).ConfigureAwait(false);

        var script = $$"""
            $ErrorActionPreference = 'Stop'
            $protected = Get-Content '{{EscapePowerShellString(passwordFile)}}' -Raw
            $secure = ConvertTo-SecureString $protected
            $credential = [pscredential]::new('__settings__', $secure)
            $payload = [pscustomobject]@{
                Password = $credential.GetNetworkCredential().Password
            }
            Write-Output '{{JsonStart}}'
            $payload | ConvertTo-Json -Depth 3
            Write-Output '{{JsonEnd}}'
            """;

        try
        {
            var json = await RunJsonScriptAsync(script, progress: null, cancellationToken).ConfigureAwait(false);
            var result = JsonSerializer.Deserialize<PlainPasswordDto>(json, JsonOptions);
            return result?.Password ?? "";
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    private async Task<string> RunJsonScriptAsync(
        string script,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var output = await RunScriptAsync(script, progress, cancellationToken).ConfigureAwait(false);
        var match = Regex.Match(
            output,
            $"{Regex.Escape(JsonStart)}\\s*(?<json>.*?)\\s*{Regex.Escape(JsonEnd)}",
            RegexOptions.Singleline);

        if (!match.Success)
        {
            throw new InvalidOperationException("PowerShell backend did not return a JSON payload." + Environment.NewLine + output);
        }

        return match.Groups["json"].Value.Trim();
    }

    private async Task<string> RunScriptAsync(
        string script,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(_moduleManifest))
        {
            throw new FileNotFoundException(
                $"CrestronAdminBootstrap module manifest was not found.\n\nExpected: {_moduleManifest}\n\nMake sure the 'src' folder is in the same directory as CrestronBootstrap.exe.",
                _moduleManifest);
        }

        var scriptPath = Path.Combine(Path.GetTempPath(), $"cabs-desktop-{Guid.NewGuid():N}.ps1");
        await File.WriteAllTextAsync(scriptPath, script, Encoding.UTF8, cancellationToken).ConfigureAwait(false);

        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = _pwshPath,
                WorkingDirectory = _repoRoot,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            process.StartInfo.ArgumentList.Add("-NoProfile");
            process.StartInfo.ArgumentList.Add("-ExecutionPolicy");
            process.StartInfo.ArgumentList.Add("Bypass");
            process.StartInfo.ArgumentList.Add("-File");
            process.StartInfo.ArgumentList.Add(scriptPath);

            var output = new StringBuilder();
            var error = new StringBuilder();

            process.OutputDataReceived += (_, e) =>
            {
                if (e.Data is null)
                {
                    return;
                }

                lock (output)
                {
                    output.AppendLine(e.Data);
                }

                if (!e.Data.Contains(JsonStart, StringComparison.Ordinal) &&
                    !e.Data.Contains(JsonEnd, StringComparison.Ordinal))
                {
                    progress?.Report(e.Data);
                }
            };

            process.ErrorDataReceived += (_, e) =>
            {
                if (e.Data is null)
                {
                    return;
                }

                lock (error)
                {
                    error.AppendLine(e.Data);
                }
            };

            try
            {
                if (!process.Start())
                {
                    throw new InvalidOperationException("PowerShell process did not start.");
                }
            }
            catch (Win32Exception ex) when (ex.NativeErrorCode is 2 or 3)
            {
                throw new FileNotFoundException(MissingPowerShellMessage(), _pwshPath, ex);
            }

            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            try
            {
                await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch
                {
                    // Best effort cancellation.
                }

                throw;
            }

            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException(error.Length > 0 ? error.ToString() : output.ToString());
            }

            return output.ToString();
        }
        finally
        {
            try
            {
                File.Delete(scriptPath);
            }
            catch
            {
                // Best effort cleanup.
            }
        }
    }

    private static string FindPowerShell()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "PowerShell", "7", "pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "PowerShell", "7", "pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "PowerShell", "7", "pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "PowerShell", "7", "pwsh.exe")
        };

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        var pathPowerShell = FindOnPath("pwsh.exe");
        if (pathPowerShell is not null)
        {
            return pathPowerShell;
        }

        throw new FileNotFoundException(MissingPowerShellMessage(), "pwsh.exe");
    }

    private static string? FindOnPath(string fileName)
    {
        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        foreach (var directory in path.Split(Path.PathSeparator))
        {
            var cleanDirectory = directory.Trim().Trim('"');
            if (string.IsNullOrWhiteSpace(cleanDirectory))
            {
                continue;
            }

            if (cleanDirectory.Contains(@"\Microsoft\WindowsApps", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var candidate = Path.Combine(cleanDirectory, fileName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private static string MissingPowerShellMessage()
    {
        return "PowerShell 7 (pwsh.exe) was not found. Install Crestron Admin Bootstrap with the Setup installer so it can add PowerShell 7, or install PowerShell 7 from https://aka.ms/powershell.";
    }

    private static string EscapePowerShellString(string value)
    {
        return value.Replace("'", "''", StringComparison.Ordinal);
    }

    private string BuildCredentialBlock(string? credUsername, string? credPassword)
    {
        if (!string.IsNullOrEmpty(credUsername) && !string.IsNullOrEmpty(credPassword))
        {
            return
                "$userName = '" + EscapePowerShellString(credUsername) + "'\n" +
                "            $userPass = '" + EscapePowerShellString(credPassword) + "'";
        }

        var sp = EscapePowerShellString(_settingsPath);
        return
            "$settingsPath = '" + sp + "'\n" +
            "            if (-not (Test-Path $settingsPath)) {\n" +
            "                throw 'Saved credentials were not found. Save credentials in the Settings tab first.'\n" +
            "            }\n" +
            "            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json\n" +
            "            if (-not $settings.DefaultUsername -or -not $settings.ProtectedDefaultPassword) {\n" +
            "                throw 'Saved credentials are incomplete. Save username/password in the Settings tab first.'\n" +
            "            }\n" +
            "            $secure = ConvertTo-SecureString $settings.ProtectedDefaultPassword\n" +
            "            $credential = [pscredential]::new([string]$settings.DefaultUsername, $secure)\n" +
            "            $userName = $credential.UserName\n" +
            "            $userPass = $credential.GetNetworkCredential().Password";
    }

    private static BlanketDeviceRow ToBlanketRow(BlanketRowDto row)
    {
        return new BlanketDeviceRow
        {
            Selected = true,
            IP = row.IP ?? "",
            Model = row.Model ?? "",
            Hostname = row.Hostname ?? "",
            CurrentDeviceMode = row.CurrentDeviceMode ?? "",
            AvApiFamily = row.AvApiFamily ?? "",
            AvApiVersion = row.AvApiVersion ?? "",
            SupportsAvSettings = row.SupportsAvSettings,
            SupportsGlobalEdid = row.SupportsGlobalEdid,
            EdidNames = row.EdidNames ?? "",
            SupportsNtp = row.SupportsNtp,
            SupportsCloud = row.SupportsCloud,
            SupportsFusion = row.SupportsFusion,
            SupportsAutoUpdate = row.SupportsAutoUpdate,
            SupportsDisplaySettings = row.SupportsDisplaySettings,
            SupportsToolbarSettings = row.SupportsToolbarSettings,
            SupportsAvFrameworkSettings = row.SupportsAvFrameworkSettings,
            CapabilitiesFetched = row.CapabilitiesFetched,
            Status = row.Status ?? "",
            Detail = row.Detail ?? "",
            NeedsReboot = row.NeedsReboot,
            Timestamp = row.Timestamp ?? ""
        };
    }

    private static PerDeviceDeviceRow ToPerDeviceRow(PerDeviceRowDto row)
    {
        return new PerDeviceDeviceRow
        {
            Selected = true,
            IP = row.IP ?? "",
            Model = row.Model ?? "",
            CurrentHostname = row.CurrentHostname ?? "",
            NewHostname = row.NewHostname ?? "N/A",
            SupportsNetwork = row.SupportsNetwork == true,
            SupportsIpTable = row.SupportsIpTable == true,
            HasWifi = row.HasWifi == true,
            SupportsDisplaySettings = row.SupportsDisplaySettings == true,
            SupportsToolbarSettings = row.SupportsToolbarSettings == true,
            SupportsAvFrameworkSettings = row.SupportsAvFrameworkSettings == true,
            CurrentIPMode = row.CurrentIPMode ?? "N/A",
            IPMode = row.IPMode ?? "N/A",
            CurrentIP = row.CurrentIP ?? "",
            NewIP = row.NewIP ?? "N/A",
            CurrentSubnet = row.CurrentSubnet ?? "",
            SubnetMask = row.SubnetMask ?? "N/A",
            CurrentGateway = row.CurrentGateway ?? "",
            Gateway = row.Gateway ?? "N/A",
            CurrentDns1 = row.CurrentDns1 ?? "",
            PrimaryDns = row.PrimaryDns ?? "N/A",
            CurrentDns2 = row.CurrentDns2 ?? "",
            SecondaryDns = row.SecondaryDns ?? "",
            DisableWifi = row.DisableWifi == true,
            CurrentAutoBrightness = row.CurrentAutoBrightness ?? "N/A",
            NewAutoBrightness = row.NewAutoBrightness ?? "N/A",
            CurrentBrightness = row.CurrentBrightness ?? "N/A",
            NewBrightness = row.NewBrightness ?? "N/A",
            CurrentScreensaver = row.CurrentScreensaver ?? "N/A",
            NewScreensaver = row.NewScreensaver ?? "N/A",
            CurrentStandbyTimeout = row.CurrentStandbyTimeout ?? "N/A",
            NewStandbyTimeout = row.NewStandbyTimeout ?? "N/A",
            CurrentToolbar = row.CurrentToolbar ?? "N/A",
            NewToolbar = row.NewToolbar ?? "N/A",
            CurrentAvFramework = row.CurrentAvFramework ?? "N/A",
            NewAvFramework = row.NewAvFramework ?? "N/A",
            CurrentIpId = row.CurrentIpId ?? "",
            NewIpId = row.NewIpId ?? "N/A",
            CurrentControlSystemAddr = row.CurrentControlSystemAddr ?? "",
            NewControlSystemAddr = row.NewControlSystemAddr ?? "N/A",
            Status = row.Status ?? "",
            Detail = row.Detail ?? "",
            NeedsReboot = row.NeedsReboot == true,
            Timestamp = row.Timestamp ?? ""
        };
    }

    private static PerDeviceStateResult ToPerDeviceStateResult(PerDeviceResultDto? result)
    {
        if (result is null)
        {
            return EmptyPerDeviceStateResult;
        }

        return new PerDeviceStateResult(
            result.Rows?.Where(row => row is not null).Select(ToPerDeviceRow).ToArray() ?? Array.Empty<PerDeviceDeviceRow>(),
            result.AvRows?.Where(row => row is not null).Select(ToPerDeviceAvRow).ToArray() ?? Array.Empty<PerDeviceAvRow>(),
            result.MulticastRows?.Where(row => row is not null).Select(ToPerDeviceMulticastRow).ToArray() ?? Array.Empty<PerDeviceMulticastRow>(),
            result.ControlSubnetRows?.Where(row => row is not null).Select(ToPerDeviceControlSubnetRow).ToArray() ?? Array.Empty<PerDeviceControlSubnetRow>());
    }

    private static PerDeviceAvRow ToPerDeviceAvRow(PerDeviceAvRowDto? row)
    {
        if (row is null) return new PerDeviceAvRow();

        var currentEdid = row.CurrentEdid ?? "N/A";
        var currentInputHdcp = row.CurrentInputHdcp ?? "N/A";
        var currentOutputHdcp = row.CurrentOutputHdcp ?? "N/A";
        var currentOutputResolution = row.CurrentOutputResolution ?? "N/A";
        var currentAutoInputRouting = row.CurrentAutoInputRouting ?? "N/A";

        var avRow = new PerDeviceAvRow
        {
            IP = row.IP ?? "",
            Model = row.Model ?? "",
            Hostname = row.Hostname ?? "",
            RowKind = row.RowKind ?? "",
            PortLabel = row.PortLabel ?? "",
            PortType = row.PortType ?? "",
            InputIndex = row.InputIndex ?? -1,
            OutputIndex = row.OutputIndex ?? -1,
            SupportsEdidEdit = row.SupportsEdidEdit == true,
            SupportsInputHdcp = row.SupportsInputHdcp == true,
            CurrentEdid = currentEdid,
            CurrentInputHdcp = currentInputHdcp,
            SupportsOutputHdcp = row.SupportsOutputHdcp == true,
            SupportsOutputResolution = row.SupportsOutputResolution == true,
            CurrentOutputHdcp = currentOutputHdcp,
            CurrentOutputResolution = currentOutputResolution,
            SupportsAvRouting = row.SupportsAvRouting == true,
            CurrentAutoInputRouting = currentAutoInputRouting,
            NewInputHdcp = row.NewInputHdcp ?? currentInputHdcp,
            NewOutputHdcp = row.NewOutputHdcp ?? currentOutputHdcp,
            NewOutputResolution = row.NewOutputResolution ?? currentOutputResolution,
            NewAutoInputRouting = row.NewAutoInputRouting ?? currentAutoInputRouting
        };

        var edidNew = row.NewEdidName ?? "";
        avRow.NewEdidName = string.IsNullOrWhiteSpace(edidNew) || string.Equals(edidNew, "N/A", StringComparison.OrdinalIgnoreCase)
            ? "" : edidNew;

        foreach (var option in NormalizeOptions(row.EdidNameOptions, currentEdid, avRow.NewEdidName))
            avRow.EdidNameOptions.Add(option);

        foreach (var option in NormalizeOptions(row.OutputResolutionOptions, currentOutputResolution, avRow.NewOutputResolution))
            avRow.OutputResolutionOptions.Add(option);

        return avRow;
    }

    private static PerDeviceMulticastRow ToPerDeviceMulticastRow(PerDeviceMulticastRowDto? row)
    {
        if (row is null)
        {
            return new PerDeviceMulticastRow();
        }

        var currentMode = row.CurrentDeviceMode ?? "N/A";
        var deviceMode = row.DeviceMode ?? currentMode;
        var currentMulticast = row.CurrentMulticastAddress ?? "N/A";
        var multicastRow = new PerDeviceMulticastRow
        {
            IP = row.IP ?? "",
            Model = row.Model ?? "",
            Hostname = row.Hostname ?? "",
            Direction = row.Direction ?? "",
            CurrentDeviceMode = currentMode,
            DeviceMode = deviceMode,
            SupportsModeChange = row.SupportsModeChange == true,
            StreamIndex = row.StreamIndex ?? 0,
            CurrentMulticastAddress = currentMulticast,
            NewMulticastAddress = row.NewMulticastAddress ?? currentMulticast,
            SupportsAvMulticast = row.SupportsAvMulticast == true
        };

        foreach (var option in NormalizeOptions(row.DeviceModeOptions, currentMode, deviceMode))
        {
            if (option is "Transmitter" or "Receiver")
            {
                multicastRow.DeviceModeOptions.Add(option);
            }
        }

        if (multicastRow.DeviceModeOptions.Count == 0 && deviceMode is "Transmitter" or "Receiver")
        {
            multicastRow.DeviceModeOptions.Add(deviceMode);
        }

        return multicastRow;
    }

    private static IEnumerable<string> NormalizeOptions(IEnumerable<string?>? options, params string?[] preferred)
    {
        return preferred
            .Concat(options ?? Array.Empty<string?>())
            .Select(option => (option ?? "").Trim())
            .Where(option => !string.IsNullOrWhiteSpace(option) && !string.Equals(option, "N/A", StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase);
    }

    private static PerDeviceControlSubnetRow ToPerDeviceControlSubnetRow(PerDeviceControlSubnetRowDto? row)
    {
        if (row is null)
        {
            return new PerDeviceControlSubnetRow();
        }

        return new PerDeviceControlSubnetRow
        {
            IP = row.IP ?? "",
            Model = row.Model ?? "",
            Hostname = row.Hostname ?? "",
            SupportsControlSubnet = row.SupportsControlSubnet == true,
            SupportsRouter = row.SupportsRouter == true,
            SupportsIgmpVersion = row.SupportsIgmpVersion == true,
            SupportsIgmpProxy = row.SupportsIgmpProxy == true,
            CurrentEnabled = row.CurrentEnabled ?? "N/A",
            NewEnabled = row.NewEnabled ?? row.CurrentEnabled ?? "N/A",
            CurrentDhcp = row.CurrentDhcp,
            IPMode = row.IPMode ?? CurrentControlSubnetMode(row.CurrentDhcp),
            CurrentIPAddress = row.CurrentIPAddress ?? "N/A",
            NewIPAddress = row.NewIPAddress ?? row.CurrentIPAddress ?? "N/A",
            CurrentSubnetMask = row.CurrentSubnetMask ?? "N/A",
            NewSubnetMask = row.NewSubnetMask ?? row.CurrentSubnetMask ?? "N/A",
            CurrentGateway = row.CurrentGateway ?? "N/A",
            NewGateway = row.NewGateway ?? row.CurrentGateway ?? "N/A",
            CurrentIgmpVersion = row.CurrentIgmpVersion ?? "N/A",
            NewIgmpVersion = row.NewIgmpVersion ?? row.CurrentIgmpVersion ?? "N/A",
            CurrentRouterAutomaticMode = row.CurrentRouterAutomaticMode ?? "N/A",
            NewRouterAutomaticMode = row.NewRouterAutomaticMode ?? row.CurrentRouterAutomaticMode ?? "N/A",
            CurrentRouterPrefix = row.CurrentRouterPrefix ?? "N/A",
            NewRouterPrefix = row.NewRouterPrefix ?? row.CurrentRouterPrefix ?? "N/A",
            CurrentRouterOnlineDelay = row.CurrentRouterOnlineDelay ?? "N/A",
            NewRouterOnlineDelay = row.NewRouterOnlineDelay ?? row.CurrentRouterOnlineDelay ?? "N/A",
            CurrentRouterIsolationMode = row.CurrentRouterIsolationMode ?? "N/A",
            NewRouterIsolationMode = row.NewRouterIsolationMode ?? row.CurrentRouterIsolationMode ?? "N/A",
            CurrentIgmpProxy = row.CurrentIgmpProxy ?? "N/A",
            NewIgmpProxy = row.NewIgmpProxy ?? row.CurrentIgmpProxy ?? "N/A",
            IgmpProxyPropertyName = row.IgmpProxyPropertyName ?? ""
        };
    }

    private static string CurrentControlSubnetMode(bool? currentDhcp)
    {
        if (currentDhcp is null)
        {
            return "N/A";
        }

        return currentDhcp.Value ? "DHCP" : "Static";
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private static readonly PerDeviceStateResult EmptyPerDeviceStateResult = new(
        Array.Empty<PerDeviceDeviceRow>(),
        Array.Empty<PerDeviceAvRow>(),
        Array.Empty<PerDeviceMulticastRow>(),
        Array.Empty<PerDeviceControlSubnetRow>());

    private sealed class ScanResultDto
    {
        public List<ScanDeviceDto>? Rows { get; set; }
    }

    private sealed class ScanDeviceDto
    {
        public string? IP { get; set; }
        public string? MatchedSig { get; set; }
        public string? ScannedAt { get; set; }
    }

    private sealed class ProvisionResultDto
    {
        public List<ProvisionDeviceDto>? Rows { get; set; }
    }

    private sealed class ProvisionDeviceDto
    {
        public string? IP { get; set; }
        public string? Status { get; set; }
        public bool? Success { get; set; }
        public string? Response { get; set; }
        public string? Timestamp { get; set; }
    }

    private sealed class BlanketResultDto
    {
        public List<BlanketRowDto>? Rows { get; set; }
    }

    private sealed class PerDeviceResultDto
    {
        public List<PerDeviceRowDto>? Rows { get; set; }
        public List<PerDeviceAvRowDto>? AvRows { get; set; }
        public List<PerDeviceMulticastRowDto>? MulticastRows { get; set; }
        public List<PerDeviceControlSubnetRowDto>? ControlSubnetRows { get; set; }
    }

    private sealed class RebootResultDto
    {
        public List<RebootRowDto>? Rows { get; set; }
    }

    private sealed class RebootRowDto
    {
        public string? IP { get; set; }
        public string? Status { get; set; }
        public bool? Success { get; set; }
        public string? Response { get; set; }
        public string? Timestamp { get; set; }
    }

    private sealed class ProtectedPasswordDto
    {
        public string? ProtectedPassword { get; set; }
    }

    private sealed class PlainPasswordDto
    {
        public string? Password { get; set; }
    }

    private sealed class BlanketRowDto
    {
        public string? IP { get; set; }
        public string? Model { get; set; }
        public string? Hostname { get; set; }
        public string? CurrentDeviceMode { get; set; }
        public string? AvApiFamily { get; set; }
        public string? AvApiVersion { get; set; }
        public bool SupportsAvSettings { get; set; }
        public bool SupportsGlobalEdid { get; set; }
        public string? EdidNames { get; set; }
        public bool SupportsNtp { get; set; }
        public bool SupportsCloud { get; set; }
        public bool SupportsFusion { get; set; }
        public bool SupportsAutoUpdate { get; set; }
        public bool SupportsDisplaySettings { get; set; }
        public bool SupportsToolbarSettings { get; set; }
        public bool SupportsAvFrameworkSettings { get; set; }
        public bool CapabilitiesFetched { get; set; }
        public string? Status { get; set; }
        public string? Detail { get; set; }
        public bool NeedsReboot { get; set; }
        public string? Timestamp { get; set; }
    }

    private sealed class PerDeviceRowDto
    {
        public string? IP { get; set; }
        public string? Model { get; set; }
        public string? CurrentHostname { get; set; }
        public string? NewHostname { get; set; }
        public bool? SupportsNetwork { get; set; }
        public bool? SupportsIpTable { get; set; }
        public bool? HasWifi { get; set; }
        public bool? SupportsDisplaySettings { get; set; }
        public bool? SupportsToolbarSettings { get; set; }
        public bool? SupportsAvFrameworkSettings { get; set; }
        public string? CurrentIPMode { get; set; }
        public string? IPMode { get; set; }
        public string? CurrentIP { get; set; }
        public string? NewIP { get; set; }
        public string? CurrentSubnet { get; set; }
        public string? SubnetMask { get; set; }
        public string? CurrentGateway { get; set; }
        public string? Gateway { get; set; }
        public string? CurrentDns1 { get; set; }
        public string? PrimaryDns { get; set; }
        public string? CurrentDns2 { get; set; }
        public string? SecondaryDns { get; set; }
        public bool? DisableWifi { get; set; }
        public string? CurrentAutoBrightness { get; set; }
        public string? NewAutoBrightness { get; set; }
        public string? CurrentBrightness { get; set; }
        public string? NewBrightness { get; set; }
        public string? CurrentScreensaver { get; set; }
        public string? NewScreensaver { get; set; }
        public string? CurrentStandbyTimeout { get; set; }
        public string? NewStandbyTimeout { get; set; }
        public string? CurrentToolbar { get; set; }
        public string? NewToolbar { get; set; }
        public string? CurrentAvFramework { get; set; }
        public string? NewAvFramework { get; set; }
        public string? CurrentIpId { get; set; }
        public string? NewIpId { get; set; }
        public string? CurrentControlSystemAddr { get; set; }
        public string? NewControlSystemAddr { get; set; }
        public string? Status { get; set; }
        public string? Detail { get; set; }
        public bool? NeedsReboot { get; set; }
        public string? Timestamp { get; set; }
    }

    private sealed class PerDeviceAvRowDto
    {
        public string? IP { get; set; }
        public string? Model { get; set; }
        public string? Hostname { get; set; }
        public string? RowKind { get; set; }
        public string? PortLabel { get; set; }
        public string? PortType { get; set; }
        public int? InputIndex { get; set; }
        public int? OutputIndex { get; set; }
        // Input
        public bool? SupportsEdidEdit { get; set; }
        public bool? SupportsInputHdcp { get; set; }
        public string? CurrentEdid { get; set; }
        public string? NewEdidName { get; set; }
        public List<string>? EdidNameOptions { get; set; }
        public string? CurrentInputHdcp { get; set; }
        public string? NewInputHdcp { get; set; }
        // Output
        public bool? SupportsOutputHdcp { get; set; }
        public bool? SupportsOutputResolution { get; set; }
        public string? CurrentOutputHdcp { get; set; }
        public string? NewOutputHdcp { get; set; }
        public string? CurrentOutputResolution { get; set; }
        public string? NewOutputResolution { get; set; }
        public List<string>? OutputResolutionOptions { get; set; }
        // Device
        public bool? SupportsAvRouting { get; set; }
        public string? CurrentAutoInputRouting { get; set; }
        public string? NewAutoInputRouting { get; set; }
    }

    private sealed class PerDeviceMulticastRowDto
    {
        public string? IP { get; set; }
        public string? Model { get; set; }
        public string? Hostname { get; set; }
        public string? Direction { get; set; }
        public string? CurrentDeviceMode { get; set; }
        public string? DeviceMode { get; set; }
        public bool? SupportsModeChange { get; set; }
        public int? StreamIndex { get; set; }
        public string? CurrentMulticastAddress { get; set; }
        public string? NewMulticastAddress { get; set; }
        public bool? SupportsAvMulticast { get; set; }
        public List<string>? DeviceModeOptions { get; set; }
    }

    private sealed class PerDeviceControlSubnetRowDto
    {
        public string? IP { get; set; }
        public string? Model { get; set; }
        public string? Hostname { get; set; }
        public bool? SupportsControlSubnet { get; set; }
        public bool? SupportsRouter { get; set; }
        public bool? SupportsIgmpVersion { get; set; }
        public bool? SupportsIgmpProxy { get; set; }
        public string? CurrentEnabled { get; set; }
        public string? NewEnabled { get; set; }
        public bool? CurrentDhcp { get; set; }
        public string? IPMode { get; set; }
        public string? CurrentIPAddress { get; set; }
        public string? NewIPAddress { get; set; }
        public string? CurrentSubnetMask { get; set; }
        public string? NewSubnetMask { get; set; }
        public string? CurrentGateway { get; set; }
        public string? NewGateway { get; set; }
        public string? CurrentIgmpVersion { get; set; }
        public string? NewIgmpVersion { get; set; }
        public string? CurrentRouterAutomaticMode { get; set; }
        public string? NewRouterAutomaticMode { get; set; }
        public string? CurrentRouterPrefix { get; set; }
        public string? NewRouterPrefix { get; set; }
        public string? CurrentRouterOnlineDelay { get; set; }
        public string? NewRouterOnlineDelay { get; set; }
        public string? CurrentRouterIsolationMode { get; set; }
        public string? NewRouterIsolationMode { get; set; }
        public string? CurrentIgmpProxy { get; set; }
        public string? NewIgmpProxy { get; set; }
        public string? IgmpProxyPropertyName { get; set; }
    }
}
