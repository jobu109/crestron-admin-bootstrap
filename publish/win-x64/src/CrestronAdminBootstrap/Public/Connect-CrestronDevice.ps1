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

# --- Step 2: POST /userlogin.html and capture response headers -----------
    # Match the browser-issued login as closely as possible:
    #  - Only URL-encode characters that *must* be escaped in form data
    #    (% & = + and control chars). Some firmware variants do a literal
    #    string compare on the password instead of URL-decoding it.
    #  - Send X-Requested-With: XMLHttpRequest so the device treats the POST
    #    as an AJAX login (matches what the web UI does).
    function _MinimalFormEncode ([string]$s) {
        $sb = [System.Text.StringBuilder]::new()
        foreach ($ch in $s.ToCharArray()) {
            $code = [int]$ch
            if ($code -le 0x20 -or $code -eq 0x25 -or $code -eq 0x26 -or $code -eq 0x2B -or $code -eq 0x3D -or $code -ge 0x7F) {
                [void]$sb.AppendFormat('%{0:X2}', $code)
            } else {
                [void]$sb.Append($ch)
            }
        }
        $sb.ToString()
    }

    $hdrFile   = Join-Path ([IO.Path]::GetTempPath()) "cabs-hdr-$([Guid]::NewGuid()).txt"
    $loginBody = "login=$(_MinimalFormEncode $user)&passwd=$(_MinimalFormEncode $pass)"
    $token     = $null

    try {
        & curl.exe -k -s -b $jar -c $jar -D $hdrFile --max-time $TimeoutSec `
            -X POST `
            -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" `
            -H "X-Requested-With: XMLHttpRequest" `
            -H "Referer: https://$IP/userlogin.html" `
            -H "Origin: https://$IP" `
            -H "Accept: */*" `
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

        # The XSRF token may or may not appear in the login response headers
        # depending on firmware variant. Newer firmware (e.g. TS-1070 v3.x)
        # returns CREST-XSRF-TOKEN; older firmware returns only session cookies
        # and exposes the token elsewhere. Treat "session cookies present" as
        # the real success signal, and try to extract the token if found.
        $tokenMatch = Select-String -Path $hdrFile -Pattern '^\s*CREST-XSRF-TOKEN\s*:\s*(.+)$' -CaseSensitive:$false |
                      Select-Object -First 1
        if ($tokenMatch) {
            $token = $tokenMatch.Matches.Groups[1].Value.Trim()
        } else {
            $token = $null
        }

        # Real auth check: did the device set our session cookies?
        $expectedCookies = @('userstr','userid','iv','tag','AuthByPasswd')
        $jarText = Get-Content $jar -Raw
        $present = @($expectedCookies | Where-Object { $jarText -match [regex]::Escape($_) })
        if ($present.Count -lt 3) {
            # Fewer than 3 of the 5 cookies — assume credentials were rejected.
            # (Bad-login responses set 0 cookies; partial responses suggest a
            # different problem but should still fail.)
            throw "Authentication rejected by $IP — likely wrong credentials. (HTTP $statusCode, only $($present.Count)/5 session cookies set.)"
        }

        if (-not $token) {
            # No token in header — try to find it on the post-login landing page,
            # which on older firmware embeds it in a meta tag or sets it as a cookie.
            $probe = Join-Path ([IO.Path]::GetTempPath()) "cabs-probe-$([Guid]::NewGuid()).html"
            try {
                & curl.exe -k -s -b $jar -c $jar --max-time $TimeoutSec `
                    -o $probe `
                    "https://$IP/" 2>$null | Out-Null
                if (Test-Path $probe) {
                    $html = Get-Content $probe -Raw -ErrorAction SilentlyContinue
                    if ($html -match 'CREST-XSRF-TOKEN["'']?\s*[:=]\s*["'']?([^"''<>\s]+)') {
                        $token = $Matches[1]
                    }
                }
            } catch { }
            finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
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