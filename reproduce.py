"""Local export entry: check by default; explicit PC execution only. No build/board command."""
import argparse
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parent

def need(ok,msg):
    if not ok:raise ValueError(msg)
def pin(raw):return dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())

def verify(expected):
    body=(ROOT/'manifest.json').read_bytes();need(pin(body)['sha256']==expected,'external export manifest SHA mismatch')
    doc=json.loads(body);actual={}
    for p in ROOT.rglob('*'):
        need(not p.is_symlink() and not p.is_junction(),'plain export tree required')
        if p.is_file() and p!=ROOT/'manifest.json':actual[p.relative_to(ROOT).as_posix()]=pin(p.read_bytes())
    need(actual==doc['files'],'export member/size/SHA drift')
    return len(actual)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest-sha',required=True)
    p.add_argument('--profile',choices=('check','pc','hybrid-smoke','hybrid12'),default='check')
    p.add_argument('--output',type=Path)
    p.add_argument('--enable-offline',action='store_true')
    a=p.parse_args();count=verify(a.manifest_sha)
    if a.profile=='check':
        need(a.output is None and not a.enable_offline,'check does not execute or prepare output')
        print(json.dumps(dict(operation_success=True,files=count,inference_executed=False,board_access=False,publicly_released=False,promotion=False)))
        return 0
    need(a.enable_offline is True and a.output is not None,'explicit offline enable and fresh output required')
    need(platform.machine().lower() in ('amd64','x86_64'),'x86-64 PC only')
    output=a.output.resolve();need(not output.exists() and output.parent.is_dir() and not output.is_relative_to(ROOT) and not ROOT.is_relative_to(output),'fresh output outside immutable export')
    output.mkdir();cwd=output/'empty_cwd';cwd.mkdir()
    if a.profile=='pc':
        argv=[sys.executable,'-I','-B',str(ROOT/'src/pc_validation/run_pc.py'),'--manifest-sha','13b17023d130370f1e204d0f46d70f1046fae2af617171e6260f0467c449c630','--output',str(output/'results'),'--profile','pc']
    else:
        argv=[sys.executable,'-I','-B',str(ROOT/'src/reproduction/reproduce_offline.py'),'--candidate-archive',str(ROOT/'data/packages/kws_full_hybrid_return.zip'),'--prerequisites-archive',str(ROOT/'data/packages/kws_prerequisites.zip'),'--action','run','--mode','smoke1' if a.profile=='hybrid-smoke' else 'fixed12','--enable-hybrid-offline','--output',str(output/'results')]
    with (output/'stdout.txt').open('xb') as stdout,(output/'stderr.txt').open('xb') as stderr:
        proc=subprocess.run(argv,cwd=cwd,stdout=stdout,stderr=stderr,shell=False)
    verify(a.manifest_sha)
    result=dict(operation_success=proc.returncode==0,profile=a.profile,actual_exit=proc.returncode,argv=argv,
                immutable_export_verified_after=True,automatic_retry=False,automatic_kill=False,board_access=False,promotion=False)
    with (output/'receipt.json').open('x',encoding='utf8') as f:f.write(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='argv'}))
    return 0 if result['operation_success'] else 1

if __name__=='__main__':raise SystemExit(main())
