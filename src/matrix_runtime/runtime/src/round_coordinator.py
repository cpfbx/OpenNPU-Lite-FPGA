"""Trusted callback serial core, NOT a process launcher or proof authenticator.

    Real CPU/FPGA outer bridges are separate requirements. This core alone never
    claims OS evidence even when its caller supplies plausible terminal receipts.
"""
from dataclasses import asdict

from batch_policy import BatchStop
from comparison_policy import ComparisonPolicy
from comparison_bank import verify_output
from serial_plan import SerialPlan
from round_artifacts import RetainedOutputs,timing_row,descriptive_stats


class RoundCoordinator:
    def __init__(self,bank,stopped,*,enabled=False):
        if enabled is not True or not callable(stopped):raise ValueError('round core default-off')
        self.bank,self.stopped=bank,stopped
        self.ledger=SerialPlan(enabled=True);self.outputs=RetainedOutputs(enabled=True)
        self.rows=[];self.block_receipts=[];self._used=False;self._error=None

    def _stop(self):
        if self.stopped() is not False:self.ledger.stop()
        if self.ledger.stopped:raise BatchStop('round stop; no next request or block')

    def before(self,spec):
        self._stop()
        if self._error is not None:raise RuntimeError('round fault; no retry')
        wanted=self.ledger.claim()
        if type(spec) is not type(wanted) or asdict(spec)!=asdict(wanted):
            self.ledger.failed=True;raise ValueError('backend request does not match pending fixed request')
        if any(type(getattr(spec,k)) is not type(v) for k,v in asdict(wanted).items()):
            self.ledger.failed=True;raise ValueError('backend request type drift')
        return wanted

    def accept(self,spec,result,digest,output):
        """Full oracle OUTSIDE measured request; pending may finish after stop."""
        pending=self.ledger.pending
        if pending is None or type(spec) is not type(pending) or asdict(spec)!=asdict(pending):
            self.ledger.failed=True;raise ValueError('completion does not match claimed request')
        try:
            verified=verify_output(self.bank[pending.dimension,pending.input_id],output)
        except BaseException:
            import numpy as np
            if type(output) is np.ndarray and output.dtype==np.int32 and output.shape==(pending.dimension,)*2 and output.flags.c_contiguous:
                self.outputs.failure(pending,output.astype('<i4',copy=False).tobytes(),'row-major-int32-le')
            self.ledger.failed=True;raise
        try:
            if digest!=verified:raise ValueError('backend digest differs from full golden verification')
            row=timing_row(pending,result['begin_ns'],result['end_ns'],result['process_cpu_ns'])
            self.outputs.success(pending,output,verified)
        except BaseException:
            self.ledger.failed=True;raise
        self.ledger.accept(pending,exact=True)
        self.rows.append(row)

    def run(self,execute_block):
        """execute_block(policy, before_GO, accept_result) must return only AFTER cleanup.

        Callback return is SUPPLIED evidence, not independently proven here. No
        caller can turn this API into run_ready or a genuine OS-observed summary.
        """
        if self._used:raise RuntimeError('round single-use; no retry')
        self._used=True
        if not callable(execute_block):raise ValueError('trusted block executor required')
        try:
            for block in range(12):
                self._stop();policy=ComparisonPolicy(block,True);self.ledger.begin(policy)
                receipt=execute_block(policy,self.before,self.accept)
                self._stop()  # A late stop is not a successful run; do not open next block.
                self.ledger.finish(receipt);self.block_receipts.append(dict(receipt))
        except BaseException as error:
            self._error=type(error).__name__
            if isinstance(error,BatchStop):self.ledger.stop()
            else:self.ledger.failed=True
            pending=self.ledger.pending
            if pending is not None:
                try:self.outputs.failure_from_exception(pending,error)
                except BaseException as attachment_error:
                    error.output_attachment_error_type=type(attachment_error).__name__
            raise
        return self.summary()

    def summary(self):
        return dict(ledger=self.ledger.summary(),timings=descriptive_stats(self.rows),
            completed_block_receipts=len(self.block_receipts),error_type=self._error,
            retained_payload_bytes=self.outputs.payload_bytes,os_evidence_observed=False,
            scope='trusted callback serial core only; real outer bridges not implemented here',
            run_ready=False,board_access=False,promotion=False)
