param(
    [string]$Destination = (Join-Path (Split-Path -Parent $PSScriptRoot) '.vendor\pynq-z2-board')
)

$ErrorActionPreference = 'Stop'
$sourceUrl = 'https://dpoauwgwqsy2x.cloudfront.net/Download/pynq-z2.zip'
$expectedSha256 = '6FBA4C40DB5A0C480CA96B2F41719F57E83728A54AC9823578AC21667B2E4E7F'
$archive = Join-Path $Destination 'pynq-z2.zip'
$extractRoot = Join-Path $Destination 'files'
$preset = Join-Path $extractRoot 'pynq-z2\A.0\preset.xml'

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest -Uri $sourceUrl -OutFile $archive
}

$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
if ($actualSha256 -ne $expectedSha256) {
    throw "PYNQ-Z2 board file hash mismatch: $actualSha256"
}

if (-not (Test-Path -LiteralPath $preset)) {
    Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force
}

if (-not (Test-Path -LiteralPath $preset)) {
    throw "PYNQ-Z2 preset not found after extraction: $preset"
}

Write-Host "PYNQ-Z2 board files ready: $extractRoot"
Write-Host "SHA256: $actualSha256"
