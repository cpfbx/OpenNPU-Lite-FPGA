"""Bounded first Call-error sidecar, published BEFORE cleanup or retained supervisor.

ready.json is staged metadata. Only an empty committed.flag publishes readiness;
its exclusive creation has no content-write window. Neither certifies cleanup.
No stdout protocol change, hardware access, lock operation, retries or overwrites.
"""
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import stat
from round_artifacts import checked_request
from cpu_frames import encode

sha=lambda b:hashlib.sha256(b).hexdigest()

def canonical(path):
    path=Path(path).absolute()
    for node in [path,*path.parents]:
        if os.path.lexists(node):
            st=node.lstat()
            if stat.S_ISLNK(st.st_mode) or getattr(st,'st_file_attributes',0)&0x400:
                raise ValueError('journal symlink/reparse point forbidden')
    if path.resolve()!=path:raise ValueError('canonical journal path required')
    return path

def exclusive(path,raw):
    with path.open('xb') as stream:
        stream.write(raw);stream.flush();os.fsync(stream.fileno())

def bounded_read(path,limit):
    path=canonical(path);before=path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1 or before.st_size>limit:
        raise ValueError('bounded single-link regular journal member required')
    with path.open('rb') as stream:
        opened=os.fstat(stream.fileno());raw=stream.read(limit+1);after=os.fstat(stream.fileno())
    final=path.lstat()
    identity=lambda st:(st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns,st.st_nlink)
    if len(raw)>limit or any(identity(st)!=identity(before) for st in (opened,after,final)):
        raise ValueError('journal member changed during read')
    return raw

def strict_json(raw):
    def pairs(rows):
        result={}
        for key,value in rows:
            if key in result:raise ValueError('duplicate journal key')
            result[key]=value
        return result
    def bad(value):raise ValueError('nonfinite journal JSON')
    return json.loads(raw,object_pairs_hook=pairs,parse_constant=bad)

class JournalFault(RuntimeError):
    pass

class FailureJournal:
    def __init__(self,directory):
        self.folder=canonical(directory);self.used=False
        if os.path.lexists(self.folder):raise ValueError('fresh failure journal required')
        self.folder.mkdir()

    def capture(self,spec,error):
        checked_request(spec)
        if self.used:raise RuntimeError('first fault journal single-use')
        self.used=True
        payload=getattr(error,'matrix_returned_payload',None)
        if payload is not None and (type(payload) is not bytes or len(payload)!=spec.dimension**2*4):
            raise ValueError('exact bounded chain output attachment required')
        metadata=dict(schema='threeway-call-fault-v1',request=asdict(spec),pid=os.getpid(),
            error_type=type(error).__name__,encoding='chain-tiled-int32-le',
            payload_available=payload is not None,payload_bytes=0 if payload is None else len(payload),
            payload_sha256=None if payload is None else sha(payload),
            cleanup_observed=False,release_authorized=False)
        if payload is not None:exclusive(self.folder/'first_fault.bin',payload)
        raw=encode(metadata);exclusive(self.folder/'first_fault.json',raw)
        exclusive(self.folder/'ready.json',encode(dict(metadata_sha256=sha(raw))))
        # All bounded data/hash files are already flushed and closed. Unlike a
        # JSON marker, this empty file is complete at the instant open('xb')
        # creates it. No rename-overwrite or relaxation for malformed data.
        exclusive(self.folder/'committed.flag',b'')
        return metadata

def read_ready(directory,policy,pid):
    folder=canonical(directory)
    if not os.path.lexists(folder/'committed.flag'):return None
    if bounded_read(folder/'committed.flag',0)!=b'':raise ValueError('empty journal commit required')
    marker=strict_json(bounded_read(folder/'ready.json',1024))
    if type(marker) is not dict or set(marker)!={'metadata_sha256'}:raise ValueError('journal marker shape')
    raw=bounded_read(folder/'first_fault.json',8192)
    if marker['metadata_sha256']!=sha(raw):raise ValueError('journal metadata digest drift')
    meta=strict_json(raw)
    keys={'schema','request','pid','error_type','encoding','payload_available','payload_bytes',
          'payload_sha256','cleanup_observed','release_authorized'}
    if type(meta) is not dict or set(meta)!=keys:raise ValueError('journal exact fields required')
    request=meta['request']
    if type(request) is not dict or type(request.get('local_index')) is not int:
        raise ValueError('journal request identity')
    spec=policy.request(request['local_index']);wanted=asdict(spec)
    if (request!=wanted or any(type(request.get(k)) is not type(v) for k,v in wanted.items())
            or type(meta['pid']) is not int or meta['pid']!=pid
            or meta['schema']!='threeway-call-fault-v1' or meta['encoding']!='chain-tiled-int32-le'
            or meta['cleanup_observed'] is not False or meta['release_authorized'] is not False
            or type(meta['payload_available']) is not bool or type(meta['payload_bytes']) is not int
            or type(meta['error_type']) is not str or not 1<=len(meta['error_type'])<=128):
        raise ValueError('journal bound request/pid/claims drift')
    if meta['payload_available']:
        payload=bounded_read(folder/'first_fault.bin',spec.dimension**2*4)
        if len(payload)!=spec.dimension**2*4 or meta['payload_bytes']!=len(payload) or meta['payload_sha256']!=sha(payload):
            raise ValueError('journal full output digest/extent drift')
    else:
        payload=None
        if meta['payload_bytes']!=0 or meta['payload_sha256'] is not None or os.path.lexists(folder/'first_fault.bin'):
            raise ValueError('journal absent payload mismatch')
    return spec,meta,payload
