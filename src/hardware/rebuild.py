"""Offline source build packaging candidate, not a production/board launcher."""
from datetime import datetime,timezone
from decimal import Decimal
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import zipfile

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('cold_build_verify',ROOT/'verify_kit.py')
verify=importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
launcher_spec=importlib.util.spec_from_file_location('cold_build_windows_launcher',ROOT/'windows_launcher.py')
launcher=importlib.util.module_from_spec(launcher_spec)
launcher_spec.loader.exec_module(launcher)


def require(ok,message):
    if not ok: raise ValueError(message)


def sha(raw): return hashlib.sha256(raw).hexdigest()


def exact_vivado_version(raw):
    """Match a complete release token, not the prefix of 2026.10/2026.1.1."""
    return re.search(rb'(?m)^\s*Vivado[ \t]+v?2026\.1(?=[ \t\r\n]|$)',raw) is not None


def document(path): return verify.read_json(Path(path).read_bytes())


def write_new(path,value):
    with Path(path).open('x',encoding='utf-8',newline='\n') as stream:
        stream.write(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n')


def identity():
    value=document(ROOT/'source_identity.json')
    require(len(value['original_build_input_sha256'])==47,'47 original build inputs')
    for name,expected in value['files'].items():
        verify.relative_name(name)
        raw=(ROOT/'source'/name).read_bytes()
        require({'bytes':len(raw),'sha256':sha(raw)}==expected,'source bytes/hash')
    expected_aliases={n.lower():n for n in value['original_build_input_sha256'] if n!=n.lower()}
    require(value['distribution_to_build_path']==expected_aliases,'exact distribution/build path aliases')
    require(all(value['files'][n.lower()]['sha256']==h for n,h in value['original_build_input_sha256'].items()),'original input hash binding')
    return value


def outside_kit(path):
    path=Path(path)
    require(path.is_absolute(),'absolute fresh work directory required')
    for ancestor in (path.parent,*path.parent.parents): verify.no_alias(ancestor)
    require(not path.exists() and not path.is_symlink(),'work directory already exists')
    require(not path.is_relative_to(ROOT) and not ROOT.is_relative_to(path),'work must be outside kit')
    return path


def prepare(work,board_zip):
    config=identity()
    work=outside_kit(work)
    board_zip=Path(board_zip)
    require(board_zip.is_file(),'download the specified board ZIP separately first')
    raw=board_zip.read_bytes()
    require(sha(raw)==config['board_definition']['sha256'] and len(raw)==config['board_definition']['bytes'],'board ZIP identity')
    with zipfile.ZipFile(board_zip) as archive:
        info=archive.infolist()
        require(len(info)==6 and len({i.filename for i in info})==6,'board archive member count')
        for item in info:
            verify.relative_name(item.filename.rstrip('/'))
            require(not stat.S_ISLNK(item.external_attr>>16),'board archive symlink')
    work.mkdir(exist_ok=False)
    source=work/'source'
    source.mkdir()
    for name in config['files']:
        target=source/config['distribution_to_build_path'].get(name,name)
        target.parent.mkdir(parents=True,exist_ok=True)
        with target.open('xb') as stream: stream.write((ROOT/'source'/name).read_bytes())
    vendor=source/'.vendor/pynq-z2-board'
    vendor.mkdir(parents=True)
    with (vendor/'pynq-z2.zip').open('xb') as stream: stream.write(raw)
    with zipfile.ZipFile(board_zip) as archive: archive.extractall(vendor/'files')
    require((vendor/'files/pynq-z2/A.0/preset.xml').is_file(),'board preset missing')
    write_new(work/'prepared.json',{'historical_commit':config['historical_commit'],
                                  'source_files':config['files'],'board_zip_sha256':sha(raw),
                                  'source_snapshot_not_git_checkout':True,'vivado_started':False,
                                  'package_source_identity_sha256':sha((ROOT/'source_identity.json').read_bytes())})
    return {'prepared':True,'source_files':len(config['files']),'original_inputs':47,'vivado_started':False}


def prepared(work):
    work=Path(work)
    require(work.is_absolute() and work.is_dir(),'absolute prepared work directory')
    for ancestor in (work,*work.parents): verify.no_alias(ancestor)
    require(not work.is_relative_to(ROOT),'runtime outside kit')
    state=document(work/'prepared.json')
    config=identity()
    require(state['package_source_identity_sha256']==sha((ROOT/'source_identity.json').read_bytes()),'prepared identity')
    require(state['source_files']==config['files'],'prepared source map')
    for name,expected in config['files'].items():
        path=work/'source'/config['distribution_to_build_path'].get(name,name)
        for node in (path,*path.parents): verify.no_alias(node)
        raw=path.read_bytes()
        require({'bytes':len(raw),'sha256':sha(raw)}==expected,'prepared source changed')
    vendor=work/'source/.vendor/pynq-z2-board'
    require(sha((vendor/'pynq-z2.zip').read_bytes())==config['board_definition']['sha256'],'prepared board zip changed')
    with zipfile.ZipFile(vendor/'pynq-z2.zip') as archive:
        expected_files={i.filename:archive.read(i) for i in archive.infolist() if not i.is_dir()}
    actual,_=verify.inventory(vendor/'files')
    require(actual=={n:{'bytes':len(v),'sha256':sha(v)} for n,v in expected_files.items()},'extracted board definition changed')
    return config


def payload(raw):
    require(len(raw)>16,'short BIT')
    first=int.from_bytes(raw[:2],'big')
    offset=2+first
    require(offset+2<len(raw) and raw[offset:offset+2]==b'\x00\x01','BIT key framing')
    offset+=2
    for key in b'abcd':
        require(raw[offset:offset+1]==bytes([key]),'BIT header field')
        count=int.from_bytes(raw[offset+1:offset+3],'big')
        offset+=3+count
        require(offset<len(raw),'BIT field exceeds extent')
    require(raw[offset:offset+1]==b'e','BIT payload tag')
    count=int.from_bytes(raw[offset+1:offset+5],'big')
    offset+=5
    require(count>0 and offset+count==len(raw),'BIT payload extent')
    return raw[offset:]


def timing(text):
    require('WNS(ns)' in text,'timing summary header')
    body=text.split('WNS(ns)',1)[1]
    matches=[]
    for line in body.splitlines():
        if re.fullmatch(r'\s*[+-]?\d+(?:\.\d+)?(?:\s+[+-]?\d+(?:\.\d+)?){11}\s*',line):
            matches.append(line.split())
    require(bool(matches),'timing summary numeric row')
    values=[Decimal(x) for x in matches[0]]
    return {'wns_ns':str(values[0]),'whs_ns':str(values[4]),'wpws_ns':str(values[8]),
            'setup_failing':int(values[2]),'hold_failing':int(values[6]),'pulse_failing':int(values[10]),
            'natural_timing_closed':all(values[i]>=0 for i in (0,4,8)) and all(values[i]==0 for i in (2,6,10))}


def child(argv,cwd,stem):
    start=datetime.now(timezone.utc).isoformat()
    result=None
    try:
        with stem.with_suffix('.stdout').open('xb') as out,stem.with_suffix('.stderr').open('xb') as err:
            process=subprocess.Popen(argv,cwd=cwd,stdout=out,stderr=err)
            result=process.wait()
    finally:
        write_new(stem.with_suffix('.receipt.json'),{'argv':argv,'cwd':str(cwd),'started_utc':start,
              'ended_utc':datetime.now(timezone.utc).isoformat(),'actual_exit_code':result,
              'exit_observed':result is not None,'board_access':False})
    return result


def collect(work):
    config=prepared(work)
    work=Path(work)
    run=document(work/'build.receipt.json')
    require(type(run['actual_exit_code']) is int and run['actual_exit_code']==0 and run['exit_observed'] is True,'actual successful tool exit required')
    reports=work/'source/.board-work/full_overlay/reports'
    names={'bit':'opennpu_gemm_accelerator.bit','hwh':'opennpu_gemm_accelerator.hwh',
           'xsa':'opennpu_gemm_accelerator.xsa','timing':'gemm_accelerator_implementation_timing_summary.rpt',
           'constrained_timing':'gemm_accelerator_implementation_constrained_timing_summary.rpt',
           'utilization':'gemm_accelerator_implementation_utilization.rpt'}
    artifacts={}
    for key,name in names.items():
        raw=(reports/name).read_bytes()
        artifacts[key]={'relative_path':(reports/name).relative_to(work).as_posix(),'bytes':len(raw),'sha256':sha(raw)}
    data=payload((reports/names['bit']).read_bytes())
    t=timing((reports/names['timing']).read_text('utf-8',errors='strict'))
    require(t['natural_timing_closed'],'natural setup/hold/pulse failed')
    import xml.etree.ElementTree as ET
    ET.fromstring((reports/names['hwh']).read_bytes())
    expected=config['historical_reference']
    result={'scope':'new packaging wrapper build observation, not board/performance acceptance',
            'historical_source_commit':config['historical_commit'],'source_snapshot_not_git_checkout':True,
            'original_47_input_hashes_match':True,'actual_build_exit':0,'artifacts':artifacts,
            'timing':t,'configuration_payload_sha256':sha(data),'configuration_payload_bytes':len(data),
            'payload_matches_historical':sha(data)==expected['configuration_payload_sha256'] and len(data)==expected['configuration_payload_bytes'],
            'historical_reference_not_new_thresholds':expected,'needs_human_engineering_review':True,
            'board_access':False,'promotion':False}
    write_new(work/'build_observation.json',result)
    return result


def build(work,vivado_root,confirmation):
    require(confirmation=='OFFLINE_BUILD_ONLY','explicit build-only confirmation required')
    require(os.name=='nt','candidate launcher is Windows-only')
    prepared(work)
    work=Path(work)
    require(not (work/'source/.board-work/full_overlay').exists(),'fresh build output required')
    require(Path(vivado_root).is_absolute() and (Path(vivado_root)/'bin/vivado.bat').is_file(),'absolute Vivado root')
    with (work/'build_claim.json').open('x',encoding='utf-8') as stream:
        json.dump({'confirmation':confirmation,'started_utc':datetime.now(timezone.utc).isoformat(),'board_access':False},stream)
    output=work/'source/.board-work/full_overlay'
    def invoke(action,stem):
        try:return launcher.run(vivado_root,work/'source',output,work,stem,action)
        except (ValueError,OSError) as error:
            raise ValueError(action.lower()+'_launcher_failed: '+str(error)) from error
    code=invoke('Version',work/'version')
    require(type(code) is int and code==0,
            'version_query_failed: inspect version.stdout/stderr/receipt.json; no retry')
    require(exact_vivado_version((work/'version.stdout').read_bytes()),
            'version_mismatch: exact installed Vivado 2026.1 required')
    code=invoke('Build',work/'build')
    require(type(code) is int and code==0,
            'build_failed: inspect build.stdout/stderr/receipt.json; preserve work, no retry')
    return collect(work)


def main():
    try:
        parser=verify.JsonParser()
        parser.add_argument('operation',choices=['check','prepare','build','collect'])
        parser.add_argument('--manifest-sha',required=True)
        parser.add_argument('--work')
        parser.add_argument('--board-zip')
        parser.add_argument('--vivado-root')
        parser.add_argument('--confirm')
        args=parser.parse_args()
        verify.verify(ROOT,args.manifest_sha)
        identity()
        if args.operation=='check': result={'offline_package_check':True,'original_inputs':47,'vivado_started':False,'run_ready':False}
        elif args.operation=='prepare':
            require(bool(args.work and args.board_zip),'work and board ZIP required')
            result=prepare(args.work,args.board_zip)
        elif args.operation=='build':
            require(bool(args.work and args.vivado_root),'work and Vivado root required')
            result=build(args.work,args.vivado_root,args.confirm)
        else:
            require(bool(args.work),'work required')
            result=collect(args.work)
        print(json.dumps(result,ensure_ascii=False,allow_nan=False))
        return 0
    except (ValueError,TypeError,KeyError,OSError,ArithmeticError,zipfile.BadZipFile) as exc:
        print(json.dumps({'success':False,'error':str(exc),'board_access':False}),file=sys.stderr)
        return 2


if __name__=='__main__':sys.exit(main())
