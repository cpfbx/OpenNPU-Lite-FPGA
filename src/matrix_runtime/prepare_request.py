"""DATA ONLY: verify bytes and prepare an external request; NEVER starts runtime.

No PYNQ/native imports, lock access, subprocess, SSH or OS configuration changes.
Fresh manual declarations are not physical authentication or approval by Codex.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('prepared_kit_verifier',ROOT/'verify_kit.py')
verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)

def parent_path(path):
    path=Path(path).absolute()
    for node in [path,*path.parents]:verifier.no_alias(node)
    if not path.is_dir() or path.resolve()!=path or path==ROOT or ROOT in path.parents:
        raise ValueError('existing canonical evidence parent outside kit required')
    return path

def prepare(manifest_sha,parent,declaration,confirm):
    verifier.verify(ROOT,manifest_sha)
    parent=parent_path(parent)
    if (type(declaration) is not str or not 1<=len(declaration)<=128
            or any(ord(c)<32 for c in declaration)):
        raise ValueError('nonempty bounded board declaration required; no credentials')
    if confirm!='PREPARE_PANEL72':raise ValueError('fresh bx preparation confirmation required')
    value=json.loads((ROOT/'request.template.json').read_bytes())
    value['request']['board_serial_declared']=declaration
    value['request']['operator_confirmed']=True
    for key in ('utc_verified','board_idle_verified','single_supply_verified','separate_scope_approved'):
        value[key]=True
    raw=(json.dumps(value,ensure_ascii=False,sort_keys=True)+'\n').encode('utf-8')
    # No overwrites or cleanup retry. Retain a partially written directory on error.
    folder=Path(tempfile.mkdtemp(prefix='panel72_run_',dir=parent))
    path=folder/'request.json'
    try:
        with path.open('xb') as stream:stream.write(raw);stream.flush()
        result=dict(schema='panel-preparation-data-v1',work_directory=str(folder),
            config=str(path),config_sha256=hashlib.sha256(raw).hexdigest(),
            evidence_directory=str(folder/'evidence'),kit_manifest_sha256=manifest_sha,
            declarations_supplied_by_operator=True,physical_identity_authenticated=False,
            runtime_started=False,lock_access=False,board_access=False,promotion=False)
        with (folder/'preparation.json').open('xb') as stream:
            stream.write((json.dumps(result,ensure_ascii=False,sort_keys=True)+'\n').encode('utf-8'))
    except BaseException as error:
        error.preparation_directory=str(folder);raise
    return result

def main():
    try:
        p=verifier.JsonParser(description=__doc__)
        p.add_argument('--kit-manifest-sha',required=True)
        p.add_argument('--prepare-data-only',action='store_true')
        p.add_argument('--evidence-parent',type=Path)
        p.add_argument('--board-declaration')
        args=p.parse_args()
        verifier.verify(ROOT,args.kit_manifest_sha)
        if not args.prepare_data_only:
            print(json.dumps(dict(preview_only=True,runtime_started=False,board_access=False,
                request_template=json.loads((ROOT/'request.template.json').read_bytes())),ensure_ascii=False));return 0
        if args.evidence_parent is None or args.board_declaration is None:
            raise ValueError('explicit parent and board declaration required')
        print('DATA ONLY, no test starts. bx must already approve this exact kit/scope and verify UTC, idle and wiring.')
        confirmation=input('If ALL declarations are freshly true, type PREPARE_PANEL72; otherwise stop: ')
        print(json.dumps(prepare(args.kit_manifest_sha,args.evidence_parent,args.board_declaration,confirmation),ensure_ascii=False));return 0
    except (ValueError,OSError,RuntimeError,EOFError,KeyError,TypeError) as error:
        print(json.dumps(dict(error_type=type(error).__name__,error=str(error),
            retained_directory=getattr(error,'preparation_directory',None),runtime_started=False,
            board_access=False,promotion=False)),file=sys.stderr);return 2

if __name__=='__main__':sys.exit(main())
