"""bx-approved missing-lock bootstrap only. No PYNQ/MMIO/Overlay imports.

Root launcher delegates exclusive creation/probing to existing xilinx uid1000.
Existing files are never truncated, removed, replaced, chmod'ed or chown'ed.
The real PCC worker must still acquire and hold its ORIGINAL session lock.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys


WORKER = r'''
import json, os, pathlib, stat
LOCK = '/tmp/opennpu-kws-chain.lock'

def scan_missing_lock_workloads(proc=pathlib.Path('/proc')):
    # Conservative signal only, NOT proof that no hardware user exists.
    allowed_servers = {'redirect_server', 'jupyter-notebook', 'jupyter-lab', 'jupyter-server'}
    for item in proc.iterdir():
        if not item.name.isdigit() or int(item.name) in (os.getpid(), APPROVED_LAUNCHER_PID):
            continue
        try:
            comm = (item/'comm').read_text().strip()
            if not comm.startswith(('python', 'arecord', 'aplay', 'cyclictest', 'stress', 'perf')):
                continue
            args = (item/'cmdline').read_bytes().split(b'\0')
        except FileNotFoundError:
            continue
        except OSError:
            raise RuntimeError('STOP: cannot inspect possible workload PID ' + item.name)
        script = next((pathlib.Path(arg.decode('utf-8', errors='replace')).name
            for arg in args[1:] if arg and not arg.startswith(b'-')), None)
        if comm.startswith('python') and script in allowed_servers:
            continue
        raise RuntimeError('STOP: missing lock with possible workload PID ' + item.name)

def bootstrap(os_api, stat_api, flock_api, missing_guard):
    if not hasattr(os_api, 'O_NOFOLLOW'):
        raise RuntimeError('STOP: O_NOFOLLOW unavailable; no fallback')
    created = False
    created_stat = None
    try:
        before = os_api.lstat(LOCK)
    except FileNotFoundError:
        missing_guard()
        try:
            fd = os_api.open(LOCK, os_api.O_WRONLY | os_api.O_CREAT |
                os_api.O_EXCL | os_api.O_NOFOLLOW, 0o644)
        except FileExistsError:
            raise RuntimeError('STOP: lock appeared during initialization; no retry')
        try:
            created_stat = os_api.fstat(fd)
            if not stat_api.S_ISREG(created_stat.st_mode):
                raise RuntimeError('STOP: newly created lock is not regular')
            os_api.fsync(fd)
            created = True
        finally:
            os_api.close(fd)
        before = os_api.lstat(LOCK)
        if (before.st_dev, before.st_ino) != (created_stat.st_dev, created_stat.st_ino):
            raise RuntimeError('STOP: newly created lock inode changed')
    if (not stat_api.S_ISREG(before.st_mode) or before.st_nlink != 1 or
            before.st_uid != 1000 or before.st_mode & 0o022):
        raise RuntimeError('STOP: unsafe lock type/owner/links/mode; no repair')
    fd = os_api.open(LOCK, os_api.O_RDONLY | os_api.O_NOFOLLOW | os_api.O_NONBLOCK)
    try:
        opened = os_api.fstat(fd)
        if (not stat_api.S_ISREG(opened.st_mode) or
                (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)):
            raise RuntimeError('STOP: lock inode changed during open')
        try:
            flock_api.flock(fd, flock_api.LOCK_EX | flock_api.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('STOP: canonical lock is busy; no retry or bypass')
        after = os_api.lstat(LOCK)
        if (not stat_api.S_ISREG(after.st_mode) or after.st_nlink != 1 or
                after.st_uid != 1000 or after.st_mode & 0o022 or
                (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)):
            raise RuntimeError('STOP: lock changed after acquisition')
        result = dict(success=True, created=created, path=LOCK, uid=after.st_uid,
            mode=oct(stat_api.S_IMODE(after.st_mode)), inode=after.st_ino, device=after.st_dev,
            exclusive_probe=True, full_board_idle_proven=False, hardware_access=False,
            session_lock_held=False, automatic_retry=False, existing_inode_modified=False)
    finally:
        os_api.close(fd)
    result['probe_descriptor_closed'] = True
    return result

def worker_main():
    try:
        if os.uname().machine != 'armv7l' or os.geteuid() != 1000:
            raise RuntimeError('STOP: exact ARMv7 xilinx uid1000 required')
        import fcntl
        result = bootstrap(os, stat, fcntl, scan_missing_lock_workloads)
    except BaseException as error:
        print(json.dumps(dict(success=False, error_type=type(error).__name__,
            error_message=str(error), hardware_access=False, automatic_retry=False)), flush=True)
        return 1
    print(json.dumps(result), flush=True)
    return 0

if __name__ == '__main__':
    raise SystemExit(worker_main())
'''


def guard_root():
    if platform.system() != 'Linux' or platform.machine() != 'armv7l' or os.geteuid() != 0:
        raise RuntimeError('STOP: existing root ARMv7 Jupyter terminal required; no PC execution')
    import pwd
    if pwd.getpwnam('xilinx').pw_uid != 1000:
        raise RuntimeError('STOP: xilinx account identity drift; no account repair')


def initialize(report_path):
    guard_root()  # Before subprocess or any path creation.
    report_path = Path(report_path)
    report = dict(scope='missing canonical lock bootstrap only', success=False,
        hardware_access=False, board_test_started=False, automatic_retry=False,
        session_lock_held=False)
    # Reserve evidence before any mutation. Never overwrite earlier evidence.
    with report_path.open('x', encoding='utf-8') as stream:
        try:
            code = ('APPROVED_LAUNCHER_PID = ' + str(os.getpid()) + '\n' + WORKER).encode('utf-8')
            done = subprocess.run(['/usr/sbin/runuser', '-u', 'xilinx', '--',
                '/usr/bin/python3', '-I', '-B', '-'], input=code, capture_output=True)
            report.update(actual_bootstrap_exit=done.returncode,
                stderr=done.stderr.decode('utf-8', errors='replace'))
            outcome = json.loads(done.stdout)
            report['worker'] = outcome
            if done.returncode != 0 or outcome.get('success') is not True:
                raise RuntimeError(outcome.get('error_message', 'STOP: bootstrap failed'))
            if (outcome.get('probe_descriptor_closed') is not True or
                    outcome.get('path') != '/tmp/opennpu-kws-chain.lock' or outcome.get('uid') != 1000):
                raise RuntimeError('STOP: incomplete bootstrap report')
            report['success'] = True
        except BaseException as error:
            report.update(error_type=type(error).__name__, error_message=str(error))
            raise
        finally:
            json.dump(report, stream, indent=2, allow_nan=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    try:
        report = initialize(args.report)
    except BaseException as error:
        print('LOCK BOOTSTRAP FAILED: ' + str(error), file=sys.stderr, flush=True)
        return 1
    state = 'created missing lock' if report['worker']['created'] else 'existing lock unchanged'
    print('LOCK READY: ' + state + '; exclusive probe released, worker must acquire session lock.', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
