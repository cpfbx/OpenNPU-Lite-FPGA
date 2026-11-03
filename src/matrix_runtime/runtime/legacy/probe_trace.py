"""Emit a synthetic driver trace comparison, never an ARM/FPGA benchmark."""
import hashlib
import json
from pathlib import Path
import sys
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent
for path in reversed([ROOT/'frozen_source',ROOT]):sys.path.insert(0,str(path))
import numpy as np
import chain_protocol as chain
import pynq_gemm as driver
import offline_fixture as fixture
from matrix_panel_builder_candidate import build_panel_layout_cached_transactions
from tiled_gemm import TileConfig,Layout


def main():
    observations=[]
    for index in (42,43):
        a,b=fixture.bank_arrays(index)
        jobs=list(build_panel_layout_cached_transactions(a,b,TileConfig(layout=Layout.K_MAJOR),enabled=True).transactions)
        expected=(ROOT/'bank'/f'input_{index}_expected.bin').read_bytes()
        output=fixture.tiled_output(jobs,np.frombuffer(expected,dtype='<i4').reshape(512,512))
        traces=[]
        for flat in (False,True):
            r,tx,rx,events=fixture.fixture(jobs,output,candidate=flat)
            materializations=[]
            original=chain.ChainRecord.bytes.fget
            def observed(record):
                raw=original(record)
                materializations.append(len(raw))
                return raw
            with patch.object(chain.ChainRecord,'bytes',property(observed)):
                returned,records,metrics=r.run_chain(jobs,tx,rx,1,.01,profile_host=True,mode_override=11)
            wire,reference_records=chain.pack_chain(jobs)
            assert bytes(tx)==wire and records==reference_records and returned==output
            traces.append({'path':'flat_candidate' if flat else 'frozen_baseline','dma_events':events,
                'wire_bytes':len(wire),'wire_sha256':hashlib.sha256(bytes(tx)).hexdigest(),
                'output_bytes':len(returned),'synthetic_output_sha256':hashlib.sha256(returned).hexdigest(),
                'record_bytes_materializations':len(materializations),'record_bytes_materialized_bytes':sum(materializations),
                'non_timing_metrics':{k:v for k,v in metrics.items() if k not in ('seconds','host_profile')}})
        assert traces[0]['dma_events']==traces[1]['dma_events']
        assert traces[0]['wire_sha256']==traces[1]['wire_sha256']
        assert traces[0]['record_bytes_materializations']==64 and traces[1]['record_bytes_materializations']==0
        assert traces[0]['record_bytes_materialized_bytes']==4198400
        assert traces[0]['non_timing_metrics']==traces[1]['non_timing_metrics']
        observations.append({'input_id':index,'traces':traces})
    print(json.dumps({'scope':'actual Python driver code over synthetic MMIO/DMA; NOT a hardware execution',
        'synthetic_dma_payload_source':'precomputed pinned golden output; no RTL numerical simulation',
        'counter_values':'small synthetic conservation fixture, not physical-cycle evidence',
        'timings_excluded':True,'arm_speedup_measured':False,'board_access':False,'promotion':False,
        'observations':observations},ensure_ascii=False))


if __name__=='__main__':main()
