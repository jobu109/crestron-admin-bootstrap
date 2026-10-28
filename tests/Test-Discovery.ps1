$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/CrestronAdminBootstrap/CrestronAdminBootstrap.psd1" -Force
$module = Get-Module CrestronAdminBootstrap
$temp = Join-Path ([IO.Path]::GetTempPath()) "cabs-test-$([Guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temp
try {
    & $module {
        $request = New-CrestronDiscoveryRequest -Hostname 'TEST-PC'
        if ($request.Length -ne 266 -or [BitConverter]::ToString($request, 0, 10) -ne '14-00-00-00-01-04-00-03-00-00' -or
            [Text.Encoding]::ASCII.GetString($request, 10, 7) -ne 'TEST-PC' -or $request[17] -ne 0) {
            throw 'Discovery request differs from captured Toolbox wire layout'
        }
        $longRequest = New-CrestronDiscoveryRequest -Hostname ('A' * 300)
        if ($longRequest.Length -ne 266 -or $longRequest[265] -ne 0) { throw 'Sender name must be bounded and NUL-terminated' }
        if (ConvertFrom-CrestronDiscoveryReply $request '10.2.3.6') { throw 'Query accepted as reply' }
        $packet = [byte[]]::new(400)
        $packet[0] = 0x15
        $info = [Text.Encoding]::ASCII.GetBytes('CP4 [v4.0004.00114 (Oct 18 2024), #12345678] @E-AABBCCDDEEFF')
        $info.CopyTo($packet, 266)
        $row = ConvertFrom-CrestronDiscoveryReply $packet '10.2.3.4'
        if ($row.IP -ne '10.2.3.4' -or $row.MatchedSig -notmatch 'CP4') { throw 'Valid reply rejected' }
        if (ConvertFrom-CrestronDiscoveryReply ([byte[]]::new(20)) '10.2.3.4') { throw 'Truncated reply accepted' }
        if (ConvertFrom-CrestronDiscoveryReply ([byte[]]::new(316)) '10.2.3.4') { throw 'Query/invalid reply accepted' }
        # Synthetic compatibility cases, not captures from deployed hardware.
        foreach ($offset in @(42, 256, 266)) {
            $panel = [byte[]]::new($offset + 100)
            $panel[0] = 0x15
            [Text.Encoding]::ASCII.GetBytes('TSW1070-ROOM101').CopyTo($panel, 10)
            [Text.Encoding]::ASCII.GetBytes('TSW-1070 [2.004.1026]').CopyTo($panel, $offset)
            $row = ConvertFrom-CrestronDiscoveryReply $panel '10.2.3.5'
            if ($row.IP -ne '10.2.3.5' -or $row.MatchedSig -notmatch 'TSW-1070') { throw "Panel variant rejected at offset $offset" }
        }
        $panel = [Text.Encoding]::ASCII.GetBytes(([char]0).ToString() * 10 + "ROOM101`0TSW-1070`0")
        $panel[0] = 0x15
        if (-not (ConvertFrom-CrestronDiscoveryReply $panel '10.2.3.5')) { throw 'Panel without firmware rejected' }
        $query = [byte[]]::new(316)
        [Text.Encoding]::ASCII.GetBytes('LAPTOP').CopyTo($query, 27)
        if (ConvertFrom-CrestronDiscoveryReply $query '10.2.3.6') { throw 'Padded sender-name query accepted' }
        foreach ($cidr in @('10.0.0.0/33', '10.0.0.0/-1', '::1/24', '10.0.0.0/no')) {
            $rejected = $false
            try { Find-CrestronDevice -Cidr $cidr } catch { $rejected = $true }
            if (-not $rejected) { throw "Invalid CIDR accepted: $cidr" }
        }
        # Exercise the real parallel first-boot pipeline without network traffic.
        function script:Expand-Cidr { throw 'Discovery must not enumerate subnet hosts' }
        function script:Find-CrestronDevice { param($Cidr) [pscustomobject]@{ IP = '10.2.3.4' }; [pscustomobject]@{ IP = '10.2.3.5' } }
        function script:Test-CrestronBootupPage {
            param($IP, $TimeoutSec)
            if ($IP -eq '10.2.3.5') { return } # configured panel, no create-admin form
            [pscustomobject]@{ IP = $IP; BootupPage = $true; MatchedSig = 'test'; ScannedAt = 'test' }
        }
    }
    $cidrFile = Join-Path $temp subnets.txt
    $csv = Join-Path $temp results.csv
    '10.2.0.0/16' | Set-Content $cidrFile
    $rows = @(Find-CrestronBootup -CidrFile $cidrFile -OutputCsv $csv)
    if ($rows.Count -ne 1 -or $rows[0].IP -ne '10.2.3.4') { throw 'First-boot scan did not probe discovered candidate' }
    & $module { function script:Find-CrestronDevice { param($Cidr) } }
    $rows = @(Find-CrestronBootup -CidrFile $cidrFile -OutputCsv $csv)
    if ($rows.Count -ne 0 -or @(Import-Csv $csv).Count -ne 0) { throw 'Empty discovery returned stale results' }
    'Discovery regression checks passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Module CrestronAdminBootstrap
}
