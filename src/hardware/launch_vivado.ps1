param(
    [Parameter(Mandatory=$true)][ValidateSet('Version','Build')][string]$Action,
    [Parameter(Mandatory=$true)][string]$VivadoRoot,
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [Parameter(Mandatory=$true)][string]$OutputRoot
)
$ErrorActionPreference = 'Stop'
$vivado = Join-Path $VivadoRoot 'bin/vivado.bat'
if (-not (Test-Path -LiteralPath $vivado -PathType Leaf)) { throw 'Vivado launcher missing' }
if ($Action -eq 'Version') {
    & $vivado -version
    exit $LASTEXITCODE
}
if (Test-Path -LiteralPath $OutputRoot) { throw 'Fresh build output required; no overwrite/retry' }
$env:USERPROFILE = Join-Path $SourceRoot '.vivado_userprofile'
$env:APPDATA = Join-Path $SourceRoot '.vivado_appdata'
New-Item -ItemType Directory -Path $env:USERPROFILE,$env:APPDATA | Out-Null
Remove-Item Env:TCLLIBPATH -ErrorAction SilentlyContinue
$env:OPENNPU_ACCELERATOR = 'gemm'
$env:OPENNPU_ARRAY_SIZE = '8'
$env:OPENNPU_INPUT_FIFO_DEPTH = '0'
$env:OPENNPU_D007_P_HOLD_MARGIN = '0'
$env:OPENNPU_MODE11_EXPERIMENT = '1'
$env:OPENNPU_BUILD_OUTPUT_ROOT = $OutputRoot
Set-Location -LiteralPath $SourceRoot
& $vivado -mode batch -source (Join-Path $SourceRoot 'synth/build_dma_loopback.tcl') -nojournal -nolog
exit $LASTEXITCODE
