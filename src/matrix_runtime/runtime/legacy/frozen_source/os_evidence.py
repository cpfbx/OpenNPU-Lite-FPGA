"""Read-only Linux evidence around the UNCHANGED existing canonical lock helper.

No flock acquisition, descriptor duplication, lock creation or process killing.
Same-process trusted code and no concurrent descriptor manipulation required.
"""
import errno
import os
from pathlib import Path
import re
import stat
import threading

LOCK = '/tmp/opennpu-kws-chain.lock'


def parse_fdinfo(text, *, pid, device, inode):
    if type(text) is not str or len(text) > 65536:
        raise ValueError('bounded fdinfo required')
    flags, locks, found_inode = [], [], []
    for line in text.splitlines():
        if line.startswith('flags:'):
            flags.append(int(line.split(':', 1)[1].strip(), 8))
        elif line.startswith('ino:'):
            found_inode.append(int(line.split(':', 1)[1].strip()))
        elif line.startswith('lock:'):
            locks.append(line.split(':', 1)[1].split())
    if len(flags) != 1 or found_inode != [inode] or len(locks) != 1:
        raise ValueError('exact owned lock descriptor fields required')
    row = locks[0]
    if (len(row) != 8 or re.fullmatch(r'[0-9]+:', row[0]) is None
            or row[1:4] != ['FLOCK', 'ADVISORY', 'WRITE']
            or row[4] != str(pid) or row[6:] != ['0', 'EOF']):
        raise ValueError('exclusive whole-file FLOCK owned by guardian required')
    parts = row[5].split(':')
    if (len(parts) != 3 or int(parts[0], 16) != os.major(device)
            or int(parts[1], 16) != os.minor(device) or int(parts[2]) != inode):
        raise ValueError('kernel lock device/inode mismatch')
    # Linux O_CLOEXEC is octal 02000000; no platform-dependent Windows constant.
    if not flags[0] & 0o2000000:
        raise ValueError('CLOEXEC required; lock may not survive into child')
    return dict(pid=pid, device=device, inode=inode, exclusive_flock=True, cloexec=True)


def process_start(raw):
    """/proc/PID/stat field 22; comm can itself contain spaces/parentheses."""
    if type(raw) is not str or len(raw) > 8192 or ')' not in raw:
        raise ValueError('bounded proc stat required')
    fields = raw[raw.rfind(')') + 1:].split()
    if len(fields) < 20 or not fields[19].isdigit():
        raise ValueError('process start ticks required')
    return int(fields[19])


def read_text(path, limit=65536):
    with Path(path).open('rb') as f:
        raw = f.read(limit + 1)
    if len(raw) > limit:
        raise ValueError('proc evidence exceeds budget')
    return raw.decode('ascii')


class ObservedLease:
    """Observe the helper's original fd without acquiring a second lock.

    Keep this object reachable if acquisition succeeded but observation failed;
    the real owner marks quarantine and the unchanged supervisor retains it.
    """
    def __init__(self, unchanged_factory):
        self.factory = unchanged_factory
        self.context = None
        self.fd = None
        self.identity = None
        self.entered = False
        self.released = False
        self.pid, self.thread = os.getpid(), threading.get_ident()

    def _owned(self):
        if (os.getpid(), threading.get_ident()) != (self.pid, self.thread):
            raise RuntimeError('lock observer process/thread ownership drift')

    def __enter__(self):
        self._owned()
        if os.name != 'posix' or not Path('/proc/self/fdinfo').is_dir() or self.context is not None:
            raise RuntimeError('single-use Linux proc observer required')
        before = os.lstat(LOCK)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError('canonical existing single-link regular lock required')
        self.identity = (before.st_dev, before.st_ino)
        self.context = self.factory()
        self.context.__enter__()
        self.entered = True
        candidates = []
        for entry in Path('/proc/self/fd').iterdir():
            try:
                fd = int(entry.name)
                opened = os.fstat(fd)
            except OSError as error:
                if error.errno == errno.EBADF:
                    continue
                raise
            if (opened.st_dev, opened.st_ino) == self.identity:
                candidates.append(fd)
        if len(candidates) != 1:
            raise RuntimeError('one original canonical lock fd required; retain on ambiguity')
        self.fd = candidates[0]
        self.audit()
        return self

    def audit(self):
        self._owned()
        if not self.entered or self.released or self.fd is None:
            raise RuntimeError('no observed live canonical lease')
        pathname, opened = os.lstat(LOCK), os.fstat(self.fd)
        if (not stat.S_ISREG(pathname.st_mode) or pathname.st_nlink != 1
                or (pathname.st_dev, pathname.st_ino) != self.identity
                or (opened.st_dev, opened.st_ino) != self.identity
                or os.get_inheritable(self.fd)):
            raise RuntimeError('canonical lock descriptor/path identity drift')
        proof = parse_fdinfo(read_text('/proc/self/fdinfo/%d' % self.fd), pid=self.pid,
                             device=opened.st_dev, inode=opened.st_ino)
        proof.update(fd=self.fd, process_start_ticks=process_start(read_text('/proc/self/stat', 8192)),
                     path=LOCK, source='original fd fstat + kernel fdinfo FLOCK',
                     physical_identity_authenticated=False)
        return proof

    def __exit__(self, *exc):
        self._owned()
        self.audit()
        self.context.__exit__(*exc)  # Only unchanged helper closes its descriptor.
        try:
            os.fstat(self.fd)
        except OSError as error:
            if error.errno != errno.EBADF:
                raise
        else:
            raise RuntimeError('original descriptor closure not proven')
        self.released = True


def verify_guardian_ticket(ticket):
    """CPU child checks parent-owned lock; child NEVER acquires/inherits it."""
    if type(ticket) is not dict or ticket.get('path') != LOCK:
        raise ValueError('canonical guardian lock ticket required')
    for name in ('pid', 'fd', 'device', 'inode', 'process_start_ticks'):
        if type(ticket.get(name)) is not int or ticket[name] < (0 if name in ('fd', 'device') else 1):
            raise ValueError('integer guardian identity required')
    if os.getppid() != ticket['pid']:
        raise RuntimeError('CPU child must still have guardian parent')
    st = os.lstat(LOCK)
    if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1
            or (st.st_dev, st.st_ino) != (ticket['device'], ticket['inode'])):
        raise RuntimeError('CPU observed canonical path drift')
    root = Path('/proc') / str(ticket['pid'])
    if process_start(read_text(root / 'stat', 8192)) != ticket['process_start_ticks']:
        raise RuntimeError('guardian PID identity reused')
    opened = (root / 'fd' / str(ticket['fd'])).stat()
    if (opened.st_dev, opened.st_ino) != (ticket['device'], ticket['inode']):
        raise RuntimeError('guardian fd inode drift')
    parse_fdinfo(read_text(root / 'fdinfo' / str(ticket['fd'])), pid=ticket['pid'],
                 device=ticket['device'], inode=ticket['inode'])
    # Guardian's exact fd number must not be an inherited lock fd here.
    for entry in Path('/proc/self/fd').iterdir():
        try:
            own = entry.stat()
        except FileNotFoundError:
            continue
        if (own.st_dev, own.st_ino) == (ticket['device'], ticket['inode']):
            raise RuntimeError('CPU inherited canonical lock descriptor')
    return True


def process_group_absent(pid):
    if type(pid) is not int or pid <= 1:
        raise ValueError('exact child process-group id required')
    try:
        os.killpg(pid, 0)  # Read-only presence query, not a termination signal.
    except ProcessLookupError:
        return True
    return False  # Permissions/other errors propagate as unknown, never absence.
