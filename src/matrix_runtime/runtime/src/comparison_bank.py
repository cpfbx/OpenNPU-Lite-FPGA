"""Read-only, externally pinned data bank. Not a source-authentication signature."""
from dataclasses import dataclass
import hashlib
from pathlib import Path
import re
import numpy as np
import comparison_policy as policy
import verify_candidate as verifier


def sha(raw):return hashlib.sha256(raw).hexdigest()


def anchor(value):
    if type(value) is not str or re.fullmatch('[0-9a-f]{64}',value) is None:
        raise ValueError('external lowercase SHA256 required')
    return value


def checked_path(root,name):
    parsed=verifier.relative_name(name)
    path=root.joinpath(*parsed.parts)
    for item in [path,*path.parents]:verifier.no_alias(item)
    return path


@dataclass(frozen=True)
class BankPair:
    dimension:int
    input_id:int
    a:bytes
    b:bytes
    expected:bytes

    def arrays(self):
        values=[np.frombuffer(raw,dtype=np.int8).reshape(self.dimension,self.dimension).copy()
                for raw in (self.a,self.b)]
        for value in values:value.setflags(write=False)
        return tuple(values)


def load_bank(root,manifest_sha):
    root=Path(root).absolute()
    raw=checked_path(root,'bank_manifest.json').read_bytes()
    if sha(raw)!=anchor(manifest_sha):raise ValueError('bank manifest identity drift')
    document=verifier.read_json(raw)
    if (type(document) is not dict or document.get('schema')!='comparison-bank-v1'
            or document.get('byte_order')!='little'):
        raise ValueError('bank schema')
    rows=document.get('rows')
    if type(rows) is not list or len(rows)!=4:raise ValueError('four bank pairs required')
    pairs={}
    for row in rows:
        if type(row) is not dict or set(row)!={'dimension','input_id','assets'}:raise ValueError('bank row shape')
        dim=row['dimension'];policy.Geometry(dim);policy.integer(row['input_id'],42,43)
        key=dim,row['input_id']
        if key in pairs:raise ValueError('duplicate bank pair')
        fields=row['assets']
        if type(fields) is not dict or set(fields)!={'a','b','expected'}:raise ValueError('asset fields')
        values={}
        for name,item in fields.items():
            if type(item) is not dict or set(item)!={'path','bytes','sha256'}:raise ValueError('asset identity fields')
            expected_name=(f'bank256/input_{key[1]}_{name}.bin' if dim==256
                           else f'legacy/bank/input_{key[1]}_{name}.bin')
            if item['path']!=expected_name:raise ValueError('fixed asset mapping')
            size=dim**2*(4 if name=='expected' else 1)
            if type(item['bytes']) is not int or item['bytes']!=size:raise ValueError('asset exact size')
            data=checked_path(root,item['path']).read_bytes()
            if len(data)!=size or sha(data)!=anchor(item['sha256']):raise ValueError('bank asset drift')
            values[name]=data
        pairs[key]=BankPair(dim,key[1],**values)
    if set(pairs)!={(d,i) for d in policy.SHAPES for i in (42,43)}:raise ValueError('bank pair set')
    return pairs


def verify_output(pair,output):
    if type(pair) is not BankPair:raise ValueError('exact BankPair required')
    if type(output) is not np.ndarray or output.dtype!=np.int32 or output.shape!=(pair.dimension,)*2:
        raise ValueError('plain shaped INT32 output required')
    if not output.flags.c_contiguous:raise ValueError('C contiguous output required')
    expected=np.frombuffer(pair.expected,dtype='<i4').reshape(output.shape)
    if not np.array_equal(output,expected):raise ValueError('complete INT32 golden mismatch')
    return sha(output.astype('<i4',copy=False).tobytes())
