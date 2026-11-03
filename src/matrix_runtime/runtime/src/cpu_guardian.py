"""CPU-only holder of the ORIGINAL canonical lease; no overlay, lock creation or retry."""
import os
import threading
from lease_entry_candidate import EntrySafeObservedLease
from comparison_policy import validate_policy
from batch_policy import BatchStop

_RETAINED=[]


class CpuGuardian:
    def __init__(self,policy,stopped,*,enabled=False):
        if enabled is not True or not callable(stopped):raise ValueError('CPU guardian default-off')
        validate_policy(policy)
        if policy.backend!='openblas_2t':raise ValueError('exact CPU block required')
        self.policy,self.stopped=policy,stopped
        self._pid,self._thread=os.getpid(),threading.get_ident()
        self._lease=None;self._used=self._closed=self._held=self._unsafe=False
        self._children=[];self._failures=[];self.cleanup_readback=None

    def _owned(self):
        if (os.getpid(),threading.get_ident())!=(self._pid,self._thread):
            raise RuntimeError('CPU guardian process/thread drift')

    @property
    def supervision_status(self):
        return dict(pid=self._pid,held=self._held,safety_unresolved=self._unsafe,
            lease_retained=self._lease is not None,runner_retained=bool(self._children),
            root_buffers_retained=0,child_processes_retained=len(self._children),
            failure_types=tuple(self._failures),automatic_retry=False,automatic_free=False,
            board_evidence=False)

    def _hold(self,error):
        self._failures.append(type(error).__name__);self._unsafe=True
        if not self._held:self._held=True;_RETAINED.append(self)

    def start(self,unchanged_factory):
        self._owned()
        if self._used or self._closed or self.stopped() is not False:
            raise RuntimeError('guardian single-use; stop or reuse before acquisition')
        self._used=True;self._lease=EntrySafeObservedLease(unchanged_factory)
        acquisition_completed=False
        try:
            self._lease.__enter__();acquisition_completed=True
            self.pre_submit()
        except BaseException as error:
            lease=self._lease
            if (lease is not None and getattr(lease,'acquisition_attempted',None) is False
                    and lease.entered is False and lease.context is None):
                self._lease=None
            elif isinstance(error,BatchStop) and acquisition_completed and not self._unsafe:
                pass
            else:self._hold(error)
            raise

    def pre_submit(self):
        self._owned()
        if self.stopped() is not False:raise BatchStop('CPU stop; no launch or next GO')
        if self._closed or self._held or self._unsafe or self._lease is None:
            raise RuntimeError('CPU guardian unhealthy')
        try:return self._lease.audit()
        except BaseException as error:self._hold(error);raise

    def retain_child(self,child):
        self._owned()
        if self._children:raise RuntimeError('one CPU child only')
        self._children.append(child)

    def forget_child(self,child):
        self._owned()
        if self._children!=[child]:raise RuntimeError('exact observed CPU child required')
        self._children.clear()

    def close(self):
        self._owned()
        if self._held or self._unsafe:raise RuntimeError('quarantined CPU lease cannot auto-close')
        if self._closed:return
        if self._children:
            error=RuntimeError('CPU child lifecycle unresolved');self._hold(error);raise error
        try:
            proof=self._lease.audit() if self._lease is not None else None
            if self._lease is not None:self._lease.__exit__(None,None,None);self._lease=None
            self._closed=True
            self.cleanup_readback=dict(last_lock_proof=proof,resources=self.supervision_status,
                source='original helper closure verified by inherited observer; no PL resources')
        except BaseException as error:self._hold(error);raise
