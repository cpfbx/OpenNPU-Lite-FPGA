"""Pure plan ledger only: supplied receipts are NOT independent OS exit proofs."""
from dataclasses import asdict
from comparison_policy import ComparisonPolicy,validate_policy
from batch_policy import BatchStop


class SerialPlan:
    def __init__(self,*,enabled=False):
        if enabled is not True:raise ValueError('serial comparison default-off')
        self.next_block=0
        self.active=None
        self.local_index=0
        self.pending=None
        self.stopped=False
        self.failed=False
        self.formal=0
        self.warmup=0

    def stop(self):self.stopped=True

    def _guard(self):
        if self.failed:raise RuntimeError('failed serial plan; no retry')
        if self.stopped:raise BatchStop('stop requested; no next request or block')

    def _reject(self,message):
        self.failed=True
        raise ValueError(message)

    def begin(self,policy):
        self._guard()
        try:validate_policy(policy)
        except (ValueError,TypeError):
            self.failed=True
            raise
        if self.active is not None or policy.block_index!=self.next_block:
            self._reject('strictly serial exact next block required')
        self.active=policy;self.local_index=0

    def claim(self):
        self._guard()
        if self.active is None or self.pending is not None or self.local_index>=6:
            self._reject('one pending bounded request required')
        self.pending=self.active.request(self.local_index)
        return self.pending

    def accept(self,request,*,exact):
        # Stop can arrive during this entered request. Accept its completion,
        # but never issue the next claim/block once stopped.
        if self.failed:raise RuntimeError('failed serial plan; no retry')
        if self.pending is None or request is not self.pending or exact is not True:
            self.failed=True
            raise ValueError('pending request identity/full exact check required')
        if request.phase=='formal':self.formal+=1
        else:self.warmup+=1
        self.local_index+=1;self.pending=None

    def finish(self,receipt):
        if self.failed:raise RuntimeError('failed serial plan; quarantine externally')
        if self.active is None or self.local_index!=6 or self.pending is not None:
            self._reject('all six entered calls must complete before successful block finish')
        expected=dict(block_index=self.active.block_index,actual_exit_code=0,
                      process_group_absent=True,cleanup_verified=True,lock_released=True)
        if (type(receipt) is not dict or set(receipt)!=set(expected)
                or any(type(receipt[k]) is not type(v) or receipt[k]!=v for k,v in expected.items())):
            self.failed=True
            raise ValueError('block terminal receipt must be exact; OS observer still required')
        self.next_block+=1;self.active=None

    def summary(self):
        return dict(plan_complete=self.next_block==12 and self.active is None
                    and not self.failed and not self.stopped,
                    formal_calls=self.formal,warmup_calls=self.warmup,
                    completed_blocks=self.next_block,stop_latched=self.stopped,
                    fault_latched=self.failed,os_evidence_observed=False,
                    source='pure supplied-receipt model; not an actual process observer',
                    board_access=False,promotion=False)
