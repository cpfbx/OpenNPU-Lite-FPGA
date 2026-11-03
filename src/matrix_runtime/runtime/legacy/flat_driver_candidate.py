"""Explicit opt-in pack-only derivative. No monkeypatch of the frozen driver.

Run through the unchanged owner, never as an authority/lock substitute.
Importing this module does not import PYNQ or access hardware.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

import pynq_gemm as frozen
from chain_protocol import ChainRecord
from tiled_gemm import TileTransaction, FusedTileTransaction
from pack_chain_flat_candidate import pack_chain_flat


class FlatPackPynqGemm(frozen.PynqGemm):
    def __init__(self, bit_path: Path, *, enabled=False):
        if enabled is not True:
            raise ValueError('flat driver candidate default-off')
        self._flat_pack_enabled = True
        super().__init__(bit_path)

    def run_chain(
        self,
        transactions: list[TileTransaction | FusedTileTransaction],
        input_buffer: Any,
        output_buffer: Any,
        first_job_id: int,
        timeout_s: float,
        launch_order: str = "dma-first",
        profile_host: bool = False,
        mode_override: int | None = None,
        fast_counter_reads: bool = False,
    ) -> tuple[bytes, list[ChainRecord], dict[str, Any]]:
        """Frozen run_chain body except explicit pack-only wiring and opt-in guard."""
        if getattr(self, '_flat_pack_enabled', False) is not True:
            raise ValueError('flat driver instance was not explicitly enabled')
        fused, k_major, chain_mode, capability = frozen.chain_execution_contract(
            transactions
        )
        if mode_override is not None:
            if mode_override not in (
                frozen.MODE_CHAIN_INT32_K_MAJOR_DECOUPLED,
                frozen.MODE_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE,
                frozen.MODE_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH,
                frozen.MODE_CHAIN_INT32_K_MAJOR_DUAL_C,
            ):
                raise ValueError(f"unsupported chain mode override {mode_override}")
            if fused or not k_major:
                raise ValueError("MODE 7/9/10/11 requires a dense K-major chain")
            chain_mode = mode_override
            capability = {
                frozen.MODE_CHAIN_INT32_K_MAJOR_DECOUPLED:
                    frozen.CAPABILITY_CHAIN_INT32_K_MAJOR_DECOUPLED,
                frozen.MODE_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE:
                    frozen.CAPABILITY_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE,
                frozen.MODE_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH:
                    frozen.CAPABILITY_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH,
                frozen.MODE_CHAIN_INT32_K_MAJOR_DUAL_C:
                    frozen.CAPABILITY_CHAIN_INT32_K_MAJOR_DUAL_C,
            }[mode_override]
        if type(fast_counter_reads) is not bool:
            raise ValueError("fast_counter_reads must be a boolean")
        if fast_counter_reads:
            if chain_mode != frozen.MODE_CHAIN_INT32_K_MAJOR_DUAL_C:
                raise ValueError("fast counter reads require MODE11")
            self._mode11_word_reader()  # Same pre-DMA validation, not enabled by this candidate.
        if not self.capabilities & capability:
            label = ("K-major " if k_major else "") + (
                "fused INT8" if fused else "INT32"
            )
            raise RuntimeError(
                f"Overlay does not advertise chained {label} capability: "
                f"0x{self.capabilities:08x}"
            )

        chain_payload, records = pack_chain_flat(
            transactions, first_job_id=first_job_id, enabled=True
        )
        input_bytes = len(chain_payload)
        output_bytes = sum(record.header.output_transport_bytes for record in records)
        if input_bytes > input_buffer.size or output_bytes > output_buffer.size:
            raise ValueError("allocated DMA buffers are too small for this chain")

        return self._submit_chain(
            chain_payload, records, transactions, input_buffer, output_buffer,
            first_job_id, timeout_s, launch_order, profile_host, chain_mode, k_major,
            fast_counter_reads=fast_counter_reads,
        )


def flat_runner_type(*, enabled=False):
    """Supply the unchanged BatchOwner's runner-type protocol, without resources."""
    if enabled is not True:
        raise ValueError('flat runner binding default-off')

    class ExplicitFlatPackRunner(FlatPackPynqGemm):
        def __init__(self, bit_path):
            super().__init__(bit_path, enabled=True)

    return ExplicitFlatPackRunner
