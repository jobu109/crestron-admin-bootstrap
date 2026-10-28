$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/CrestronAdminBootstrap/CrestronAdminBootstrap.psd1" -Force
$module = Get-Module CrestronAdminBootstrap
$temp = Join-Path ([IO.Path]::GetTempPath()) "cabs-test-$([Guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temp
try {
    & $module {
        $packet = [byte[]]::new(400)
        $info = [Text.Encoding]::ASCII.GetBytes('CP4 [v4.0004.00114 (Oct 18 2024), #12345678] @E-AABBCCDDEEFF')
        $info.CopyTo($packet, 266)
        $row = ConvertFrom-CrestronDiscoveryReply $packet '10.2.3.4'
        if ($row.IP -ne '10.2.3.4' -or $row.MatchedSig -notmatch 'CP4') { throw 'Valid reply rejected' }
        if (ConvertFrom-CrestronDiscoveryReply ([byte[]]::new(20)) '10.2.3.4') { throw 'Truncated reply accepted' }
        if (ConvertFrom-CrestronDiscoveryReply ([byte[]]::new(316)) '10.2.3.4') { throw 'Query/invalid reply accepted' }
        foreach ($cidr in @('10.0.0.0/33', '10.0.0.0/-1', '::1/24', '10.0.0.0/no')) {
            $rejected = $false
            try { Find-CrestronDevice -Cidr $cidr } catch { $rejected = $true }
            if (-not $rejected) { throw "Invalid CIDR accepted: $cidr" }
        }
        # Exercise the real parallel first-boot pipeline without network traffic.
        function script:Expand-Cidr { throw 'Discovery must not enumerate subnet hosts' }
        function script:Find-CrestronDevice { param($Cidr) [pscustomobject]@{ IP = '10.2.3.4' } }
        function script:Test-CrestronBootupPage {
            param($IP, $TimeoutSec)
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
