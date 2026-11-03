"""Bounded immutable artifacts and descriptive timing; no device or file I/O on accept."""
from dataclasses import asdict
import hashlib
from pathlib import Path
import statistics

from comparison_policy import ComparisonPolicy,Request
from cpu_frames import write_new


def checked_request(request):
    if type(request) is not Request:raise ValueError('exact fixed-plan Request required')
    expected=ComparisonPolicy(request.block_index,True).request(request.local_index)
    if asdict(request)!=asdict(expected):raise ValueError('request identity drift')
    # Dataclass equality accepts bool/int aliases; serialized equality alone is insufficient.
    if any(type(getattr(request,k)) is not type(v) for k,v in asdict(expected).items()):
        raise ValueError('request field type drift')
    return expected


class RetainedOutputs:
    """At most 12 fixed local-index-2 successes + ONE first-failure full payload.

    Total output payload bound = 6*256^2*4 + 6*512^2*4 + 512^2*4 = 8.5 MiB.
    No change to oracle, no retention of successive good 1MiB outputs in a batch.
    """
    MAX_PAYLOAD_BYTES=8912896

    def __init__(self,*,enabled=False):
        if enabled is not True:raise ValueError('output retention default-off')
        self.successes={};self.first_failure=None;self._written=False

    @property
    def payload_bytes(self):
        return sum(len(v['payload']) for v in self.successes.values())+(
            0 if self.first_failure is None else len(self.first_failure['payload']))

    def _budget(self,additional):
        if type(additional) is not int or additional<0 or self.payload_bytes+additional>self.MAX_PAYLOAD_BYTES:
            raise ValueError('explicit retained output payload budget exceeded')

    def success(self,request,output,expected_sha):
        checked_request(request)
        if self._written:raise RuntimeError('retention already persisted')
        if request.local_index!=2:return  # Fixed BEFORE results, no best-window selection.
        if request.block_index in self.successes:raise ValueError('duplicate representative output')
        import numpy as np
        if (type(output) is not np.ndarray or output.dtype!=np.int32
                or output.shape!=(request.dimension,)*2 or not output.flags.c_contiguous):
            raise ValueError('representative plain contiguous INT32 required')
        raw=output.astype('<i4',copy=False).tobytes()
        if hashlib.sha256(raw).hexdigest()!=expected_sha:raise ValueError('representative SHA drift')
        self._budget(len(raw))
        self.successes[request.block_index]=dict(request=asdict(request),payload=raw,
            encoding='row-major-int32-le',sha256=expected_sha)

    def failure(self,request,payload,encoding):
        checked_request(request)
        if self._written:raise RuntimeError('retention already persisted')
        if self.first_failure is not None:return False
        if type(payload) is not bytes or len(payload)!=request.dimension**2*4:
            raise ValueError('bounded exact full first-failure bytes required')
        if encoding not in ('row-major-int32-le','chain-tiled-int32-le'):
            raise ValueError('explicit output encoding required')
        self._budget(len(payload))
        self.first_failure=dict(request=asdict(request),payload=payload,encoding=encoding,
            sha256=hashlib.sha256(payload).hexdigest())
        return True

    def failure_from_exception(self,request,error):
        """Explicit interfaces only; never inspect traceback or scrape arbitrary objects."""
        checked_request(request)
        payload=getattr(error,'comparison_returned_payload',None)
        if payload is not None:
            expected=dict(block_index=request.block_index,local_index=request.local_index,
                input_id=request.input_id,dimension=request.dimension,encoding='row-major-int32-le')
            identity=getattr(error,'comparison_output_identity',None)
            if (type(identity) is not dict or identity!=expected
                    or any(type(identity.get(k)) is not type(v) for k,v in expected.items())):
                raise ValueError('comparison failure attachment identity drift')
            return self.failure(request,payload,'row-major-int32-le')
        payload=getattr(error,'cpu_returned_payload',None)
        if payload is not None:
            expected=dict(block_index=request.block_index,local_index=request.local_index,
                input_id=request.input_id,dimension=request.dimension,encoding='row-major-int32-le')
            identity=getattr(error,'cpu_output_identity',None)
            if (type(identity) is not dict or identity!=expected
                    or any(type(identity.get(k)) is not type(v) for k,v in expected.items())):
                raise ValueError('CPU failure attachment identity drift')
            return self.failure(request,payload,'row-major-int32-le')
        payload=getattr(error,'matrix_returned_payload',None)
        return False if payload is None else self.failure(request,payload,'chain-tiled-int32-le')

    def persist(self,directory):
        """External post-request sink; caller must separately prove lifecycle/cleanup status.

        Fresh directory, exclusive writes; a write failure poisons this sink (no retry).
        No lock operations and no claim that evidence persistence releases hardware.
        """
        if self._written:raise RuntimeError('persistence single-use; no retry')
        folder=Path(directory).absolute()
        if folder.exists() or folder.resolve()!=folder:raise ValueError('fresh canonical output directory required')
        self._written=True;folder.mkdir()
        rows=[]
        values=[(f'success_block_{b:02d}.bin',v) for b,v in sorted(self.successes.items())]
        if self.first_failure is not None:values.append(('first_failure.bin',self.first_failure))
        for name,value in values:
            with (folder/name).open('xb') as stream:stream.write(value['payload'])
            rows.append(dict(path=name,bytes=len(value['payload']),**{k:v for k,v in value.items() if k!='payload'}))
        result=dict(outputs=rows,payload_bytes=self.payload_bytes,
            max_payload_bytes=self.MAX_PAYLOAD_BYTES,selection='local_index_2_of_each_fixed_block',
            lifecycle_proven_by_this_sink=False,energy_evaluated=False,promotion=False)
        write_new(folder/'outputs.json',result)
        return result


def timing_row(request,begin_ns,end_ns,cpu_ns):
    checked_request(request)
    if (any(type(v) is not int for v in (begin_ns,end_ns,cpu_ns))
            or not 0<begin_ns<end_ns or cpu_ns<0):raise ValueError('integer positive request timing required')
    return dict(request=asdict(request),wall_ns=end_ns-begin_ns,process_cpu_ns=cpu_ns,
        scope='cpu_child_compute' if request.backend=='openblas_2t' else 'fpga_complete_request',
        oracle_ipc_setup_cleanup_included=False)


def descriptive_stats(rows):
    if type(rows) is not list or len(rows)>72:raise ValueError('bounded request rows required')
    seen=set();groups={}
    for row in rows:
        if type(row) is not dict or set(row)!={'request','wall_ns','process_cpu_ns','scope','oracle_ipc_setup_cleanup_included'}:
            raise ValueError('timing row shape')
        request=Request(**row['request']);checked_request(request)
        wanted=timing_row(request,1,1+row['wall_ns'],row['process_cpu_ns'])
        if row!=wanted or type(row['wall_ns']) is not int or row['oracle_ipc_setup_cleanup_included'] is not False:
            raise ValueError('timing row type/scope drift')
        if request.global_index in seen:raise ValueError('duplicate timed request')
        seen.add(request.global_index)
        if request.phase=='formal':groups.setdefault((request.dimension,request.backend),[]).append(row)
    result=[]
    for (dimension,backend),values in sorted(groups.items()):
        item=dict(dimension=dimension,backend=backend,formal_n=len(values))
        for field in ('wall_ns','process_cpu_ns'):
            numbers=[v[field] for v in values]
            item[field]=dict(mean=statistics.mean(numbers),median=statistics.median(numbers),
                min=min(numbers),max=max(numbers))
        result.append(item)
    return dict(groups=result,raw_rows=len(rows),complete_72_rows=len(seen)==72,
        tail_latency_accepted=False,energy_evaluated=False,historical_threshold_used=False,promotion=False)
