"""Private FPGA block service; trusted dependencies, unchanged owner/supervisor.

No oracle or file writes in measured request; ACK comes only after parent's
RoundCoordinator.accept full check. No standalone device CLI in this module.
"""
import contextlib
import hashlib
import os
import sys
import time
import numpy as np
from batch_policy import BatchStop
from comparison_policy import validate_fpga_policy
from cpu_frames import encode,line,exact_row
from comparison_call import ComparisonCall
from supervision_bridge import supervised


def serve(policy,bank,owner,start,source,sink,stopped,publish,*,enabled=False,
          call_type=ComparisonCall,compute_kind='fpga_mode11',failure_journal=None):
    if enabled is not True:raise ValueError('FPGA service default-off')
    validate_fpga_policy(policy)
    if owner.policy is not policy:raise ValueError('same exact FPGA owner policy required')
    if compute_kind not in ('fpga_mode11','pc_fpga_fixture'):raise ValueError('explicit compute identity')
    inputs={i:bank[policy.dimension,i].arrays() for i in (42,43)}
    acquired_ticket=None
    completed=0

    def send(row,payload=None):
        raw=encode(row)
        if len(raw)>8192:raise ValueError('FPGA metadata line exceeds protocol budget')
        sink.write(raw)
        if payload is not None:sink.write(payload)
        sink.flush()

    def receive(kind,index):
        row=line(source)
        if row is None or row==dict(kind='stop'):raise BatchStop('parent stop or EOF')
        exact_row(row,dict(kind=kind,index=index))

    def operation(stop):
        nonlocal acquired_ticket,completed
        owner.stop_requested=stop
        operation_error=None
        try:
            # PYNQ's textual initialization diagnostics must never enter binary IPC.
            with contextlib.redirect_stdout(sys.stderr):start(owner)
            call=call_type(owner,policy,enabled=True)
            ticket=owner.pre_submit()
            acquired_ticket=ticket
            send(dict(kind='hello',pid=os.getpid(),block_index=policy.block_index,
                dimension=policy.dimension,compute_kind=compute_kind,ticket=ticket))
            for index in range(6):
                request=policy.request(index)
                if stop() is not False:raise BatchStop('FPGA stop before READY')
                owner.pre_submit()
                send(dict(kind='ready',index=index,input_id=request.input_id,pid=os.getpid()))
                receive('go',index)
                if stop() is not False:raise BatchStop('FPGA stop after GO before call')
                a,b=inputs[request.input_id]
                cpu=time.process_time_ns();begin=time.perf_counter_ns()
                try:
                    with contextlib.redirect_stdout(sys.stderr):output,metrics=call(a,b)
                except BaseException as primary:
                    # This must precede owner.close AND the original supervisor's
                    # potentially infinite hold. Never substitute an I/O error.
                    if failure_journal is not None:
                        try:failure_journal.capture(request,primary)
                        except BaseException as secondary:
                            primary.failure_journal_error_type=type(secondary).__name__
                    raise
                end=time.perf_counter_ns();cpu=time.process_time_ns()-cpu
                if (type(output) is not np.ndarray or output.dtype!=np.int32
                        or output.shape!=(policy.dimension,)*2 or not output.flags.c_contiguous):
                    raise ValueError('bounded plain row-major INT32 result required')
                payload=output.astype('<i4',copy=False).tobytes()
                if len(payload)!=policy.geometry.output_bytes:raise ValueError('exact FPGA output bytes required')
                # NO premature verify_output: parent accept must retain pure numeric failures.
                digest=hashlib.sha256(payload).hexdigest()
                send(dict(kind='result',index=index,input_id=request.input_id,pid=os.getpid(),
                    payload_bytes=len(payload),begin_ns=begin,end_ns=end,process_cpu_ns=cpu,
                    output_sha256=digest,metrics=metrics),payload)
                completed+=1
                receive('ack',index)
                del output,payload
            if stop() is not False:raise BatchStop('FPGA stop after last ACK')
            return ticket
        except BaseException as error:
            operation_error=error;raise
        finally:
            if not owner._held and not owner._unsafe:
                try:
                    with contextlib.redirect_stdout(sys.stderr):owner.close()
                except BaseException as secondary:
                    if operation_error is None:raise
                    operation_error.owner_close_error_type=type(secondary).__name__

    try:observed=supervised(owner,operation,publish,stopped,enabled=True)
    except BaseException as primary:
        # A safely closed stopped/failed request still exposes cleanup, NEVER DONE.
        # Quarantine never returns from the original supervisor to this branch.
        if owner._closed and not owner._held and not owner._unsafe and acquired_ticket is not None:
            try:
                send(dict(kind='aborted',calls=completed,pid=os.getpid(),ticket=acquired_ticket,
                    cleanup=dict(owner_closed=True,readback=owner.cleanup_readback)))
            except BaseException as secondary:
                primary.cleanup_terminal_write_error_type=type(secondary).__name__
        raise
    # Reached only after cleanup AND safe signal-handler restoration. A quarantined
    # owner never reaches DONE; original supervisor retains its process/lease.
    send(dict(kind='done',calls=6,pid=os.getpid(),ticket=observed['result'],
        cleanup=dict(owner_closed=owner._closed,readback=owner.cleanup_readback)))
    return 0
