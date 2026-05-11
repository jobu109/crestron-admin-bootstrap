<#
    CrestronAdminBootstrap module loader.
    Dot-sources every .ps1 in Public/ and Private/, then exports only Public.
#>

$ErrorActionPreference = 'Stop'

$publicDir  = Join-Path $PSScriptRoot 'Public'
$privateDir = Join-Path $PSScriptRoot 'Private'

# Private first (helpers must be defined before Public functions reference them)
if (Test-Path $privateDir) {
    Get-ChildItem -Path $privateDir -Filter *.ps1 -File | ForEach-Object {
        . $_.FullName
    }
}

# Public next
$publicFunctions = @()
if (Test-Path $publicDir) {
    Get-ChildItem -Path $publicDir -Filter *.ps1 -File | ForEach-Object {
        . $_.FullName
        # Function name matches file name (convention)
        $publicFunctions += $_.BaseName
    }
}

if ($publicFunctions.Count -gt 0) {
    Export-ModuleMember -Function $publicFunctions
}