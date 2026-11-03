"""Explicit offline call candidate; all original checks and timings retained."""
import math
import time
from comparison_call import ComparisonCall
from comparison_policy import validate_fpga_policy as validate_policy


class ContiguousComparisonCall(ComparisonCall):
    def __init__(self,owner,policy,*,enabled=False):
        validate_policy(policy)
        if policy.backend!='fpga_flat_contiguous':raise ValueError('contiguous builder requires explicit flat-family policy')
        super().__init__(owner,policy,enabled=enabled)

    def _call(self, a, b):
        import numpy as np
        from chain_protocol import build_chain_record, split_chain_output
        from tiled_gemm import Layout, TileConfig, place_output
        from panel_contiguous_candidate import build_panel_layout_cached_transactions
        from d007_mode11_contract import validate_summary
        validate_policy(self.policy)
        spec = self.policy.request(self._index)
        self.owner.pre_submit()  # Before construction; not a reusable submit permit.
        if any(type(x) is not np.ndarray or x.dtype != np.int8 or x.shape != (spec.dimension, spec.dimension)
               or not x.flags.owndata or not x.flags.c_contiguous for x in (a, b)):
            raise ValueError('owning C-contiguous fixed-shape INT8 arrays required')
        if np.shares_memory(a, b):
            raise ValueError('independent A/B required')
        stages = {}
        tick = time.perf_counter_ns()
        jobs = list(build_panel_layout_cached_transactions(a, b, TileConfig(layout=Layout.K_MAJOR),
                                                         enabled=True).transactions)
        stages['transaction_generation'] = time.perf_counter_ns() - tick
        if len(jobs) != spec.jobs:
            raise ValueError('batch tile count drift')
        tick = time.perf_counter_ns()
        # Owner repeats stop/lease/fresh hardware checks immediately before run_chain.
        returned = self.owner.execute_chain(jobs, first_job_id=spec.first_job_id,
                timeout_s=60., mode_override=11, launch_order='dma-first', profile_host=True)
        stages['owned_submission'] = time.perf_counter_ns() - tick
        try:
            payload, records, metrics = returned
            if type(payload) is not bytes or type(metrics) is not dict:
                raise ValueError('owned CPU bytes/plain metrics required')
            tick = time.perf_counter_ns()
            wanted = [build_chain_record(job, spec.first_job_id + i, chain_last=i == spec.jobs-1)
                      for i, job in enumerate(jobs)]
            if list(records) != wanted:
                raise ValueError('chain records differ from submitted operands')
            fields = dict(mode=11, jobs=spec.jobs, chain_jobs_completed=spec.jobs, input_bytes=self.policy.geometry.input_bytes,
                          output_bytes=self.policy.geometry.output_bytes, output_valid_bytes=self.policy.geometry.output_bytes,
                          effective_macs=self.policy.geometry.macs, first_job_id=spec.first_job_id, error_code=0)
            if any(type(metrics.get(k)) is not int or metrics[k] != v for k, v in fields.items()):
                raise ValueError('batch work/sequence counter mismatch')
            if (metrics.get('layout') != 'k_major' or metrics.get('counter_contract') != 'd007_global_work_v2'
                    or type(metrics.get('status')) is not int or metrics['status'] & (2 | 4 | 8) != 4
                    or not all(validate_summary(metrics).values())):
                raise ValueError('MODE11 global conservation/clean DONE mismatch')
            if (type(metrics.get('seconds')) not in (int, float)
                    or not math.isfinite(metrics['seconds']) or metrics['seconds'] <= 0
                    or len(payload) != self.policy.geometry.output_bytes):
                raise ValueError('exact output bytes/positive inner DMA+PL timing required')
            stages['record_reconstruction'] = time.perf_counter_ns() - tick
            tick = time.perf_counter_ns()
            result = np.zeros((spec.dimension, spec.dimension), dtype=np.int32)
            tiles = iter(split_chain_output(payload, records))
            for job in jobs:
                place_output(result, job, next(tiles))
            if next(tiles, None) is not None:
                raise ValueError('extra returned output tile')
            stages['output_unpack'] = time.perf_counter_ns() - tick
            metrics.update(batch_pl_index=self._index, batch_policy='explicit-panel-comparison-v1',
                           panel_cache_enabled=True, attribution_observed=True,
                           attribution_adapter_ns=stages)
            metrics['host_path_candidate'] = 'flat_contiguous'
            self._index += 1
            return result, metrics
        except BaseException as error:
            if isinstance(returned, tuple) and len(returned) == 3 and type(returned[0]) is bytes:
                error.matrix_returned_payload = returned[0]
            raise
