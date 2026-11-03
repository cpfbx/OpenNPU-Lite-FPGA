param(
    [string]$VivadoRoot = $env:OPENNPU_VIVADO_ROOT,
    [ValidateSet(0, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096)]
    [int]$InputFifoDepth = 0,
    [ValidateSet(4, 8)]
    [int]$ArraySize = 4,
    [switch]$D007PHoldMargin,
    [switch]$Mode11Experiment
)

$ErrorActionPreference = 'Stop'
if ($Mode11Experiment -and ($ArraySize -ne 8 -or $D007PHoldMargin -or
    -not $env:OPENNPU_BUILD_OUTPUT_ROOT)) {
    throw 'MODE11 requires -ArraySize 8, isolated OPENNPU_BUILD_OUTPUT_ROOT and no legacy hold constraint.'
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$reportDir = Join-Path $repoRoot 'reports'
if ($env:OPENNPU_BUILD_OUTPUT_ROOT) {
    $reportDir = Join-Path $env:OPENNPU_BUILD_OUTPUT_ROOT 'reports'
}
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$python = Join-Path $repoRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Missing Python environment: $python"
}
if (-not $VivadoRoot) {
    if ($env:XILINX_VIVADO) {
        $VivadoRoot = $env:XILINX_VIVADO
    } else {
        $VivadoRoot = 'D:\AMDFPGA\2026.1\Vivado'
    }
}

$vivado = Join-Path $VivadoRoot 'bin\vivado.bat'
if (-not (Test-Path -LiteralPath $vivado)) {
    throw "Vivado not found: $vivado"
}

$boardPreset = Join-Path $repoRoot '.vendor\pynq-z2-board\files\pynq-z2\A.0\preset.xml'
if (-not (Test-Path -LiteralPath $boardPreset)) {
    throw 'PYNQ-Z2 board files are missing; run synth\fetch_pynq_z2_board_files.ps1 first.'
}
if ($D007PHoldMargin -and $ArraySize -ne 8) {
    throw 'D007-P hold-margin constraint requires -ArraySize 8.'
}

$profileDir = Join-Path $repoRoot '.vivado_userprofile'
$appDataDir = Join-Path $repoRoot '.vivado_appdata'
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
New-Item -ItemType Directory -Force -Path $appDataDir | Out-Null

# Capture the exact source state before Vivado starts. This sidecar is emitted
# for every future overlay build and must be copied into the corresponding
# metrics/build record. Older D003 artifacts predate this mechanism and retain
# that limitation explicitly instead of receiving a reconstructed identity.
$identityFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'rtl') -File -Recurse |
        Where-Object { $_.Extension -in @('.sv', '.v') }
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'constraints') -File -Recurse |
        Where-Object { $_.Extension -eq '.xdc' }
    Get-Item -LiteralPath (Join-Path $repoRoot 'synth\build_dma_loopback.tcl')
    Get-Item -LiteralPath (Join-Path $repoRoot 'synth\finalize_gemm_build_identity.py')
    Get-Item -LiteralPath $PSCommandPath
)
$sourceHashes = [ordered]@{}
foreach ($sourceFile in ($identityFiles | Sort-Object FullName -Unique)) {
    $relative = $sourceFile.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
    $sourceHashes[$relative] = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$gitCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
$gitStatus = @(& git -C $repoRoot status --porcelain)
$sourceIdentity = [ordered]@{
    schema = 'opennpu.build-source-identity.v1'
    captured_utc = (Get-Date).ToUniversalTime().ToString('o')
    git_commit = $gitCommit
    git_dirty = ($gitStatus.Count -gt 0)
    git_status = $gitStatus
    parameters = [ordered]@{
        input_fifo_depth = $InputFifoDepth
        array_size = $ArraySize
        d007_p_hold_margin = [bool]$D007PHoldMargin
        mode11_experiment = [bool]$Mode11Experiment
        mode11_implementation_min_delay_ns = $(if ($Mode11Experiment) { 0.060 } else { 0.0 })
    }
    source_sha256 = $sourceHashes
}
$identityPath = Join-Path $reportDir 'gemm_build_source_identity.json'
$sourceIdentity | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $identityPath -Encoding UTF8
Write-Host "Build source identity: $identityPath"
if ($gitStatus.Count -gt 0) {
    Write-Warning 'Building from a dirty worktree; the dirty paths are recorded in the source identity.'
}

$oldProfile = $env:USERPROFILE
$oldAppData = $env:APPDATA
$oldTclLibPath = $env:TCLLIBPATH
$oldAccelerator = $env:OPENNPU_ACCELERATOR
$oldInputFifoDepth = $env:OPENNPU_INPUT_FIFO_DEPTH
$oldArraySize = $env:OPENNPU_ARRAY_SIZE
$oldD007PHoldMargin = $env:OPENNPU_D007_P_HOLD_MARGIN
$oldMode11Experiment = $env:OPENNPU_MODE11_EXPERIMENT
try {
    $env:USERPROFILE = $profileDir
    $env:APPDATA = $appDataDir
    $env:OPENNPU_ACCELERATOR = 'gemm'
    $env:OPENNPU_INPUT_FIFO_DEPTH = [string]$InputFifoDepth
    $env:OPENNPU_ARRAY_SIZE = [string]$ArraySize
    $env:OPENNPU_D007_P_HOLD_MARGIN = if ($D007PHoldMargin) { '1' } else { '0' }
    $env:OPENNPU_MODE11_EXPERIMENT = if ($Mode11Experiment) { '1' } else { '0' }
    Remove-Item Env:TCLLIBPATH -ErrorAction SilentlyContinue
    Push-Location $repoRoot
    try {
        & $vivado -mode batch -source synth\build_dma_loopback.tcl -nojournal -nolog
        if ($LASTEXITCODE -ne 0) {
            throw "GEMM overlay build failed with exit code $LASTEXITCODE"
        }
        & $python (Join-Path $repoRoot 'synth\finalize_gemm_build_identity.py') `
            --repo-root $repoRoot `
            --source-identity $identityPath `
            --output (Join-Path $reportDir 'gemm_build_artifact_identity.json')
        if ($LASTEXITCODE -ne 0) {
            throw "GEMM artifact identity finalization failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
} finally {
    if ($null -eq $oldMode11Experiment) {
        Remove-Item Env:OPENNPU_MODE11_EXPERIMENT -ErrorAction SilentlyContinue
    } else {
        $env:OPENNPU_MODE11_EXPERIMENT = $oldMode11Experiment
    }
    $env:USERPROFILE = $oldProfile
    $env:APPDATA = $oldAppData
    if ($null -eq $oldTclLibPath) {
        Remove-Item Env:TCLLIBPATH -ErrorAction SilentlyContinue
    } else {
        $env:TCLLIBPATH = $oldTclLibPath
    }
    if ($null -eq $oldAccelerator) {
        Remove-Item Env:OPENNPU_ACCELERATOR -ErrorAction SilentlyContinue
    } else {
        $env:OPENNPU_ACCELERATOR = $oldAccelerator
    }
    if ($null -eq $oldInputFifoDepth) {
        Remove-Item Env:OPENNPU_INPUT_FIFO_DEPTH -ErrorAction SilentlyContinue
    } else {
        $env:OPENNPU_INPUT_FIFO_DEPTH = $oldInputFifoDepth
    }
    if ($null -eq $oldArraySize) {
        Remove-Item Env:OPENNPU_ARRAY_SIZE -ErrorAction SilentlyContinue
    } else {
        $env:OPENNPU_ARRAY_SIZE = $oldArraySize
    }
    if ($null -eq $oldD007PHoldMargin) {
        Remove-Item Env:OPENNPU_D007_P_HOLD_MARGIN -ErrorAction SilentlyContinue
    } else {
        $env:OPENNPU_D007_P_HOLD_MARGIN = $oldD007PHoldMargin
    }
}
