function Connect-CrestronDevice {
    <#
    .SYNOPSIS
        Authenticates against a Crestron 4-Series device and returns a session
        object usable by Set-CrestronSettings.
    .DESCRIPTION
        Follows the Crestron CWS auth flow:
          1. GET / to obtain a TRACKID cookie
          2. POST /userlogin.html with credentials and TRACKID
          3. Capture CREST-XSRF-TOKEN response header and session cookies
          4. GET /Device/DeviceInfo to record device family (TouchPanel vs
             ControlSystem etc.) for downstream API shape selection
        Returns an opaque session object. The cookie jar is written to a per-
        session temp file; call Disconnect-CrestronDevice to clean up.
    .PARAMETER IP
        Target device IP address.
    .PARAMETER Credential
        Admin credentials (same as those set by Set-CrestronAdmin).
    .PARAMETER TimeoutSec
        Per-request timeout. Default 15.
    .OUTPUTS
        PSCustomObject with: IP, CookieJarPath, XsrfToken, DeviceFamily,
        Model, Hostname, Firmware, ConnectedAt.
    .EXAMPLE
        $cred = Get-Credential
        $session = Connect-CrestronDevice -IP 172.22.0.21 -Credential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutSec = 15
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "Requires PowerShell 7+."
    }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw "curl.exe not found on PATH."
    }

    $user = $Credential.UserName
    $pass = $Credential.GetNetworkCredential().Password
    if (-not $user) { throw "Credential username is empty." }
    if (-not $pass) { throw "Credential password is empty." }

    # Per-session cookie jar
    $jar = Join-Path ([IO.Path]::GetTempPath()) "cabs-session-$([Guid]::NewGuid()).txt"

    # --- Step 1: GET / to grab TRACKID ---------------------------------------
    & curl.exe -k -s -c $jar --max-time $TimeoutSec `
        -o NUL `
        "https://$IP/" | Out-Null

    if (-not (Test-Path $jar)) {
        throw "Failed to receive TRACKID cookie from https://$IP/ (no jar created)."
    }
    if (-not (Select-String -Path $jar -Pattern 'TRACKID' -Quiet)) {
        Remove-Item $jar -ErrorAction SilentlyContinue
        throw "Device at $IP did not set a TRACKID cookie on GET /. Device may be unreachable or not a 4-Series unit."
    }

    # --- Step 2: POST /userlogin.html and capture response headers -----------
    $hdrFile   = Join-Path ([IO.Path]::GetTempPath()) "cabs-hdr-$([Guid]::NewGuid()).txt"
    $loginBody = "login=$([uri]::EscapeDataString($user))&passwd=$([uri]::EscapeDataString($pass))"
    $token     = $null

    try {
        & curl.exe -k -s -b $jar -c $jar -D $hdrFile --max-time $TimeoutSec `
            -X POST `
            -H "Content-Type: application/x-www-form-urlencoded" `
            -H "Referer: https://$IP/userlogin.html" `
            -H "Origin: https://$IP" `
            --data $loginBody `
            -o NUL `
            "https://$IP/userlogin.html" | Out-Null

        if (-not (Test-Path $hdrFile)) {
            throw "Login request to $IP produced no response headers."
        }

        $statusLine = Get-Content $hdrFile -TotalCount 1
        if ($statusLine -notmatch '\b(\d{3})\b') {
            throw "Could not parse status from login response: $statusLine"
        }
        $statusCode = [int]$Matches[1]
        if ($statusCode -ge 400) {
            throw "Login to $IP failed with HTTP $statusCode. Check credentials."
        }

        $tokenMatch = Select-String -Path $hdrFile -Pattern '^\s*CREST-XSRF-TOKEN\s*:\s*(.+)$' -CaseSensitive:$false |
                      Select-Object -First 1
        if (-not $tokenMatch) {
            throw "Login succeeded (HTTP $statusCode) but no CREST-XSRF-TOKEN header was returned by $IP."
        }
        $token = $tokenMatch.Matches.Groups[1].Value.Trim()

        $expectedCookies = @('userstr','userid','iv','tag','AuthByPasswd')
        $jarText = Get-Content $jar -Raw
        $missing = @($expectedCookies | Where-Object { $jarText -notmatch [regex]::Escape($_) })
        if ($missing.Count -gt 0) {
            Write-Warning "Login succeeded but expected cookie(s) missing from jar: $($missing -join ', ')"
        }
    } finally {
        Remove-Item $hdrFile -Force -ErrorAction SilentlyContinue
    }

    # --- Step 3: Probe /Device/DeviceInfo for family/model -------------------
    $family   = $null
    $model    = $null
    $hostName = $null
    $firmware = $null

    try {
        $infoBody = & curl.exe -k -s -b $jar -c $jar --max-time $TimeoutSec `
            -H "Accept: application/json" `
            -H "X-Requested-With: XMLHttpRequest" `
            -H "X-CREST-XSRF-TOKEN: $token" `
            "https://$IP/Device/DeviceInfo" 2>$null

        if ($infoBody) {
            $infoJson = $infoBody | ConvertFrom-Json -ErrorAction Stop
            $di = $infoJson.Device.DeviceInfo
            if ($di) {
                $family   = $di.Category
                $model    = $di.Model
                $hostName = $di.Name
                $firmware = $di.Version
            }
        }
    } catch {
        Write-Warning "Could not retrieve DeviceInfo from $IP ($($_.Exception.Message)). Family-specific payloads may pick the wrong shape."
    }

    [pscustomobject]@{
        IP            = $IP
        CookieJarPath = $jar
        XsrfToken     = $token
        DeviceFamily  = $family       # e.g. 'TouchPanel', 'ControlSystem'
        Model         = $model        # e.g. 'TS-1070', 'CP4'
        Hostname      = $hostName
        Firmware      = $firmware
        ConnectedAt   = (Get-Date).ToString('s')
    }
}