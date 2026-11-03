"""Derivative of frozen BatchOwner: conservative lease-entry failure handling.

Only start is overridden. Submission, stop boundary, close, policy, DMA and
counter checks remain inherited. No automatic release/retry from quarantine.
"""
import batch_owner as frozen
from batch_policy import BatchStop
from lease_entry_candidate import EntrySafeObservedLease


class EntrySafeBatchOwner(frozen.BatchOwner):
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
            self._extents=(4198400,1048576)
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
