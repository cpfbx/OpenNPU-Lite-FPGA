"""Private bounded recovery adapter. No allocation/freeing or executable entry.

Reuse the unchanged instance-wide Simple-DMA reset/resync and accelerator soft
reset. A snapshot/truthy object is never a quiescence certificate. This is not
proof of physical hardware recovery until bx runs an approved device test.
"""
import math
import os
import threading

from pynq_dma_loopback import (reset_simple_dma, wait_until, CONTROL_SOFT_RESET,
    STATUS_IDLE, STATUS_BUSY, STATUS_ERROR, DMA_DMACR_RESET,
    DMA_DMASR_HALTED, DMA_DMASR_ERROR_MASK)


class _Recovery:
    def __init__(self, runner, *, timeout=1., enabled=False):
        if enabled is not True:
            raise ValueError('private recovery is default-off')
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 1:
            raise ValueError('recovery wait budget must be finite in (0,1] seconds')
        self._runner, self._dma, self._mmio = runner, runner.dma, runner.mmio
        self._channels = (runner.dma.sendchannel, runner.dma.recvchannel)
        self._dma_mmio = self._channels[0]._mmio
        self._timeout, self._pid = float(timeout), os.getpid()
        self._lock = threading.Lock()
        self.last_diagnostics = None
        self._owned()

    def _owned(self):
        if (os.getpid() != self._pid or self._runner.dma is not self._dma or
                self._runner.mmio is not self._mmio or
                self._dma.sendchannel is not self._channels[0] or
                self._dma.recvchannel is not self._channels[1]):
            raise RuntimeError('recovery runner/process ownership drift')
        for ch, off in zip(self._channels, (0, 0x30)):
            if ch._mmio is not self._dma_mmio or type(ch._offset) is not int or ch._offset != off:
                raise RuntimeError('recovery channel/MMIO ownership drift')

    @staticmethod
    def _read(mmio, offset):
        value = mmio.read(offset)
        if type(value) is not int or not 0 <= value < 2**32:
            raise ValueError('invalid fresh recovery register value')
        return value

    def recover_and_confirm(self, runner):
        if not self._lock.acquire(blocking=False):
            raise RuntimeError('recovery busy/reentrant')
        diag = dict(confirmed=False, dma_reset=None, accelerator_reset=False)
        self.last_diagnostics = diag
        try:
            if runner is not self._runner:
                raise RuntimeError('recovery cannot target another runner')
            self._owned()
            primary = None
            try:
                diag['dma_reset'] = reset_simple_dma(self._dma, timeout_s=self._timeout)
            except BaseException as exc:
                primary = exc
            # Best effort accelerator reset even when the DMA reset failed;
            # NEVER let the second error erase the first or return success.
            try:
                self._mmio.write(0, CONTROL_SOFT_RESET)
                wait_until(lambda: self._read(self._mmio, 4) & (STATUS_IDLE | STATUS_BUSY | STATUS_ERROR)
                    == STATUS_IDLE, self._timeout, 'private accelerator reset to clean IDLE')
                diag['accelerator_reset'] = True
                self._owned()
                identity = dict(phase='post-soft-reset-before-start',
                    build_id=self._read(self._mmio, 0x60),
                    capabilities=self._read(self._mmio, 0x64),
                    counter_contract_version=self._read(self._mmio, 0x12c),
                    expected_counter_contract_version=1, error=self._read(self._mmio, 8))
                diag['fresh_accelerator_identity'] = identity
                # D075 resets active_new_mode to zero: contract 1 here, but
                # the unchanged native MODE11 completion check still requires 2.
                if (identity['build_id'] != 0x2026d075 or
                        identity['capabilities'] != 0x00080efe or
                        identity['counter_contract_version'] != 1 or identity['error'] != 0):
                    raise RuntimeError('fresh recovery identity/contract/error invalid: ' + repr(identity))
                states = []
                for ch in self._channels:
                    cr = self._read(self._dma_mmio, ch._offset)
                    sr = self._read(self._dma_mmio, ch._offset+4)
                    if (cr & DMA_DMACR_RESET or not cr & 1 or
                            sr & (DMA_DMASR_HALTED | DMA_DMASR_ERROR_MASK) or
                            ch._first_transfer is not True or ch._active_buffer is not None):
                        raise RuntimeError('DMA post-reset state not safe')
                    states.append(dict(control=cr, status=sr))
                # DMA IDLE is observed, not required before its first transfer.
                diag['fresh_dma_states'] = states
                self._owned()
                status = self._read(self._mmio, 4)
                if status & (STATUS_IDLE | STATUS_BUSY | STATUS_ERROR) != STATUS_IDLE or self._read(self._mmio, 8):
                    raise RuntimeError('accelerator left clean IDLE during recovery checks')
                diag['fresh_accelerator_status'] = status
            except BaseException as secondary:
                if primary is None:
                    primary = secondary
                else:
                    diag['secondary_error'] = repr(secondary)
            if primary is not None:
                diag['error'] = repr(primary)
                primary.recovery_diagnostics = diag
                raise primary
            diag['confirmed'] = True
            return True  # Exact True required by the unchanged owner.
        except BaseException as exc:
            diag.setdefault('error', repr(exc))
            raise
        finally:
            self._lock.release()


def main():
    print('Private recovery adapter only; no factory/board entry or hardware proof.')
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
