# Mechanically derived from frozen candidate_08; original unchanged.
"""New batch-plan owner; derivative of unchanged matrix_owner_draft safety core.

No historical policy coercion, board CLI or automatic recovery retry. NumPy and
PYNQ dependencies are supplied only by a future sealed binding. Acquisition and
cleanup stay under the unchanged supervision wrapper, including quarantine.
"""
import math
import os
import threading

from os_evidence import ObservedLease
from batch_policy import BatchStop, validate_policy

_RETAINED = []


class BatchOwner:
    def __init__(self, policy, stop_requested, *, enabled=False):
        if enabled is not True or not callable(stop_requested):
            raise ValueError('new batch owner default-off; explicit stop source required')
        validate_policy(policy)
        self.policy, self.stop_requested = policy, stop_requested
        self._pid, self._thread = os.getpid(), threading.get_ident()
        self._guard = threading.Lock()
        self._lease = self._runner = self._recovery = None
        self._buffers = []
        self._held = self._unsafe = self._used = self._closed = False
        self._failures = []
        self._index = 0
        self.cleanup_readback = None

    def _owned(self):
        if (os.getpid(), threading.get_ident()) != (self._pid, self._thread):
            raise RuntimeError('batch owner process/thread ownership drift')

    def _hold(self, error):
        self._failures.append(type(error).__name__)
        if not self._held:
            self._held = True
            _RETAINED.append(self)

    @property
    def supervision_status(self):
        return dict(pid=self._pid, held=self._held, safety_unresolved=self._unsafe,
                    lease_retained=self._lease is not None, runner_retained=self._runner is not None,
                    root_buffers_retained=len(self._buffers), failure_types=tuple(self._failures),
                    automatic_retry=False, automatic_free=False, board_evidence=False)

    def _identity(self, phase):
        r = self._runner
        fresh = [r.mmio.read(x) for x in (0x60, 0x64, 0x12c, 8)]
        if (r.mmio is not self._mmio or r.dma is not self._dma
                or type(r.build_id) is not int or type(r.capabilities) is not int
                or r.build_id != 0x2026D075 or r.capabilities != 0x00080EFE
                or any(type(x) is not int for x in fresh)
                or fresh != [0x2026D075, 0x00080EFE, phase, 0]):
            raise RuntimeError('fresh D075 identity/phase/error drift')

    def _buffers_valid(self):
        import numpy as np
        for buf, size, channel in zip(self._buffers, self._extents, self._channels):
            address = getattr(buf, 'physical_address', None)
            if (not isinstance(buf, np.ndarray) or buf.dtype != np.dtype('uint8')
                    or buf.ndim != 1 or not buf.flags.c_contiguous or not buf.flags.writeable
                    or buf.nbytes != size or type(address) is not int
                    or not 0 <= address < 2**32 or address + size > 2**32
                    or type(channel._align) is not int or channel._align <= 0
                    or type(channel._dre) is not bool
                    or not channel._dre and address % channel._align
                    or type(channel._max_size) is not int or size > channel._max_size
                    or not callable(getattr(buf, 'freebuffer', None))):
                raise RuntimeError('root buffer extent/address/alignment drift')
        if len(self._buffers) == 2:
            tx, rx = self._buffers
            if (np.shares_memory(tx, rx) or max(tx.physical_address, rx.physical_address) <
                    min(tx.physical_address + tx.nbytes, rx.physical_address + rx.nbytes)):
                raise RuntimeError('DMA roots alias')

    def start(self, runner_type, bit_path, unchanged_lease_factory, recovery_factory):
        self._owned()
        if self._used or self._closed or self.stop_requested() is not False:
            raise RuntimeError('owner already used or stop pending before acquisition')
        self._used = True
        # Bind observation BEFORE enter: enter may acquire the real lock then
        # fail its audit. Such a lease must stay reachable under supervision.
        self._lease = ObservedLease(unchanged_lease_factory)
        try:
            self._lease.__enter__()
            self._unsafe = True
            self._runner = runner_type.__new__(runner_type)
            runner_type.__init__(self._runner, bit_path)
            r = self._runner
            self._mmio, self._dma = r.mmio, r.dma
            if r.pynq_version != '3.1.1' or r._pynq.Clocks.fclk0_mhz != 100.:
                raise RuntimeError('unchanged PYNQ3.1.1/100MHz required')
            self._channels = (r.dma.sendchannel, r.dma.recvchannel)
            self._dma_mmio = self._channels[0]._mmio
            self._identity(1)
            self._recovery = recovery_factory(r, timeout=1., enabled=True)
            if self._recovery.recover_and_confirm(r) is not True:
                raise RuntimeError('initial bounded recovery not confirmed')
            self._identity(1)
            self._extents = (4198400, 1048576)  # 64*64B headers + 512^3 panel bytes, INT32 C
            import numpy as np
            for extent in self._extents:
                self._buffers.append(r._allocate(shape=(extent,), dtype=np.uint8))
                self._buffers_valid()
            self._unsafe = False
            self.pre_submit()
        except BaseException as error:
            if self._lease is not None and not self._lease.entered and self._runner is None:
                self._lease = None  # helper failed before retaining a real lease
            elif isinstance(error, BatchStop) and not self._unsafe:
                pass  # Safe initialization completed; operation finally closes it.
            else:
                self._hold(error)
            raise

    def pre_submit(self):
        """Fresh guardian/lock/hardware readback, not an authorization token."""
        self._owned()
        if self.stop_requested() is not False:
            raise BatchStop('stop requested; no submission')
        if self._closed or self._held or self._unsafe or len(self._buffers) != 2:
            raise RuntimeError('owner unhealthy; no submission')
        proof = self._lease.audit()
        r = self._runner
        if (r.mmio is not self._mmio or r.dma is not self._dma
                or r.dma.sendchannel is not self._channels[0] or r.dma.recvchannel is not self._channels[1]):
            raise RuntimeError('owned MMIO/DMA/channel drift')
        for channel, offset in zip(self._channels, (0, 0x30)):
            if channel._mmio is not self._dma_mmio or channel._offset != offset:
                raise RuntimeError('DMA mapping/offset drift')
            cr, sr = channel._mmio.read(offset), channel._mmio.read(offset + 4)
            if (type(cr) is not int or type(sr) is not int or cr & 4 or not cr & 1 or sr & (1 | 0x770)
                    or not sr & 2 and not (channel._first_transfer is True and channel._active_buffer is None)):
                raise RuntimeError('DMA not ready')
        phase = r.mmio.read(0x12c)
        if type(phase) is not int or phase not in (1, 2):
            raise RuntimeError('pre-submit counter phase drift')
        self._identity(phase)
        status = r.mmio.read(4)
        if type(status) is not int or status & (2 | 8) or not status & (1 | 4):
            raise RuntimeError('accelerator not IDLE/DONE')
        self._buffers_valid()
        return proof

    def execute_chain(self, jobs, **options):
        self._owned()
        if not self._guard.acquire(blocking=False):
            raise RuntimeError('batch owner busy/reentrant')
        returned = None
        try:
            validate_policy(self.policy)
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

    def close(self):
        self._owned()
        if not self._guard.acquire(blocking=False):
            raise RuntimeError('cannot close active batch owner')
        try:
            if self._held or self._unsafe:
                raise RuntimeError('quarantined resources cannot be freed automatically')
            if self._closed:
                return
            try:
                proof = self._lease.audit() if self._lease is not None else None
                terminal = None
                if self._runner is not None:
                    self._unsafe = True
                    if self._recovery.recover_and_confirm(self._runner) is not True:
                        raise RuntimeError('cleanup bounded recovery not confirmed')
                    self._identity(1)
                    terminal = dict(build_id=self._runner.mmio.read(0x60), phase=self._runner.mmio.read(0x12c),
                                    error=self._runner.mmio.read(8),
                                    recovery=self._recovery.last_diagnostics)
                    self._unsafe = False
                while self._buffers:
                    self._buffers[-1].freebuffer()
                    self._buffers.pop()
                self._runner = self._recovery = None
                self._channels = self._mmio = self._dma = self._dma_mmio = None
                if self._lease is not None:
                    self._lease.__exit__(None, None, None)
                    self._lease = None
                self._closed = True
                self.cleanup_readback = dict(terminal=terminal, last_lock_proof=proof,
                                              resources=self.supervision_status,
                                              source='owner recovery/readback/freebuffer/helper-close lifecycle')
            except BaseException as error:
                self._hold(error)
                raise
        finally:
            self._guard.release()

