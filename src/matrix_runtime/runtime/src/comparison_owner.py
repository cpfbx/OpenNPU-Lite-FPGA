"""New exact comparison policy; entry safety and all inherited resource proofs unchanged.
Generated methods have explicit AST-equivalence tests against pinned legacy.
No global patch of legacy validation, helper, owner or pack.
"""
import math
import os
import threading
from owner_entry_candidate import EntrySafeBatchOwner
from lease_entry_candidate import EntrySafeObservedLease
from batch_policy import BatchStop
from comparison_policy import validate_fpga_policy


class ComparisonOwner(EntrySafeBatchOwner):
    def __init__(self, policy, stop_requested, *, enabled=False):
        if enabled is not True or not callable(stop_requested):
            raise ValueError('new batch owner default-off; explicit stop source required')
        validate_fpga_policy(policy)
        self.policy, self.stop_requested = policy, stop_requested
        self._pid, self._thread = os.getpid(), threading.get_ident()
        self._guard = threading.Lock()
        self._lease = self._runner = self._recovery = None
        self._buffers = []
        self._held = self._unsafe = self._used = self._closed = False
        self._failures = []
        self._index = 0
        self.cleanup_readback = None

    def start(self,runner_type,bit_path,unchanged_lease_factory,recovery_factory):
        self._owned()
        if self._used or self._closed or self.stop_requested() is not False:
            raise RuntimeError('owner already used or stop pending before acquisition')
        self._used=True
        self._lease=EntrySafeObservedLease(unchanged_lease_factory)
        try:
            self._lease.__enter__()
            self._unsafe=True
            self._runner=runner_type.__new__(runner_type)
            runner_type.__init__(self._runner,bit_path)
            r=self._runner
            self._mmio,self._dma=r.mmio,r.dma
            if r.pynq_version!='3.1.1' or r._pynq.Clocks.fclk0_mhz!=100.:
                raise RuntimeError('unchanged PYNQ3.1.1/100MHz required')
            self._channels=(r.dma.sendchannel,r.dma.recvchannel)
            self._dma_mmio=self._channels[0]._mmio
            self._identity(1)
            self._recovery=recovery_factory(r,timeout=1.,enabled=True)
            if self._recovery.recover_and_confirm(r) is not True:
                raise RuntimeError('initial bounded recovery not confirmed')
            self._identity(1)
            self._extents=(self.policy.geometry.input_bytes,self.policy.geometry.output_bytes)
            import numpy as np
            for extent in self._extents:
                self._buffers.append(r._allocate(shape=(extent,),dtype=np.uint8))
                self._buffers_valid()
            self._unsafe=False
            self.pre_submit()
        except BaseException as error:
            if (self._lease is not None and self._runner is None
                    and getattr(self._lease,'acquisition_attempted',None) is False
                    and self._lease.entered is False and self._lease.context is None):
                self._lease=None  # Proven pre-factory failure; no helper invoked.
            elif self._lease is not None and self._runner is None:
                # Includes factory/enter failure, including BatchStop. "entered"
                # False is NOT a release proof. Retain the object for the
                # REQUIRED unchanged exit-safety supervisor's process hold.
                self._unsafe=True
                self._hold(error)
            elif isinstance(error,BatchStop) and not self._unsafe:
                pass  # Same safe-stop-after-initialization behavior as baseline.
            else:
                self._hold(error)
            raise

    def execute_chain(self, jobs, **options):
        self._owned()
        if not self._guard.acquire(blocking=False):
            raise RuntimeError('batch owner busy/reentrant')
        returned = None
        try:
            validate_fpga_policy(self.policy)
            spec = self.policy.request(self._index)
            if (type(jobs) is not list or len(jobs) != spec.jobs
                    or any((j.matrix_m, j.matrix_n, j.matrix_k) != spec.shape for j in jobs)
                    or set(options) != {'first_job_id', 'timeout_s', 'mode_override', 'launch_order', 'profile_host'}
                    or type(options['first_job_id']) is not int or options['first_job_id'] != spec.first_job_id
                    or type(options['mode_override']) is not int or options['mode_override'] != 11
                    or options['launch_order'] != 'dma-first' or options['profile_host'] is not True
                    or type(options['timeout_s']) not in (int, float)
                    or not math.isfinite(options['timeout_s']) or not 0 < options['timeout_s'] <= 60):
                raise ValueError('explicit batch schedule/options drift')
            self.pre_submit()
            # Last check immediately before the original driver's submit call.
            if self.stop_requested() is not False:
                raise BatchStop('stop latched before complete run_chain request')
            self._unsafe = True
            returned = self._runner.run_chain(jobs, *self._buffers, **options)
            self._identity(2)
            status = self._runner.mmio.read(4)
            if type(status) is not int or status & (2 | 4 | 8) != 4:
                raise RuntimeError('MODE11 clean DONE not observed')
            for channel in self._channels:
                cr, sr = (channel._mmio.read(channel._offset), channel._mmio.read(channel._offset + 4))
                if type(cr) is not int or type(sr) is not int or cr & 4 or not cr & 1 or not sr & 2 or sr & (1 | 0x770):
                    raise RuntimeError('DMA completion not quiescent')
            self._unsafe = False
            self._index += 1
            return returned
        except BaseException as error:
            if self._runner is not None and not (isinstance(error, BatchStop) and not self._unsafe):
                self._hold(error)
            if isinstance(returned, tuple) and len(returned) == 3 and type(returned[0]) is bytes:
                error.matrix_returned_payload = returned[0]
            raise
        finally:
            self._guard.release()
