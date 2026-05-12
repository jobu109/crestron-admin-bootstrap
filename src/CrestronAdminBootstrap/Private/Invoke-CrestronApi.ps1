function Invoke-CrestronApi {
    <#
    .SYNOPSIS
        Wraps curl.exe for authenticated Crestron CresNext API calls.
    .DESCRIPTION
        Handles cookies (loads + persists), XSRF token header, JSON body
        serialization, and status/body parsing. Used by Set-CrestronSettings
        and other authenticated cmdlets.
    .PARAMETER Session
        Session object from Connect-CrestronDevice (IP, CookieJarPath,
        XsrfToken).
    .PARAMETER Path
        Endpoint path on the device (e.g. '/Device').
    .PARAMETER Method
        HTTP method. Default POST.
    .PARAMETER Body
        Hashtable or PSCustomObject to serialize as JSON. Ignored for GET.
    .PARAMETER TimeoutSec
        Per-request timeout. Default 15.
    .OUTPUTS
        PSCustomObject: Status (int), Success (bool), Body (string),
        BodyJson (parsed object if JSON, else $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET','POST')][string]$Method = 'POST',
        $Body,
        [int]$TimeoutSec = 15
    )

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw "curl.exe not found on PATH."
    }
    foreach ($k in 'IP','CookieJarPath','XsrfToken') {
        if (-not $Session.$k) {
            throw "Session is missing required property '$k'. Reconnect with Connect-CrestronDevice."
        }
    }

    $ip   = $Session.IP
    $url  = "https://$ip$Path"
    $jar  = $Session.CookieJarPath
    $xsrf = $Session.XsrfToken

    $bodyFile = $null
    try {
        $args = @(
            '-k','-s',
            '-b', $jar,
            '-c', $jar,
            '--max-time', $TimeoutSec,
            '-X', $Method,
            '-H', 'Accept: application/json',
            '-H', 'X-Requested-With: XMLHttpRequest',
            '-H', "Origin: https://$ip",
            '-H', "Referer: https://$ip/index_device.html"
        )

        if ($Method -eq 'POST') {
            $args += @('-H', "X-CREST-XSRF-TOKEN: $xsrf")
            if ($null -ne $Body) {
                $json     = $Body | ConvertTo-Json -Depth 12 -Compress
                $bodyFile = New-TemporaryFile
                Set-Content -Path $bodyFile -Value $json -Encoding UTF8 -NoNewline
                $args += @('-H', 'Content-Type: application/json',
                           '--data-binary', "@$bodyFile")
            }
        }

        $args += @('-w', "`n__HTTP_STATUS__:%{http_code}", $url)

        $out    = & curl.exe @args 2>$null
        $text   = ($out -join "`n")
        $status = if ($text -match '__HTTP_STATUS__:(\d+)') { [int]$Matches[1] } else { 0 }
        $body   = $text -replace "`n?__HTTP_STATUS__:\d+$",''

        $bodyJson = $null
        if ($body -and ($body.TrimStart().StartsWith('{') -or $body.TrimStart().StartsWith('['))) {
            try { $bodyJson = $body | ConvertFrom-Json } catch { }
        }

        [pscustomobject]@{
            Status   = $status
            Success  = ($status -ge 200 -and $status -lt 300)
            Body     = $body
            BodyJson = $bodyJson
        }
    } finally {
        if ($bodyFile -and (Test-Path $bodyFile)) {
            Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}