"""Explicit Windows STUB BAT probe. Never selects an installed Vivado directory."""
from pathlib import Path
import hashlib
import json
import os
import sys
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
import rebuild
from test_windows_launcher import STUB_BAT

ROOT=Path(__file__).resolve().parent


def run(manifest_sha,directory,*,enabled=False):
    if enabled is not True:raise ValueError('stub probe default-off')
    if os.name!='nt':raise ValueError('Windows-only actual cmd stub probe')
    rebuild.verify.verify(ROOT,manifest_sha);rebuild.identity()
    folder=Path(directory).absolute()
    if folder.exists() or folder.resolve()!=folder or folder.is_relative_to(ROOT):
        raise ValueError('fresh canonical external stub evidence directory required')
    folder.mkdir();cases=[]
    for label,action,expected in [('normal_version','Version',0),('version_fail','Version',42),
                                  ('wrong_version','Version',0),('normal_build','Build',0),('build_fail','Build',42)]:
        work=folder/label;work.mkdir()
        tool=work/'假工具 with spaces (x86)';(tool/'bin').mkdir(parents=True)
        bat=tool/'bin/vivado.bat'
        with bat.open('xb') as stream:stream.write(STUB_BAT)
        assert bat.read_bytes()==STUB_BAT
        source=work/'source with spaces';(source/'synth').mkdir(parents=True)
        with (source/'synth/build_dma_loopback.tcl').open('xb') as stream:stream.write(b'# STUB only; no real Tcl execution\n')
        environment=rebuild.launcher.environment
        def inherited(original,*args):
            original.update(USERPROFILE='fixture_profile',APPDATA='fixture_appdata',
                LM_LICENSE_FILE='fixture_license_no_secret',OPENNPU_STUB_CASE=label,TCLLIBPATH='bad')
            return environment(original,*args)
        with patch.object(rebuild.launcher,'environment',side_effect=inherited):
            code=rebuild.launcher.run(tool,source,source/'not_existing_output',work,work/'tool',action)
        assert code==expected
        raw=(work/'tool.stdout').read_bytes()
        match=rebuild.exact_vivado_version(raw) if action=='Version' else None
        if action=='Version':assert match is (label!='wrong_version')
        row=dict(case=label,action=action,actual_exit_code=code,expected_exit_code=expected,
            exact_version_token=match,stub_bat_sha256=hashlib.sha256(STUB_BAT).hexdigest(),
            actual_vivado_started=False,board_access=False)
        cases.append(row)
    result=dict(cases=cases,actual_windows_cmd_processes=5,actual_vivado_started=False,
        real_license_checked=False,execution_policy_changed=False,profiles_in_test='synthetic sentinels',
        ready_for_actual_build=False,board_access=False,promotion=False)
    rebuild.write_new(folder/'summary.json',result)
    return result


def main():
    try:
        p=rebuild.verify.JsonParser();p.add_argument('--manifest-sha',required=True)
        p.add_argument('--evidence-dir',required=True);p.add_argument('--enabled-stub',action='store_true')
        a=p.parse_args();print(json.dumps(run(a.manifest_sha,a.evidence_dir,enabled=a.enabled_stub)));return 0
    except (ValueError,TypeError,KeyError,OSError) as error:
        print(json.dumps(dict(error=str(error),actual_vivado_started=False,board_access=False)),file=sys.stderr);return 2


if __name__=='__main__':sys.exit(main())
