"""Bounded protocol; only a single full output may be outstanding."""
import json


def encode(value):return (json.dumps(value,sort_keys=True,allow_nan=False)+'\n').encode('utf-8')


def decode(raw):
    def unique(items):
        result={}
        for k,v in items:
            if k in result:raise ValueError('duplicate protocol key')
            result[k]=v
        return result
    def nonfinite(value):raise ValueError('nonfinite protocol number')
    value=json.loads(raw,object_pairs_hook=unique,parse_constant=nonfinite)
    if type(value) is not dict:raise ValueError('protocol object required')
    return value


def line(stream):
    raw=stream.readline(8193)
    if not raw:return None
    if len(raw)>8192 or not raw.endswith(b'\n'):raise ValueError('bounded complete protocol line required')
    return decode(raw)


def read_exact(stream,count):
    if type(count) is not int or not 0<count<=1048576:raise ValueError('bounded output size required')
    output=bytearray()
    while len(output)<count:
        chunk=stream.read(min(65536,count-len(output)))
        if not chunk:raise ValueError('truncated CPU output')
        output.extend(chunk)
    return bytes(output)


def exact_row(row,wanted):
    if (type(row) is not dict or set(row)!=set(wanted)
            or any(type(row[k]) is not type(v) or row[k]!=v for k,v in wanted.items())):
        raise ValueError('exact typed protocol identity/order required')


def write_new(path,value):
    from pathlib import Path
    with Path(path).open('xb') as stream:stream.write(encode(value));stream.flush()
