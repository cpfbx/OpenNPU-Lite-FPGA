"""Default-off same-layer call over PointwiseOwner and unchanged real driver.

No resources acquired here, no synthetic PL counter generation, no launcher.
This trusted internal API is not proof of physical hardware or authorization.
"""
import math
import os
import threading
import numpy as np
from adapter_binding import require
from pointwise_owner import PointwiseOwner
from pointwise_policy import validate_pointwise_policy
from batch_policy import BatchStop
from runtime_reference import sources, derive, make_jobs, authorize_owner
from return_diagnostic import SUCCESS_NO_FAILED_TILE, capture

class PointwiseDriverCall:
    def __init__(self,owner,case,*,enabled=False):
        require(enabled is True,'pointwise driver call default-off')
        require(type(owner) is PointwiseOwner,'exact pointwise owner; no software transport substitution')
        validate_pointwise_policy(owner.policy)
        authorize_owner(owner)
        spec=owner.policy.request(owner._index)
        require(type(case) is dict and type(case.get('cohort_index')) is int
            and case['cohort_index']==spec.cohort_index,'scheduled real window')
        # Copy only data verified against the unchanged, frozen prefix contract.
        frozen=derive(spec.cohort_index)
        for key in ('a','weights','bias','scales','expected'):
            require(type(case.get(key)) is np.ndarray and case[key].dtype==frozen[key].dtype
                and np.array_equal(case[key],frozen[key]),'exact frozen case '+key)
        for key in ('source_id','feature_sha256','input_zp','output_zp','activation'):
            require(case.get(key)==frozen[key],'exact case identity '+key)
        self.case={k:(v.copy() if type(v) is np.ndarray else v) for k,v in frozen.items()}
        for v in self.case.values():
            if type(v) is np.ndarray:v.flags.writeable=False
        self.owner,self.spec=owner,spec
        self.pid,self.thread=os.getpid(),threading.get_ident()
        self._guard=threading.Lock();self.used=False;self.failed=False;self.accepted=False
        self.first_failure=None

    def __call__(self,a):
        require((os.getpid(),threading.get_ident())==(self.pid,self.thread),'call process/thread drift')
        require(self._guard.acquire(blocking=False),'nonreentrant pointwise call')
        payload=None;metrics_for_diagnostic=None;fields_for_diagnostic=None;failure_check='not_returned'
        try:
            require(not self.used and not self.failed,'one-shot call; no retry/fallback')
            self.used=True
            validate_pointwise_policy(self.owner.policy)
            require(self.owner.policy.request(self.owner._index)==self.spec,'owner schedule changed')
            self.owner.pre_submit()
            require(type(a) is np.ndarray and a.dtype==np.int8 and a.shape==(125,64)
                and a.flags.c_contiguous and a.flags.owndata and np.array_equal(a,self.case['a']),
                'owning C-order exact scheduled input')
            jobs,_=make_jobs(a,self.case['weights']);jobs=list(jobs)
            require(len(jobs)==2 and [j.actual_bm for j in jobs]==[64,61],'exact pointwise geometry')
            tile,chain,counter,ref=sources()
            records=[chain.build_chain_record(job,self.spec.first_job_id+i,chain_last=i==1) for i,job in enumerate(jobs)]
            returned=self.owner.execute_chain(jobs,first_job_id=self.spec.first_job_id,timeout_s=60.,
                mode_override=11,launch_order='dma-first',profile_host=True)
            failure_check='driver_tuple'
            require(type(returned) is tuple and len(returned)==3,'driver tuple')
            if type(returned[0]) is bytes:payload=returned[0]
            response,echoed,metrics=returned
            metrics_for_diagnostic=metrics;failure_check='return_records'
            require(type(response) is bytes and len(response)==32000 and type(echoed) is list
                and echoed==records and type(metrics) is dict,'exact returned records and CPU-owned bytes')
            fields=dict(first_job_id=self.spec.first_job_id,jobs=2,mode=11,input_bytes=16512,
                input_payload_bytes=16384,input_header_bytes=128,output_bytes=32000,output_valid_bytes=32000,
                effective_macs=512000,error_code=0,chain_jobs_completed=2,failed_tile_index=SUCCESS_NO_FAILED_TILE,counter_contract_version=2)
            fields_for_diagnostic=fields;failure_check='work_counters'
            require(all(type(metrics.get(k)) is int and metrics[k]==v for k,v in fields.items()),'work/sequence/byte counters')
            failure_check='mode11_state'
            require(metrics.get('layout')=='k_major' and metrics.get('counter_contract')=='d007_global_work_v2'
                and type(metrics.get('status')) is int and metrics['status']&(2|4|8)==4
                and all(counter.validate_summary(metrics).values()) and metrics['pl_total_cycles']>0,'MODE11 conservation/clean DONE')
            failure_check='mmio_timing'
            require(metrics.get('mode11_counter_read_strategy')=='pynq_mmio_read'
                and type(metrics.get('seconds')) in (int,float) and math.isfinite(metrics['seconds'])
                and metrics['seconds']>0,'unchanged normal MMIO read path and finite timing')
            failure_check='synthetic_evidence'
            require('counter_evidence' not in metrics,'v2 synthetic transport evidence not accepted')
            raw=np.zeros((125,64),np.int32)
            for job,chunk in zip(jobs,chain.split_chain_output(response,echoed)):tile.place_output(raw,job,chunk)
            failure_check='raw_int32'
            require(np.array_equal(raw,a.astype(np.int64)@self.case['weights'].astype(np.int64)),
                'all raw INT32 values equal independent INT64 before requantization')
            corrected=raw.astype(np.int64)+self.case['bias'].astype(np.int64)+128*self.case['weights'].astype(np.int64).sum(axis=0)
            ref.checked_i32(corrected)
            result=ref.requantize(corrected,self.case['scales'],-128,1)
            failure_check='requantized_int8'
            require(np.array_equal(result,self.case['expected']),'all 8000 fixed-reference INT8 values')
            failure_check='stop_pending'
            if self.owner.stop_requested() is not False:raise BatchStop('exact result returned but stop pending; not accepted')
            self.accepted=True
            return result,dict(driver_metrics=metrics,cohort_index=self.spec.cohort_index,
                raw=raw,corrected=corrected,reply_tile_order=response,
                input_chain=b''.join(r.bytes for r in records),
                source='unchanged driver/MMIO readback API; origin NOT authenticated by this call',
                physical_identity_authenticated=False,performance_accepted=False,promotion=False)
        except BaseException as error:
            self.failed=True
            raw=getattr(error,'matrix_returned_payload',payload)
            if self.first_failure is None:
                self.first_failure=dict(error_type=type(error).__name__,cohort_index=self.spec.cohort_index,
                    payload=raw if type(raw) is bytes and len(raw)<=32000 else None,
                    accepted=False,automatic_retry=False,
                    return_diagnostic=capture(metrics_for_diagnostic,fields_for_diagnostic,failure_check))
            raise
        finally:self._guard.release()
