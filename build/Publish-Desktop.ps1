[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$Runtime = 'win-x64',
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repoRoot 'src/CrestronAdminBootstrap.Desktop/CrestronAdminBootstrap.Desktop.csproj'
$publishRoot = Join-Path $repoRoot "dist/desktop-$Runtime"
$publishRootMsBuild = ($publishRoot -replace '\\', '/') + '/'

function Assert-CabsPublishIsClean {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $blockedNames = @(
        'gui-settings.json',
        'CrestronBootstrap-error.log',
        'subnets.txt',
        'test-subnets.txt',
        'session.txt',
        'payload.json',
        'login-headers.txt'
    )

    $blockedExtensions = @(
        '.pfx',
        '.p12',
        '.cookies'
    )

    $blockedWildcardNames = @(
        'crestron-*-debug.jsonl'
    )

    $blocked = Get-ChildItem -LiteralPath $Path -Recurse -Force -File | Where-Object {
        $file = $_
        $blockedNames -contains $file.Name -or
        $blockedExtensions -contains $file.Extension -or
        @($blockedWildcardNames | Where-Object { $file.Name -like $_ }).Count -gt 0
    }

    if ($blocked) {
        $details = ($blocked | ForEach-Object { $_.FullName }) -join [Environment]::NewLine
        throw "Publish output contains local/private files and will not be zipped:$([Environment]::NewLine)$details"
    }
}

if (-not (Test-Path -LiteralPath $project)) {
    throw "Desktop project not found at $project"
}

if (Test-Path -LiteralPath $publishRoot) {
    Remove-Item -LiteralPath $publishRoot -Recurse -Force
}

$publishArgs = @(
    'publish',
    $project,
    '--configuration', $Configuration,
    '--runtime', $Runtime,
    '--self-contained', 'true',
    '-p:PublishSingleFile=true',
    '-p:IncludeNativeLibrariesForSelfExtract=true',
    '-p:EnableCompressionInSingleFile=true',
    '-p:PublishReadyToRun=false',
    "-p:PublishDir=$publishRootMsBuild"
)

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $publishArgs += "-p:Version=$Version"
    $publishArgs += "-p:AssemblyVersion=$Version"
    $publishArgs += "-p:FileVersion=$Version"
}

& dotnet @publishArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$exe = Join-Path $publishRoot 'CrestronBootstrap.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Publish finished but the EXE was not found at $exe"
}

$wrapperSource = Join-Path $repoRoot 'wrapper/CrestronBootstrap.Gui.ps1'
if (Test-Path -LiteralPath $wrapperSource) {
    $wrapperDest = Join-Path $publishRoot 'wrapper/CrestronBootstrap.Gui.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $wrapperDest) -Force | Out-Null
    Copy-Item -LiteralPath $wrapperSource -Destination $wrapperDest -Force
}

$label = if ([string]::IsNullOrWhiteSpace($Version)) { 'dev' } else { $Version.TrimStart('v') }
$zipPath = Join-Path $repoRoot "dist/CrestronAdminBootstrap-$label-$Runtime.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Assert-CabsPublishIsClean -Path $publishRoot
Compress-Archive -Path (Join-Path $publishRoot '*') -DestinationPath $zipPath -Force

$exeInfo = Get-Item -LiteralPath $exe
$zipInfo = Get-Item -LiteralPath $zipPath
[pscustomobject]@{
    Exe = $exeInfo.FullName
    ExeSizeMB = [math]::Round($exeInfo.Length / 1MB, 2)
    Zip = $zipInfo.FullName
    ZipSizeMB = [math]::Round($zipInfo.Length / 1MB, 2)
}
