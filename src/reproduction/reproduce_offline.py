"""Pinned PC-only reproduction wrapper. Default action verifies bytes without inference."""
import argparse
import hashlib
import json
import platform
import stat
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath

ROOT=Path(__file__).resolve().parent
PROJECT=ROOT.parent.parent
RETURN_PIN='9bf656729adb4fdd65f549b825c9c6bb66d5ca847352fc25e9f99504c4a96664'
RETURN_MANIFEST='890807cd2e7f009c1d4cd50c0d8c478d2024f8c111db0779d9794a9810228eac'
PREREQ_PIN='fae95a89a7bbefc4a26f281e05997b1ff7df8e9b68d44735a954e61c6ac49bd4'
PREREQ_MANIFEST='524927755ea6e403c834fee7a518a0c9d2816b499a305a2c154a27b32f55e357'
CANDIDATE_MANIFEST='e9fe21968e8ba302799d747e63bd0fc0f18dcc041ad741db141b731943e6a2d6'

def need(ok,why):
    if not ok:raise ValueError(why)
def pin(raw):return dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
def write_json(path,obj):
    with path.open('x',encoding='utf8') as f:f.write(json.dumps(obj,indent=2,sort_keys=True)+'\n')

def check_archive(path,expected,manifest_name,manifest_pin):
    need(path.is_file() and not path.is_symlink() and not path.is_junction(),'plain local input archive required')
    ident=pin(path.read_bytes());need(ident['sha256']==expected,'external archive SHA mismatch')
    with zipfile.ZipFile(path) as z:
        infos=z.infolist();need(0<len(infos)<2048,'bounded archive members')
        names=set();total=0
        for info in infos:
            name=info.filename;p=PurePosixPath(name)
            need(name and '\\' not in name and ':' not in name and not p.is_absolute() and '..' not in p.parts
                 and p.as_posix()==name.rstrip('/'),'safe archive path')
            need(name.casefold() not in names and not stat.S_ISLNK(info.external_attr>>16) and not info.flag_bits&1,'unique unencrypted regular member')
            names.add(name.casefold());total+=info.file_size
            need(info.file_size<32*1024*1024 and total<256*1024*1024,'bounded archive extent')
        raw=z.read(manifest_name);need(pin(raw)['sha256']==manifest_pin,'external manifest SHA mismatch')
        indexed=json.loads(raw)['files']
        need({i.filename for i in infos if not i.is_dir()}==set(indexed)|{manifest_name},'exact indexed member set')
        for name,item in indexed.items():need(pin(z.read(name))==item,'indexed member identity mismatch')
        if manifest_name=='MANIFEST.json':
            need(pin(z.read('candidate/manifest.json'))['sha256']==CANDIDATE_MANIFEST,'candidate manifest SHA mismatch')
        return dict(path=str(path),**ident,members=len(infos))

def extract(path,dest,prefix=None):
    dest.mkdir()
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            if prefix is not None and not info.filename.startswith(prefix):continue
            relative=info.filename[len(prefix):] if prefix else info.filename
            if not relative:continue
            target=dest.joinpath(*PurePosixPath(relative).parts)
            if info.is_dir():target.mkdir(parents=True,exist_ok=True);continue
            target.parent.mkdir(parents=True,exist_ok=True)
            with target.open('xb') as f:f.write(z.read(info))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--action',choices=('verify','run'),default='verify')
    p.add_argument('--mode',choices=('smoke1','fixed12','all'),default='smoke1')
    p.add_argument('--candidate-archive',type=Path,default=PROJECT/'.offline-results/KWS-full-hybrid-review-20261027_01/original/opennpu_kws_full_hybrid_candidate_v1_return.zip')
    p.add_argument('--prerequisites-archive',type=Path,default=PROJECT/'.offline-results/KWS-full-hybrid-handoff-20261027_01/opennpu_kws_full_hybrid_prerequisites_v1.zip')
    p.add_argument('--output',type=Path)
    p.add_argument('--enable-hybrid-offline',action='store_true')
    a=p.parse_args();candidate=a.candidate_archive.resolve();prereq=a.prerequisites_archive.resolve()
    inputs=dict(candidate=check_archive(candidate,RETURN_PIN,'MANIFEST.json',RETURN_MANIFEST),
                prerequisites=check_archive(prereq,PREREQ_PIN,'manifest.json',PREREQ_MANIFEST))
    if a.action=='verify':
        need(a.output is None and not a.enable_hybrid_offline,'verify does not prepare outputs or infer')
        print(json.dumps(dict(operation_success=True,scope='local immutable input bytes only',inputs=inputs,inference_executed=False,board_access=False,promotion=False)))
        return 0
    need(a.enable_hybrid_offline is True,'run requires explicit --enable-hybrid-offline')
    need(platform.machine().lower() in ('amd64','x86_64'),'reviewed x86-64 PC only; no ARM/board entry')
    need(a.output is not None,'fresh output required for run')
    output=a.output.resolve()
    need(not output.exists() and output.parent.is_dir(),'fresh output with existing parent required')
    for archive in (candidate,prereq):
        need(not output.is_relative_to(archive.parent) and not archive.is_relative_to(output),'output must be outside input archive directory')
    need(not output.is_relative_to(ROOT) or output.parent==ROOT,'use direct fresh child or external output')
    # Dependency check is read-only and never installs packages.
    import numpy
    output.mkdir();extract(candidate,output/'candidate',prefix='candidate/');extract(prereq,output/'handoff')
    cwd=output/'empty_cwd';cwd.mkdir();steps=[]
    commands=[('unpack_sources',[sys.executable,'-I','-B',str(output/'handoff/unpack_sources.py'),'--manifest-sha',PREREQ_MANIFEST,'--output',str(output/'sources')]),
              ('candidate_'+a.mode,[sys.executable,'-I','-B',str(output/'candidate/run_hybrid_candidate.py'),'--manifest-sha',CANDIDATE_MANIFEST,'--sources',str(output/'sources'),'--output',str(output/'results'),'--mode',a.mode,'--enable-hybrid-offline'])]
    for name,argv in commands:
        with (output/(name+'.stdout.txt')).open('xb') as stdout,(output/(name+'.stderr.txt')).open('xb') as stderr:
            proc=subprocess.run(argv,cwd=cwd,stdout=stdout,stderr=stderr,shell=False)
        steps.append(dict(name=name,argv=argv,actual_exit=proc.returncode))
        if proc.returncode!=0:break
    unchanged=pin(candidate.read_bytes())['sha256']==RETURN_PIN and pin(prereq.read_bytes())['sha256']==PREREQ_PIN
    success=len(steps)==2 and all(s['actual_exit']==0 for s in steps) and unchanged and not list(cwd.iterdir())
    receipt=dict(operation_success=success,scope='PC offline reproduction; not board execution',mode=a.mode,inputs=inputs,steps=steps,
                 inputs_unchanged=unchanged,python=sys.version,numpy=numpy.__version__,machine=platform.machine(),
                 inference_executed=len(steps)==2,automatic_retry=False,automatic_kill=False,board_access=False,real_DMA_executed=False,
                 vad_recomputed=False,promotion=False)
    write_json(output/'reproduction_receipt.json',receipt)
    print(json.dumps(dict(operation_success=success,receipt=str(output/'reproduction_receipt.json'),actual_exits=[s['actual_exit'] for s in steps],board_access=False,promotion=False)))
    return 0 if success else 1

if __name__=='__main__':raise SystemExit(main())
