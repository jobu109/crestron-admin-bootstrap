function Test-CrestronFirmwareVersionText {
    param($Value)

    if ($null -eq $Value) { return $false }

    $text = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text.Length -gt 80) { return $false }
    if ($text -match '^(?i)(n/a|na|null|unknown|true|false|enabled|disabled)$') { return $false }

    return ($text -match '\d+\.\d+')
}

function Get-CrestronFirmwareCandidateScore {
    param(
        [string]$Path,
        [string]$Value
    )

    $pathText = "$Path"
    $leaf = @($pathText -split '[.\[\]]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    $leafText = if ($leaf.Count -gt 0) { "$($leaf[0])" } else { '' }
    $score = 0

    if ($pathText -match '(?i)firmware') { $score += 140 }
    if ($leafText -match '(?i)firmware') { $score += 180 }
    if ($pathText -match '(?i)(system.?update|software|package|puf|image|os|build)') { $score += 60 }
    if ($leafText -match '(?i)(current|installed|running|active|package|puf|build|release)') { $score += 35 }
    if ($leafText -match '^(?i)(version|ver)$') { $score += 5 }

    if ($Value -match '^\d+(\.\d+){2,}') { $score += 20 }
    if ($Value -match '^\d+(\.\d+){3,}') { $score += 20 }

    # DeviceInfo.Version has been observed as a CresNext/web/API version on
    # newer units, not the installed firmware. Treat a four-part value as a
    # possible firmware fallback, but demote shorter generic versions.
    if ($pathText -match '(?i)DeviceInfo\.Version$') {
        if ($Value -match '^\d+(\.\d+){3,}') {
            $score -= 5
        }
        else {
            $score -= 25
        }
    }

    if ($pathText -match '(?i)(AudioVideoInputOutput|Avio|StreamTransmit|StreamReceive|DeviceSpecific|Applications?)\.Version$') {
        $score -= 35
    }

    return $score
}

function Get-CrestronFirmwareVersionFromObject {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [object[]]$InputObject
    )

    begin {
        $candidates = @()
    }

    process {
        foreach ($root in @($InputObject)) {
            if ($null -eq $root) { continue }

            $stack = New-Object System.Collections.Generic.List[object]
            $stack.Add([pscustomobject]@{ Value = $root; Path = ''; Depth = 0 }) | Out-Null

            while ($stack.Count -gt 0) {
                $node = $stack[$stack.Count - 1]
                $stack.RemoveAt($stack.Count - 1)

                if ($node.Depth -gt 10) { continue }

                $value = $node.Value
                $path = "$($node.Path)"

                if ($null -eq $value) { continue }

                if ($value -is [string] -or
                    $value -is [int] -or
                    $value -is [long] -or
                    $value -is [double] -or
                    $value -is [decimal]) {
                    $text = "$value".Trim()

                    if (Test-CrestronFirmwareVersionText $text) {
                        $score = Get-CrestronFirmwareCandidateScore -Path $path -Value $text
                        $candidates += [pscustomobject]@{
                            Path  = $path
                            Value = $text
                            Score = $score
                        }
                    }

                    continue
                }

                if ($value -is [System.Collections.IDictionary]) {
                    foreach ($key in @($value.Keys)) {
                        $childPath = if ($path) { "$path.$key" } else { "$key" }
                        $stack.Add([pscustomobject]@{ Value = $value[$key]; Path = $childPath; Depth = $node.Depth + 1 }) | Out-Null
                    }

                    continue
                }

                if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                    $index = 0
                    foreach ($item in @($value)) {
                        if ($index -ge 100) { break }
                        $childPath = "${path}[$index]"
                        $stack.Add([pscustomobject]@{ Value = $item; Path = $childPath; Depth = $node.Depth + 1 }) | Out-Null
                        $index++
                    }

                    continue
                }

                foreach ($property in @($value.PSObject.Properties)) {
                    $childPath = if ($path) { "$path.$($property.Name)" } else { "$($property.Name)" }
                    $stack.Add([pscustomobject]@{ Value = $property.Value; Path = $childPath; Depth = $node.Depth + 1 }) | Out-Null
                }
            }
        }
    }

    end {
        $best = @($candidates |
            Sort-Object `
                @{ Expression = 'Score'; Descending = $true },
                @{ Expression = { ([regex]::Matches($_.Value, '\.')).Count }; Descending = $true },
                @{ Expression = 'Path'; Descending = $false } |
            Select-Object -First 1)

        if ($best.Count -gt 0 -and $best[0].Score -ge 30) {
            return "$($best[0].Value)"
        }

        return ''
    }
}

function Get-CrestronFirmwareVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [object[]]$SeedObjects = @(),
        [int]$TimeoutSec = 5
    )

    $objects = @($SeedObjects | Where-Object { $null -ne $_ })
    $probeTimeout = [Math]::Max(1, [Math]::Min($TimeoutSec, 5))
    $firmware = Get-CrestronFirmwareVersionFromObject -InputObject $objects
    if (-not [string]::IsNullOrWhiteSpace($firmware)) {
        return $firmware
    }

    foreach ($path in @(
        '/Device',
        '/Device/SystemUpdate',
        '/Device/AutoUpdateMaster',
        '/Device/DeviceOperations',
        '/Device/Firmware'
    )) {
        try {
            $api = Invoke-CrestronApi -Session $Session -Path $path -Method GET -TimeoutSec $probeTimeout
            if ($api.Success -and $api.BodyJson) {
                $objects += $api.BodyJson
                $firmware = Get-CrestronFirmwareVersionFromObject -InputObject $objects
                if (-not [string]::IsNullOrWhiteSpace($firmware)) {
                    return $firmware
                }
            }
        }
        catch { }
    }

    return ''
}
