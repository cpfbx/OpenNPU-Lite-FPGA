"""Synthetic PC MMIO/DMA/lease only: NOT PYNQ, Linux lock or board evidence.

This copies precomputed CPU/golden bytes when fake START occurs. It does NOT
simulate RTL numerics or claim that real DMA/hardware produced those bytes.
"""
from pathlib import Path
from types import SimpleNamespace
import numpy as np

import pynq_gemm as driver
import d007_mode11_contract as contract
from batch_owner import BatchOwner
from batch_policy import BatchPolicy
from flat_driver_candidate import FlatPackPynqGemm

ROOT=Path(__file__).resolve().parent


class Buffer(np.ndarray):
    def __new__(cls,size,address,events,label):
        obj=np.zeros(size,dtype=np.uint8).view(cls)
        obj.physical_address=address
        obj.events=events
        obj.label=label
        return obj

    def __array_finalize__(self,source):
        if source is not None:
            for name in ('physical_address','events','label'):
                if hasattr(source,name):setattr(self,name,getattr(source,name))

    def flush(self):self.events.append(('flush',self.label))
    def invalidate(self):self.events.append(('invalidate',self.label))
    def freebuffer(self):self.events.append(('free',self.label))


class DmaMMIO:
    def __init__(self):self.values={0:1,4:2,0x30:1,0x34:2}
    def read(self,offset):return self.values.get(offset,0)


class Channel:
    def __init__(self,mmio,offset,events,name):
        self._mmio=mmio
        self._offset=offset
        self._align=8
        self._dre=False
        self._max_size=2**23-1
        self._first_transfer=True
        self._active_buffer=None
        self.events,self.name=events,name

    @property
    def idle(self):return True

    def transfer(self,buffer,nbytes):
        self.events.append(('transfer',self.name,nbytes))
        self._active_buffer=buffer
        self._first_transfer=False


class MMIO:
    def __init__(self,events,dma,payload,jobs):
        self.events,self.dma,self.payload=events,dma,payload
        self.fault=None
        self.values={driver.REG_BUILD_ID:0x2026D075,driver.REG_CAPABILITIES:0x00080EFE,
                     driver.REG_STATUS:1,driver.REG_ERROR_CODE:0,0x12c:1,
                     driver.REG_CHAIN_JOBS:len(jobs),driver.REG_FAILED_TILE:0}
        cycles=cycles_fixture()
        self.set_u64(driver.REG_TOTAL_LO,driver.REG_TOTAL_HI,cycles['pl_total_cycles'])
        self.set_u64(driver.REG_COMPUTE_LO,driver.REG_COMPUTE_HI,0)
        self.set_u64(driver.REG_MACS_LO,driver.REG_MACS_HI,sum(j.effective_macs for j in jobs))
        pairs={'LOAD_WORK':'pl_load_work_cycles','ARRAY_WORK':'pl_array_work_cycles',
               'STORE_WORK':'pl_store_work_cycles','OUTPUT_WORK':'pl_output_work_cycles',
               'WORK_UNION':'pl_work_union_cycles','OVERLAP':'pl_overlap_credit_cycles',
               'NO_WORK':'pl_no_work_cycles','ARRAY_OUTPUT':'pl_array_output_work_overlap_cycles',
               'BANK_WAIT':'pl_compute_wait_bank_cycles','TREADY_WAIT':'pl_output_wait_tready_cycles'}
        for tag,key in pairs.items():
            self.set_u64(getattr(driver,'REG_D7_'+tag+'_LO'),getattr(driver,'REG_D7_'+tag+'_HI'),cycles[key])
        self.values[driver.REG_D7_CONTRACT]=2

    def set_u64(self,low,high,value):
        self.values[low]=value & 0xFFFFFFFF
        self.values[high]=value >> 32

    def read(self,offset):return self.values.get(offset,0)

    def write(self,offset,value):
        self.events.append(('write',offset,value))
        self.values[offset]=value
        if offset==driver.REG_CONTROL and value==driver.CONTROL_SOFT_RESET:
            self.values[driver.REG_STATUS]=1
            self.values[driver.REG_ERROR_CODE]=0
            self.values[0x12c]=1
        if offset==driver.REG_CONTROL and value==driver.CONTROL_START:
            out=self.dma.recvchannel._active_buffer
            out[:len(self.payload)]=np.frombuffer(self.payload,dtype=np.uint8)
            self.values[driver.REG_STATUS]=4 if self.fault!='pl_error' else 8
            self.values[driver.REG_ERROR_CODE]=0 if self.fault!='pl_error' else 7
            self.values[0x12c]=2


def cycles_fixture():
    return contract.summarize_cycles([
        dict(load=True,array=False,store=False,output=False,bank_wait=False,output_wait=False),
        dict(load=False,array=True,store=False,output=True,bank_wait=False,output_wait=False),
        dict(load=False,array=False,store=True,output=False,bank_wait=False,output_wait=False)])


class Lease:
    def __init__(self,events):
        self.events,self.fault=events,False
        self.entered=False
    def __enter__(self):
        self.entered=True
        self.events.append(('synthetic_lease_enter',))
        return self
    def audit(self):
        self.events.append(('lease_audit',))
        if self.fault:raise RuntimeError('synthetic lease lost')
        return {'source':'synthetic PC fixture, no canonical lock queried'}
    def __exit__(self,*exc):self.events.append(('lease_close',))


def fixture(jobs,payload,*,candidate=True):
    events=[]
    dma_mmio=DmaMMIO()
    dma=SimpleNamespace(sendchannel=Channel(dma_mmio,0,events,'send'),
                        recvchannel=Channel(dma_mmio,0x30,events,'recv'))
    cls=FlatPackPynqGemm if candidate else driver.PynqGemm
    runner=cls.__new__(cls)  # Do NOT call hardware constructor.
    runner._flat_pack_enabled=True
    runner.build_id,runner.capabilities=0x2026D075,0x00080EFE
    runner.dma=dma
    runner.mmio=MMIO(events,dma,payload,jobs)
    runner._recover=lambda:events.append(('synthetic_recover',))
    import chain_protocol
    wire,_=chain_protocol.pack_chain(jobs)
    tx=Buffer(len(wire),0x10000000,events,'tx')
    rx=Buffer(len(payload),0x20000000,events,'rx')
    return runner,tx,rx,events


def bank_arrays(index):
    return tuple(np.frombuffer((ROOT/'bank'/f'input_{index}_{name}.bin').read_bytes(),dtype=np.int8).reshape(512,512).copy() for name in ('a','b'))


def tiled_output(jobs,expected):
    import tiled_gemm
    chunks=[]
    for job in jobs:
        data=expected[job.m_offset:job.m_offset+job.actual_bm,job.n_offset:job.n_offset+job.actual_bn].astype('<i4').tobytes()
        chunks.append(data+b'\0'*(tiled_gemm.align_up(len(data))-len(data)))
    return b''.join(chunks)


def owner_fixture(runner,tx,rx,events,stop_requested):
    """Inject fake already-acquired resources; original owner methods run unchanged."""
    owner=BatchOwner(BatchPolicy('smoke8',enabled=True),stop_requested,enabled=True)
    owner._runner=runner
    owner._mmio,owner._dma=runner.mmio,runner.dma
    owner._channels=(runner.dma.sendchannel,runner.dma.recvchannel)
    owner._dma_mmio=owner._channels[0]._mmio
    owner._buffers=[tx,rx]
    owner._extents=(len(tx),len(rx))
    owner._lease=Lease(events)
    owner._used=True
    class Recovery:
        last_diagnostics={'source':'synthetic PC recovery'}
        def recover_and_confirm(self,r):
            events.append(('cleanup_recovery',))
            r.mmio.values[0x12c]=1
            r.mmio.values[driver.REG_STATUS]=1
            return True
    owner._recovery=Recovery()
    return owner
