param(
    [string]$VivadoRoot = $env:OPENNPU_VIVADO_ROOT,
    [string]$WorkLibrary = 'work'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $VivadoRoot) {
    if ($env:XILINX_VIVADO) {
        $VivadoRoot = $env:XILINX_VIVADO
    } else {
        $VivadoRoot = 'D:\AMDFPGA\2026.1\Vivado'
    }
}

$xvlog = Join-Path $VivadoRoot 'bin\xvlog.bat'
$xelab = Join-Path $VivadoRoot 'bin\xelab.bat'
$xsim  = Join-Path $VivadoRoot 'bin\xsim.bat'

foreach ($tool in @($xvlog, $xelab, $xsim)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Vivado tool not found: $tool. Set OPENNPU_VIVADO_ROOT to the Vivado installation directory."
    }
}

$sources = @(
    'rtl\uart_rx.v',
    'rtl\uart_tx.v',
    'rtl\uart_loopback.v',
    'rtl\controller_fsm.v',
    'rtl\uart_controller_top.v',
    'rtl\opennpu_top.v',
    'rtl\pe.v',
    'rtl\pe_array.v',
    'rtl\pe_array_4x4.v',
    'rtl\weight_buffer.v',
    'rtl\weight_bram.v',
    'rtl\input_buffer.v',
    'rtl\input_bram.v',
    'rtl\output_buffer.v',
    'rtl\output_bram.v',
    'rtl\ibuf_mock.v',
    'rtl\wbuf_mock.v',
    'rtl\obuf_mock.v',
    'rtl\pe_array_mock.v',
    'rtl\axi_lite_regs.sv',
    'rtl\axis_packet_guard.sv',
    'rtl\axis_dma_loopback_top.sv',
    'rtl\c_accum_bram_xpm.sv',
    'rtl\requantize_int8_pipeline.sv',
    'rtl\d005_chain_header_parser.sv',
    'rtl\d007_result_fifo.sv',
    'rtl\d007_mode11_work_counters_experiment.sv',
    'rtl\d007_c_buffer_controller_experiment.sv',
    'rtl\d007_c_buffer_drain_experiment.sv',
    'rtl\d007_c_buffer_owned_drain_experiment.sv',
    'rtl\d007_shared_core_session_arbiter_experiment.sv',
    'rtl\d007_shared_core_axis_router_experiment.sv',
    'rtl\d007_shared_core_one_physical_experiment.sv',
    'rtl\axis_tile_gemm_core.sv',
    'rtl\d007_c_buffer_integrated_core_experiment.sv',
    'rtl\d007_c_buffer_chain_experiment.sv',
    'rtl\d005_gemm_execution_core.sv',
    'rtl\d007_dual_c_mode_mux_experiment.sv',
    'rtl\axis_gemm_accelerator_top.sv',
    'rtl\axis_gemm_mode11_experiment_top.sv',
    'tb\tb_controller.v',
    'tb\tb_input_buffer.v',
    'tb\tb_output_buffer.v',
    'tb\tb_pe.v',
    'tb\tb_pe_array.v',
    'tb\tb_pe_array_4x4.v',
    'tb\tb_pe_array_random.sv',
    'tb\tb_axi_lite_regs.sv',
    'tb\tb_axis_packet_guard.sv',
    'tb\tb_axis_dma_loopback_top.sv',
    'tb\tb_requantize_int8_pipeline.sv',
    'tb\tb_d005_chain_header_parser.sv',
    'tb\tb_axis_tile_gemm_core.sv',
    'tb\tb_axis_tile_gemm_core_fused.sv',
    'tb\tb_d006_k_major_core.sv',
    'tb\tb_d007_result_fifo.sv',
    'tb\tb_d007_mode11_work_counters_experiment.sv',
    'tb\tb_d007_decoupled_core.sv',
    'tb\tb_d007_c_buffer_real_overlap.sv',
    'tb\tb_d007_shared_core_runtime_restart.sv',
    'tb\tb_d007_shared_core_session_arbiter.sv',
    'tb\tb_d007_shared_core_axis_router.sv',
    'tb\tb_d007_c_buffer_owned_overlap.sv',
    'tb\tb_d007_c_buffer_chain_experiment.sv',
    'tb\tb_d007_dual_c_mode_mux_experiment.sv',
    'tb\tb_d007_mode11_random.sv',
    'tb\tb_d007_mode11_mmio.sv',
    'tb\tb_d007_registered_config_bounds.sv',
    'tb\tb_d005_gemm_execution_core.sv',
    'tb\tb_uart_controller_top.v',
    'tb\tb_uart_loopback.v',
    'tb\tb_uart_rx.v',
    'tb\tb_uart_tx.v'
)

$testbenches = @(
    'tb_controller',
    'tb_input_buffer',
    'tb_output_buffer',
    'tb_pe',
    'tb_pe_array',
    'tb_pe_array_4x4',
    'tb_pe_array_random',
    'tb_axi_lite_regs',
    'tb_axis_packet_guard',
    'tb_axis_dma_loopback_top',
    'tb_requantize_int8_pipeline',
    'tb_d005_chain_header_parser',
    'tb_axis_tile_gemm_core',
    'tb_axis_tile_gemm_core_8x8',
    'tb_d007_dual_c_real_core',
    'tb_axis_tile_gemm_core_fused',
    'tb_d007_dual_c_fused',
    'tb_d006_k_major_core',
    'tb_d007_result_fifo',
    'tb_d007_mode11_work_counters_experiment',
    'tb_d007_decoupled_core',
    'tb_d007_c_buffer_real_overlap',
    'tb_d007_shared_core_runtime_restart',
    'tb_d007_shared_core_session_arbiter',
    'tb_d007_shared_core_axis_router',
    'tb_d007_c_buffer_owned_overlap',
    'tb_d007_runtime_owned_overlap',
    'tb_d007_external_owned_overlap',
    'tb_d007_c_buffer_chain_experiment',
    'tb_d007_dual_c_mode_mux_experiment',
    'tb_d007_one_physical_mode_handoff',
    'tb_d007_one_physical_no_backpressure',
    'tb_d007_mode11_random',
    'tb_d007_mode11_mmio',
    'tb_d007_registered_config_bounds',
    'tb_d005_gemm_execution_core',
    'tb_d005_gemm_execution_core_dual_bank',
    'tb_d005_gemm_execution_core_external',
    'tb_d007_shared_core_legacy_contract',
    'tb_uart_controller_top',
    'tb_uart_loopback',
    'tb_uart_rx',
    'tb_uart_tx'
)

$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$failed = @()

Push-Location $repoRoot
try {
    & $xvlog -sv -work $WorkLibrary $sources
    if ($LASTEXITCODE -ne 0) {
        throw "xvlog failed with exit code $LASTEXITCODE"
    }

    foreach ($top in $testbenches) {
        $snapshot = "reg_$top"
        & $xelab "$WorkLibrary.$top" -L $WorkLibrary -L xpm -s $snapshot
        if ($LASTEXITCODE -ne 0) {
            $failed += "$top (elaboration)"
            continue
        }

        $output = @(& $xsim $snapshot -runall 2>&1)
        $output | Set-Content -LiteralPath (Join-Path $logDir "$top.log") -Encoding UTF8

        $summary = @($output | Where-Object {
            $_ -match 'PASS|FAIL|TOTAL|SUMMARY|通过|失败|测试完成|ALL'
        })

        Write-Host "`n===== $top ====="
        if ($summary.Count -gt 0) {
            $summary | Select-Object -Last 12 | ForEach-Object { Write-Host $_ }
        } else {
            $output | Select-Object -Last 12 | ForEach-Object { Write-Host $_ }
        }

        $hasFailure = $LASTEXITCODE -ne 0 -or ($output -match '^Fatal:') -or
            ($output -match '\[FAIL\]') -or
            ($output -match 'FAIL[:=]\s*[1-9]') -or ($output -match 'SOME FAILED')
        if ($hasFailure) {
            $failed += $top
        }
    }
} finally {
    Pop-Location
}

if ($failed.Count -gt 0) {
    Write-Error "Regression failed: $($failed -join ', ')"
    exit 1
}

Write-Host "`nAll $($testbenches.Count) testbenches passed."
