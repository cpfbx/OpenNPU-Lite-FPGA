"""OFFLINE, default-off: materialize each transposed panel before bytes export.

Adds a <=4096-byte contiguous temporary per pack, NOT zero-copy. No persistent
operand cache. Frozen validation/geometry/job order/record building stay intact.
No owner/driver wiring, PYNQ, DMA, native-library or board-launch API.
"""
import numpy as np
import tiled_gemm as frozen
import chain_protocol as chain
import matrix_panel_builder_candidate as original

base = original.base
K_MAJOR_SEGMENT = frozen.K_MAJOR_SEGMENT
k_major_groups = frozen.k_major_groups


def candidate_a_bytes(block, bm, actual_bk):
    groups = k_major_groups(bm)
    padded = np.zeros((groups * frozen.K_MAJOR_GROUP, frozen.K_MAJOR_BK), dtype=np.int8)
    padded[:bm, :actual_bk] = block
    view = np.transpose(padded.reshape(groups, frozen.K_MAJOR_GROUP, frozen.K_MAJOR_BK), (0, 2, 1))
    return np.ascontiguousarray(view).tobytes()


def candidate_b_bytes(block, bn, actual_bk):
    groups = k_major_groups(bn)
    padded = np.zeros((frozen.K_MAJOR_BK, groups * frozen.K_MAJOR_GROUP), dtype=np.int8)
    padded[:actual_bk, :bn] = block
    view = np.transpose(padded.reshape(frozen.K_MAJOR_BK, groups, frozen.K_MAJOR_GROUP), (1, 0, 2))
    return np.ascontiguousarray(view).tobytes()


def build_panel_layout_cached_transactions(a, b, config, *, enabled=False):
    # Body mechanically matches the pinned builder except the two pack helpers.
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
                    raw=candidate_a_bytes(a[mo:mo+bm,ko:ko+bk],bm,bk)
                    if len(raw)!=ab:
                        raise ValueError('frozen A segment length mismatch')
                    a_cache[a_key]=raw
                if b_key not in b_cache:
                    raw=candidate_b_bytes(b[ko:ko+bk,no:no+bn],bn,bk)
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
