"""Portable offline PC entry for KWS full hybrid inference candidate.

Usage (from an empty working directory outside candidate and unpacked sources):
  python -I -B /abs/path/candidate/run_hybrid_candidate.py \
      --manifest-sha <candidate_manifest_sha256> \
      --sources /abs/path/unpacked_sources \
      --output /abs/path/fresh_output \
      --mode all \
      --enable-hybrid-offline

Modes:
  - smoke1: run 1-window (window 0) full hybrid smoke test only
  - fixed12: run 12-window full hybrid session only
  - tests: run 17 positive/negative unittest methods only
  - all: run smoke1 + fixed12 + tests in isolated subprocesses from an empty cwd

No board access, no real lock access, no automatic dependency install.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import hybrid_contract as hc
from hybrid_contract import need, sha, write_json_exclusive
from hybrid_graph import run_hybrid_session


def run_single_mode(sources_root: Path, output: Path, mode: str) -> int:
    bundle = hc.load_hybrid_bundle(sources_root, enabled=True)
    summary = run_hybrid_session(bundle, output, enabled=True, mode=mode, profile='normal')
    print(json.dumps({
        'mode': mode,
        'operation_success': summary['operation_success'],
        'windows_completed': summary['windows_completed'],
        'driver_returns': summary['driver_returns'],
        'returned_jobs': summary['returned_jobs'],
        'returned_pointwise_MACs': summary['returned_pointwise_MACs'],
        'depthwise_executed_logical_MACs': summary['depthwise_executed_logical_MACs'],
        'vad_recomputed': summary['vad_recomputed'],
        'board_access': summary['board_access'],
        'promotion': summary['promotion'],
    }, sort_keys=True))
    return 0 if summary['operation_success'] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest-sha', required=True, help='External SHA256 pin of candidate/manifest.json')
    parser.add_argument('--sources', type=Path, required=True, help='Path to unpacked prerequisite sources')
    parser.add_argument('--output', type=Path, required=True, help='Fresh external output directory')
    parser.add_argument('--mode', choices=('smoke1', 'fixed12', 'tests', 'all'), default='all')
    parser.add_argument('--enable-hybrid-offline', action='store_true', help='Explicit opt-in flag (default-off)')
    args = parser.parse_args()

    need(args.enable_hybrid_offline is True, 'hybrid offline candidate is default-off (pass --enable-hybrid-offline)')
    before_cand = hc.verify_candidate_tree(args.manifest_sha)
    sources_root = hc.verify_sources_tree(args.sources)
    before_sources = {rel: hc.pin(sources_root / rel) for rel in hc.SOURCE_ANCHORS}
    output = hc.validate_output_dir(args.output, sources_root)

    # Check NumPy availability without auto-installing
    import numpy as np
    numpy_version = np.__version__

    if args.mode in ('smoke1', 'fixed12'):
        rc = run_single_mode(sources_root, output, args.mode)
        after_cand = hc.verify_candidate_tree(args.manifest_sha)
        need(after_cand == before_cand, 'candidate tree drifted during execution')
        return rc

    if args.mode == 'tests':
        cmd = [
            sys.executable, '-I', '-B', str(ROOT / 'test_hybrid_candidate.py'),
            '--sources', str(sources_root),
            '--output', str(output),
        ]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sys.stdout.buffer.write(res.stdout)
        sys.stderr.buffer.write(res.stderr)
        after_cand = hc.verify_candidate_tree(args.manifest_sha)
        need(after_cand == before_cand, 'candidate tree drifted during tests')
        return res.returncode

    # mode == 'all': orchestrate smoke1, fixed12, and tests in isolated subprocesses from an empty cwd
    output.mkdir(parents=False, exist_ok=False)
    empty_cwd = output / 'empty_cwd'
    empty_cwd.mkdir()
    commands = []
    started = time.monotonic()

    steps = [
        ('01_smoke1', [
            sys.executable, '-I', '-B', str(ROOT / 'run_hybrid_candidate.py'),
            '--manifest-sha', args.manifest_sha,
            '--sources', str(sources_root),
            '--output', str(output / 'smoke1'),
            '--mode', 'smoke1',
            '--enable-hybrid-offline',
        ]),
        ('02_fixed12', [
            sys.executable, '-I', '-B', str(ROOT / 'run_hybrid_candidate.py'),
            '--manifest-sha', args.manifest_sha,
            '--sources', str(sources_root),
            '--output', str(output / 'fixed12'),
            '--mode', 'fixed12',
            '--enable-hybrid-offline',
        ]),
        ('03_unit_tests', [
            sys.executable, '-I', '-B', str(ROOT / 'test_hybrid_candidate.py'),
            '--sources', str(sources_root),
            '--output', str(output / 'unit_tests'),
        ]),
    ]

    all_ok = True
    error_type = None
    unit_test_counts = None
    try:
        for label, argv in steps:
            proc = subprocess.run(argv, cwd=empty_cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            stdout_pin = hc.write_exclusive(output / f'{label}.stdout.txt', proc.stdout)
            stderr_pin = hc.write_exclusive(output / f'{label}.stderr.txt', proc.stderr)
            row = dict(
                label=label,
                argv=argv,
                actual_exit=proc.returncode,
                stdout=stdout_pin,
                stderr=stderr_pin,
            )
            if label == '03_unit_tests' and (output / 'unit_tests/unittest_summary.json').is_file():
                unit_test_counts = hc.strict_json((output / 'unit_tests/unittest_summary.json').read_bytes())
                row['test_counts'] = unit_test_counts
            commands.append(row)
            need(proc.returncode == 0, f'Subcommand {label} failed with exit {proc.returncode}')

        need(not list(empty_cwd.iterdir()), 'empty_cwd was polluted during execution')
    except BaseException as exc:
        all_ok = False
        error_type = type(exc).__name__

    after_cand = hc.verify_candidate_tree(args.manifest_sha)
    cand_unchanged = (after_cand == before_cand)
    after_sources = {rel: hc.pin(sources_root / rel) for rel in hc.SOURCE_ANCHORS}
    sources_unchanged = (after_sources == before_sources)

    smoke_summary = hc.strict_json((output / 'smoke1/summary.json').read_bytes()) if (output / 'smoke1/summary.json').is_file() else None
    fixed12_summary = hc.strict_json((output / 'fixed12/summary.json').read_bytes()) if (output / 'fixed12/summary.json').is_file() else None

    receipt = dict(
        schema='kws-full-hybrid-offline-receipt-v1',
        operation_success=bool(
            all_ok and cand_unchanged and sources_unchanged
            and smoke_summary is not None and smoke_summary['operation_success']
            and fixed12_summary is not None and fixed12_summary['operation_success']
            and unit_test_counts is not None and unit_test_counts['operation_success']
        ),
        candidate_manifest_sha256=args.manifest_sha,
        environment=dict(
            python=sys.version,
            system=platform.system(),
            machine=platform.machine(),
            numpy=numpy_version,
        ),
        elapsed_seconds=time.monotonic() - started,
        commands=commands,
        smoke1_summary_pin=hc.pin(output / 'smoke1/summary.json') if (output / 'smoke1/summary.json').is_file() else None,
        fixed12_summary_pin=hc.pin(output / 'fixed12/summary.json') if (output / 'fixed12/summary.json').is_file() else None,
        unit_test_counts=unit_test_counts,
        candidate_files_unchanged=cand_unchanged,
        frozen_sources_unchanged=sources_unchanged,
        error_type=error_type,
        vad_recomputed=False,
        vad_source='historical_fixed_pcm',
        board_access=False,
        real_lock_access=False,
        real_DMA_executed=False,
        real_cross_layer_PL_execution=False,
        promotion=False,
    )
    write_json_exclusive(output / 'receipt.json', receipt)
    print(json.dumps({
        'operation_success': receipt['operation_success'],
        'candidate_manifest_sha256': receipt['candidate_manifest_sha256'],
        'command_exits': [c['actual_exit'] for c in commands],
        'unit_test_counts': unit_test_counts,
        'candidate_files_unchanged': cand_unchanged,
        'frozen_sources_unchanged': sources_unchanged,
        'vad_recomputed': False,
        'board_access': False,
        'promotion': False,
    }, sort_keys=True))
    return 0 if receipt['operation_success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
