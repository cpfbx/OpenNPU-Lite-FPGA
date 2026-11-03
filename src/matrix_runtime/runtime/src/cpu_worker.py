"""Private worker loop, compute-only timestamps; imports never run the ARM library."""
import os
import time
import numpy as np
from comparison_policy import validate_policy
from batch_policy import BatchStop
from cpu_frames import line,encode,exact_row


def loop(policy,inputs,compute,guardian_guard,stopped,source,sink,*,compute_kind,library_sha):
    validate_policy(policy)
    if policy.backend!='openblas_2t':raise ValueError('CPU-only fixed block required')
    if compute_kind not in ('arm_openblas_2t','pc_int64_fixture'):raise ValueError('explicit compute identity')
    if type(inputs) is not dict or set(inputs)!={42,43}:raise ValueError('two pre-bound input pairs required')
    def guard():
        if stopped() is not False:raise BatchStop('CPU stop; no next compute')
        if guardian_guard() is not True:raise RuntimeError('guardian ticket not verified')
    def send(row,payload=None):
        sink.write(encode(row))
        if payload is not None:sink.write(payload)
        sink.flush()
    def receive(kind,index):
        row=line(source)
        if row is None or row==dict(kind='stop'):raise BatchStop('guardian stop or EOF')
        exact_row(row,dict(kind=kind,index=index))
    guard()
    send(dict(kind='hello',pid=os.getpid(),block_index=policy.block_index,
              dimension=policy.dimension,compute_kind=compute_kind,library_sha256=library_sha))
    for index in range(6):
        request=policy.request(index);guard()
        send(dict(kind='ready',index=index,input_id=request.input_id,pid=os.getpid()))
        receive('go',index);guard()
        # Bank selection is NOT inside complete-request timing.
        a,b=inputs[request.input_id]
        begin=time.perf_counter_ns();cpu=time.process_time_ns()
        output=compute(a,b)
        cpu=time.process_time_ns()-cpu;end=time.perf_counter_ns()
        if (type(output) is not np.ndarray or output.dtype!=np.int32
                or output.shape!=(policy.dimension,)*2 or not output.flags.c_contiguous):
            raise ValueError('CPU output shape/type/ownership contract')
        payload=output.astype('<i4',copy=False).tobytes()
        if len(payload)!=policy.geometry.output_bytes:raise ValueError('CPU output bytes')
        send(dict(kind='result',index=index,input_id=request.input_id,pid=os.getpid(),
            payload_bytes=len(payload),begin_ns=begin,end_ns=end,process_cpu_ns=cpu),payload)
        receive('ack',index)
        del output,payload
    guard();send(dict(kind='done',calls=6,pid=os.getpid()))
    return 0
