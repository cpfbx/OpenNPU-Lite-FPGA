"""Mark an acquisition attempt BEFORE invoking an opaque canonical helper.

No new flock/descriptor/lock path. Uncertain helper failures stay quarantined.
The original ObservedLease audit/exit/proc proofs remain inherited unchanged.
"""
import errno
import stat
from pathlib import Path
import os

from os_evidence import ObservedLease,LOCK


class EntrySafeObservedLease(ObservedLease):
    def __init__(self,unchanged_factory):
        super().__init__(unchanged_factory)
        self.acquisition_attempted=False

    def __enter__(self):
        self._owned()
        if (os.name!='posix' or not Path('/proc/self/fdinfo').is_dir()
                or self.context is not None or self.acquisition_attempted is not False):
            raise RuntimeError('single-use Linux proc observer required')
        before=os.lstat(LOCK)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1:
            raise ValueError('canonical existing single-link regular lock required')
        self.identity=(before.st_dev,before.st_ino)
        # Before the factory as well: failure to return a context is NOT proof
        # that trusted factory code made no acquisition/cleanup attempt.
        self.acquisition_attempted=True
        self.context=self.factory()
        self.context.__enter__()
        self.entered=True
        candidates=[]
        for entry in Path('/proc/self/fd').iterdir():
            try:
                fd=int(entry.name)
                opened=os.fstat(fd)
            except OSError as error:
                if error.errno==errno.EBADF:
                    continue
                raise
            if (opened.st_dev,opened.st_ino)==self.identity:
                candidates.append(fd)
        if len(candidates)!=1:
            raise RuntimeError('one original canonical lock fd required; retain on ambiguity')
        self.fd=candidates[0]
        self.audit()
        return self
