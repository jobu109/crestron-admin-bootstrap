function Disconnect-CrestronDevice {
    <#
    .SYNOPSIS
        Cleans up a Crestron session created by Connect-CrestronDevice.
    .DESCRIPTION
        Deletes the on-disk cookie jar associated with the session. Does not
        contact the device (CresNext sessions expire server-side on their own).
        Safe to call on a stale or partial session object.
    .PARAMETER Session
        Session object returned by Connect-CrestronDevice.
    .EXAMPLE
        Disconnect-CrestronDevice -Session $session
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][pscustomobject]$Session
    )
    process {
        if ($Session.CookieJarPath -and (Test-Path $Session.CookieJarPath)) {
            Remove-Item $Session.CookieJarPath -Force -ErrorAction SilentlyContinue
        }
    }
}