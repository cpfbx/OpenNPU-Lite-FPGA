"""Default-off diagnostic builder: request-local K-major panel/layout reuse.

Separate board-capable implementation, not a bypass of PC-only prototypes.
No resources, persistent cache, alternate protocol, or input views retained.
"""
from dataclasses import dataclass
from types import SimpleNamespace
from tiled_gemm import (BlockLayout, Layout, TileConfig, TileTransaction,
    _validate_inputs, _k_major_a_bytes, _k_major_b_bytes,
    K_MAJOR_SEGMENT, k_major_groups)

@dataclass(frozen=True)
class CachedConstruction:
    transactions: tuple
    a_pack_calls: int
    b_pack_calls: int
    cache_bytes: int

base = SimpleNamespace(TileConfig=TileConfig, Layout=Layout, BlockLayout=BlockLayout,
    TileTransaction=TileTransaction, _validate_inputs=_validate_inputs,
    _k_major_a_bytes=_k_major_a_bytes, _k_major_b_bytes=_k_major_b_bytes,
    CachedConstruction=CachedConstruction)


def build_panel_layout_cached_transactions(a, b, config, *, enabled=False):
    if enabled is not True:
        raise ValueError('panel/layout prototype default-off')
    if type(config) is not base.TileConfig or config.layout != base.Layout.K_MAJOR:
        raise ValueError('explicit frozen K-major TileConfig required')
    m,n,k = base._validate_inputs(a,b,config)
    a_cache,b_cache,layouts,jobs = {},{},{},[]
    for mo in range(0,m,config.bm):
        bm=min(config.bm,m-mo)
        for no in range(0,n,config.bn):
            bn=min(config.bn,n-no)
            geometry=(bm,bn)
            ab=k_major_groups(bm)*K_MAJOR_SEGMENT
            bb=k_major_groups(bn)*K_MAJOR_SEGMENT
            if geometry not in layouts:
                layouts[geometry]=tuple(base.BlockLayout(ko,min(config.bk,k-ko),
                    index*(ab+bb),ab,index*(ab+bb)+ab,bb)
                    for index,ko in enumerate(range(0,k,config.bk)))
            blocks=layouts[geometry]
            pieces=[]
            for block in blocks:
                ko,bk=block.k_offset,block.actual_bk
                a_key,b_key=(mo,ko),(ko,no)
                if a_key not in a_cache:
                    raw=base._k_major_a_bytes(a[mo:mo+bm,ko:ko+bk],bm,bk)
                    if len(raw)!=ab:
                        raise ValueError('frozen A segment length mismatch')
                    a_cache[a_key]=raw
                if b_key not in b_cache:
                    raw=base._k_major_b_bytes(b[ko:ko+bk,no:no+bn],bn,bk)
                    if len(raw)!=bb:
                        raise ValueError('frozen B segment length mismatch')
                    b_cache[b_key]=raw
                pieces.extend((a_cache[a_key],b_cache[b_key]))
            payload=b''.join(pieces)
            if len(payload)!=len(blocks)*(ab+bb):
                raise ValueError('payload extent mismatch')
            jobs.append(base.TileTransaction(m,n,k,mo,no,bm,bn,config,payload,
                                             k*(bm+bn),blocks))
    return base.CachedConstruction(tuple(jobs),len(a_cache),len(b_cache),
        sum(map(len,a_cache.values()))+sum(map(len,b_cache.values())))
