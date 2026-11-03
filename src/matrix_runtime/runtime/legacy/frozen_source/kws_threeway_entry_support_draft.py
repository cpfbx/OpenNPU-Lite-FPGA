"""Unreleased entry support: no Overlay construction or board RUN command.

The CLI always refuses execution. Lock/runner helpers are for a future reviewed
entry; PC tests inject OS calls and registers. The child-exit harness is desktop
x86 only. None of these consistency checks authenticates a physical board.
"""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys


SHARED_LOCK = '/tmp/opennpu-kws-chain.lock'
D075_BUILD = 0x2026D075
D075_CAPABILITIES = 0x00080EFE


@contextmanager
def existing_shared_lock_draft():
    """Borrow the existing canonical inode, never create/truncate/unlink it.

    Missing/busy/changed/unsafe lock means stop. No lease, retry, replacement,
    alternate name or privilege workaround. Hold across initialization, all
    child execution and cleanup in the future approved caller.
    """
    import fcntl  # POSIX only; PC tests substitute a fake, not a board call.
    if not hasattr(os, 'O_NOFOLLOW'):
        raise RuntimeError('O_NOFOLLOW required; no weakened lock fallback')
    before = os.lstat(SHARED_LOCK)
    if not stat.S_ISREG(before.st_mode):
        raise ValueError('existing regular shared lock required')
    fd = os.open(SHARED_LOCK, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    primary = None
    try:
        opened = os.fstat(fd)
        if (not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
            raise ValueError('shared lock inode changed during open')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        after = os.lstat(SHARED_LOCK)
        if (not stat.S_ISREG(after.st_mode)
                or (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)):
            raise ValueError('shared lock inode changed after acquisition')
        yield
    except BaseException as exc:
        primary = exc
        raise
    finally:
        try:
            os.close(fd)  # Closes this owned descriptor; never deletes the lock.
        except BaseException as exc:
            if primary is None:
                raise
            if callable(getattr(primary, 'add_note', None)):
                primary.add_note('Shared lock descriptor close failed: ' + type(exc).__name__)


def check_d075_runner_draft(runner):
    """Fresh register reads, not only constructor-cached values. No reset.

    Caller must already own the shared lock. This does NOT validate clocks,
    BIT bytes, physical serial, image provenance or authorization; package and
    runtime checks remain separate prerequisites.
    """
    from pynq_dma_loopback import REG_BUILD_ID, REG_CAPABILITIES
    cached = (runner.build_id, runner.capabilities)
    if (any(type(value) is not int for value in cached)
            or cached != (D075_BUILD, D075_CAPABILITIES)):
        raise ValueError('cached D075 runner identity mismatch')
    raw = (runner.mmio.read(REG_BUILD_ID), runner.mmio.read(REG_CAPABILITIES))
    # MMIO may return a NumPy integer; reject bool/float/string coercions.
    import numbers
    if any(isinstance(value, bool) or not isinstance(value, numbers.Integral) for value in raw):
        raise ValueError('integer hardware register values required')
    fresh = tuple(int(value) for value in raw)
    if fresh != cached:
        raise ValueError('fresh D075 register identity drift')
    return dict(build_id=f'0x{fresh[0]:08x}', capabilities=f'0x{fresh[1]:08x}',
                scope='runner-register-consistency-only',
                physical_board_authenticated=False, clock_verified=False,
                image_verified=False, board_run_authorized=False, promotion=False)


def _write_new_json(path, value):
    with Path(path).open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=True, sort_keys=True, allow_nan=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def capture_pc_child_exit_draft(command, directory):
    """Capture an actual desktop child exit, never infer it from journal complete.

    A fresh directory is mandatory; stdout/stderr and request survive failure.
    No shell, retry, resume, timeout-as-success, stats/promotion or board launch.
    This harness has no shared-board-lock claim: it is a PC-only OS-path test.
    The formal board supervisor must be separately wired/reviewed/approved.
    """
    if platform.machine().lower() not in ('amd64', 'x86_64', 'x86', 'i386', 'i686'):
        raise RuntimeError('desktop x86 child harness only; board execution forbidden')
    if (type(command) is not list or not command
            or any(type(arg) is not str or '\0' in arg for arg in command)
            or Path(command[0]).resolve() != Path(sys.executable).resolve()):
        raise ValueError('explicit local Python child argument list required')
    root = Path(directory)
    root.mkdir()  # Parents must exist; never overwrite or continue an old run.
    _write_new_json(root / 'request.json', dict(command=command,
        scope='desktop-child-exit-draft', board_evidence=False,
        performance_evaluated=False, promotion=False, default_changed=False))
    try:
        with (root / 'child.log').open('xb') as log:
            flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
            done = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                  shell=False, check=False, creationflags=flags)
            log.flush()
            os.fsync(log.fileno())
    except BaseException as primary:
        try:
            _write_new_json(root / 'supervisor_failure.json', dict(
                error_type=type(primary).__name__, actual_child_exit_code=None,
                completion_unknown=True, board_evidence=False, promotion=False))
        except BaseException as secondary:
            if callable(getattr(primary, 'add_note', None)):
                primary.add_note('Secondary failure while preserving supervisor status: '
                                 + type(secondary).__name__)
        raise
    # If this write fails, preserve log and propagate: no external exit proof.
    result = dict(actual_child_exit_code=done.returncode,
                  child_exited_zero=done.returncode == 0,
                  source='subprocess returncode, not a journal marker',
                  board_evidence=False, performance_evaluated=False,
                  promotion=False, default_changed=False)
    _write_new_json(root / 'child_exit.json', result)
    return result


def main(argv=None):
    print('UNRELEASED entry draft: board execution disabled; no enable switch.', file=sys.stderr)
    print('Independent supplemental review and bx contract/package approval required.', file=sys.stderr)
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
