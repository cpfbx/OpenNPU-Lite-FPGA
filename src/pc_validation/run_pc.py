"""Portable PC checks: retained shared-chain arithmetic, Skills, supplemental cleanup.

No downloads, board commands, builds, dependency installation, or lock operations.
"""
import argparse
import hashlib
import json
import os
import platform
import stat
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from cleanup_audit import require, strict_json


def pin(path):
    raw = path.read_bytes()
    return dict(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'plain input tree')
        if path.is_file():
            result[path.relative_to(root).as_posix()] = pin(path)
    return result


def verify(expected):
    manifest = ROOT / 'manifest.json'
    require(pin(manifest)['sha256'] == expected, 'external candidate manifest pin')
    wanted = strict_json(manifest.read_bytes())['files']
    actual = inventory(ROOT)
    actual.pop('manifest.json')
    require(actual == wanted, 'candidate file set, size or SHA drift')
    return actual


def unpack(source, target):
    # ZIPs are externally pinned before this function is reached.
    target.mkdir()
    seen = set()
    with zipfile.ZipFile(source) as archive:
        require(len(archive.infolist()) <= 1500, 'bounded ZIP entries')
        total = 0
        for item in archive.infolist():
            name = item.filename
            path = PurePosixPath(name)
            require(name and '\\' not in name and ':' not in name and
                    not path.is_absolute() and '..' not in path.parts and
                    path.as_posix() == name.rstrip('/'), 'plain ZIP paths')
            # Case aliases are rejected even on case-sensitive hosts.
            key = name.casefold()
            require(key not in seen, 'duplicate or case-alias ZIP path')
            seen.add(key)
            mode = item.external_attr >> 16
            require(not stat.S_ISLNK(mode) and not item.flag_bits & 1, 'plain unencrypted ZIP')
            total += item.file_size
            require(total <= 128 * 1024 * 1024 and item.file_size <= 32 * 1024 * 1024,
                    'bounded ZIP sizes')
            dest = target.joinpath(*path.parts)
            require(dest.resolve().is_relative_to(target.resolve()), 'contained ZIP path')
            if item.is_dir():
                dest.mkdir(parents=True, exist_ok=True)
            else:
                dest.parent.mkdir(parents=True, exist_ok=True)
                with dest.open('xb') as stream:
                    stream.write(archive.read(item))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest-sha', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', choices=('integrity', 'pc'), default='pc')
    args = parser.parse_args()
    before = verify(args.manifest_sha)
    output = args.output.resolve()
    require(not output.exists() and not output.is_relative_to(ROOT) and
            not ROOT.is_relative_to(output) and output.parent.is_dir(), 'fresh external output')
    output.mkdir()
    cwd = output / 'empty_cwd'
    cwd.mkdir()
    rows = []

    def run(label, script, arguments=()):
        command = [sys.executable, '-I', '-B', str(script), *map(str, arguments)]
        result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (output / (label + '.stdout.txt')).write_bytes(result.stdout)
        (output / (label + '.stderr.txt')).write_bytes(result.stderr)
        row = dict(label=label, argv=command, actual_exit=result.returncode)
        rows.append(row)
        require(result.returncode == 0, 'PC command failed: ' + label)
        if label == 'skill_90_methods':
            counts = strict_json(result.stdout.decode('utf8').strip().splitlines()[-1])
            for field in ('tests_run', 'failures', 'errors', 'skipped'):
                require(type(counts.get(field)) is int and counts[field] >= 0, 'exact test counts')
            require(counts['failures'] == counts['errors'] == 0 and
                    counts['skipped'] <= counts['tests_run'], 'Skill test outcomes')
            row['test_counts'] = counts

    success = False
    error = None
    try:
        if args.profile == 'pc':
            import numpy
            numpy_version = numpy.__version__
        else:
            numpy_version = 'not imported'
        run('cleanup_tests', ROOT / 'test_cleanup_audit.py')
        run('cleanup_original', ROOT / 'cleanup_audit.py',
            ['--archive', ROOT / 'inputs/shared12_evidence_v1.tar.gz'])
        if args.profile == 'pc':
            shared = output / 'shared_bundle'
            unpack(ROOT / 'inputs/shared_readback_review.zip', shared)
            run('shared_readback', shared / 'portable_checks.py', [
                '--manifest-sha', '52abba8e002803e062c2419e5562cec97a4c6272dc0eee6773459c4d4e37594a',
                '--output', output / 'shared_validation'])
            skill = output / 'skill_bundle'
            unpack(ROOT / 'inputs/skill_v3_review.zip', skill)
            root = skill / 'candidate'
            skill_before = inventory(root)
            commands = [
                ('skill_identity_before', 'verify_candidate.py', []),
                ('skill_90_methods', 'tests/run_tests.py', []),
                ('skill_gemm_selftest', 'skill/pynq-gemm-validation/scripts/validate_gemm_evidence.py', ['--self-test']),
                ('skill_resilience_selftest', 'skill/pynq-gemm-validation/scripts/validate_resilience_evidence.py', ['--self-test']),
                ('skill_link_example', 'skill/engineering-evidence-review/scripts/check_evidence_links.py',
                 [root / 'evaluation/link_example.json', '--root', root / 'evaluation/fixtures']),
                ('skill_identity_after', 'verify_candidate.py', [])]
            for label, script, arguments in commands:
                run(label, root / script, arguments)
            require(inventory(root) == skill_before, 'Skill tree changed')
        verify(args.manifest_sha)
        require(not list(cwd.iterdir()), 'empty working directory retained')
        success = True
    except Exception as exc:
        # Only a bounded class name is recorded; command stderr is in separate raw logs.
        error = type(exc).__name__
        if 'numpy_version' not in locals():
            numpy_version = 'unavailable'
    unchanged = inventory(ROOT)
    unchanged.pop('manifest.json')
    unchanged = unchanged == before
    skipped = sum(row.get('test_counts', {}).get('skipped', 0) for row in rows)
    result = dict(operation_success=success and unchanged, profile=args.profile,
                  python=sys.version, system=platform.system(), machine=platform.machine(),
                  numpy=numpy_version, commands=rows, error_type=error,
                  input_files_unchanged=unchanged, board_access=False,
                  live_lock_access=False, inference_reexecuted=False,
                  vivado_build_executed=False, rtl_regression_executed=False,
                  scope=('PC retained shared12 math + selected Skill checks + supplemental cleanup'
                         if args.profile == 'pc' else 'supplemental cleanup only'),
                  skipped_tests=skipped, all_selected_tests_executed=success and skipped == 0,
                  not_run=([] if args.profile == 'pc' else ['shared-chain arithmetic', 'Skill checks']),
                  independent_review_completed=False, promotion=False)
    (output / 'receipt.json').write_text(json.dumps(result, sort_keys=True, indent=2) + '\n', encoding='utf8')
    print(json.dumps(result))
    return 0 if result['operation_success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
