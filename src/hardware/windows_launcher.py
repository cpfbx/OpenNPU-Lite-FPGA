"""Fixed Windows cmd launcher; inherited license profile, no PowerShell/policy edits.

Trusted local packaging helper, not an execution sandbox. Paths containing CMD
metacharacters are explicitly unsupported instead of interpolated unsafely.
No retry, timeout-kill, profile redirection, network call or tool installation.
"""
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess

TOOL_VAR='_OPENNPU_INTERNAL_VIVADO_BAT'
TCL_VAR='_OPENNPU_INTERNAL_BUILD_TCL'
FIXED_ENV=dict(OPENNPU_ACCELERATOR='gemm',OPENNPU_ARRAY_SIZE='8',
    OPENNPU_INPUT_FIFO_DEPTH='0',OPENNPU_D007_P_HOLD_MARGIN='0',OPENNPU_MODE11_EXPERIMENT='1')


def safe_text(value):
    if (type(value) is not str or not value or any(ord(c)<32 for c in value)
            or any(c in value for c in '"%!?*&|<>^')):
        raise ValueError('path contains unsupported CMD metacharacters/control characters')
    return value


def checked_path(value,*,kind=None):
    path=Path(value)
    safe_text(str(path))
    if path.drive.startswith('\\\\'):raise ValueError('local drive paths required; UNC unsupported')
    if not path.is_absolute() or path.resolve()!=path:
        raise ValueError('absolute canonical launcher path required')
    for node in (path,*path.parents):
        try:info=node.lstat()
        except FileNotFoundError:continue
        if stat.S_ISLNK(info.st_mode) or getattr(info,'st_file_attributes',0)&0x400:
            raise ValueError('symlink/reparse launcher path unsupported')
    if kind=='file' and not path.is_file():raise ValueError('launcher input file missing')
    if kind=='dir' and not path.is_dir():raise ValueError('launcher directory missing')
    return path


def environment(inherited,tool,tcl,output,action):
    if type(inherited) is not dict:raise ValueError('inherited environment map required')
    if action not in ('Version','Build'):raise ValueError('fixed Version/Build action required')
    for value in (tool,tcl,output):safe_text(str(value))
    env=inherited.copy()
    # Windows environment names are case insensitive; remove aliases of ONLY
    # controlled keys so a lower-case stale value cannot defeat the fixed plan.
    controlled={TOOL_VAR,TCL_VAR}
    if action=='Build':controlled.update(FIXED_ENV);controlled.update(('TCLLIBPATH','OPENNPU_BUILD_OUTPUT_ROOT'))
    env={k:v for k,v in env.items() if k.upper() not in controlled}
    env[TOOL_VAR]=str(tool);env[TCL_VAR]=str(tcl)
    if action=='Build':
        env.update(FIXED_ENV);env['OPENNPU_BUILD_OUTPUT_ROOT']=str(output)
    return env


def command_line(cmd,action):
    safe_text(str(cmd))
    if action=='Version':tail=f'call "%{TOOL_VAR}%" -version'
    elif action=='Build':tail=f'call "%{TOOL_VAR}%" -mode batch -source "%{TCL_VAR}%" -nojournal -nolog'
    else:raise ValueError('fixed Version/Build action required')
    # Pass a raw CreateProcess command line with an explicit executable. Do not
    # use CRT list2cmdline escaping for CMD's different /c quote grammar.
    return f'"{cmd}" /d /v:off /s /c {tail}'


def run(vivado_root,source_root,output_root,cwd,stem,action):
    if os.name!='nt':raise ValueError('Windows-only launcher; no platform fallback')
    if action not in ('Version','Build'):raise ValueError('fixed Version/Build action required')
    tool=checked_path(Path(vivado_root)/'bin/vivado.bat',kind='file')
    source=checked_path(source_root,kind='dir')
    tcl=checked_path(source/'synth/build_dma_loopback.tcl',kind='file')
    output=checked_path(output_root)
    work=checked_path(cwd,kind='dir');stem=checked_path(stem)
    if stem.parent!=work:raise ValueError('launcher logs must be inside exact work directory')
    if action=='Build' and output.exists():raise ValueError('fresh build output required; no overwrite/retry')
    system=os.environ.get('SystemRoot') or os.environ.get('SYSTEMROOT')
    if not system:raise ValueError('Windows system directory unavailable')
    cmd=checked_path(Path(system)/'System32/cmd.exe',kind='file')
    line=command_line(cmd,action)
    env=environment(dict(os.environ),tool,tcl,output,action)
    paths={k:stem.with_suffix('.'+k) for k in ('stdout','stderr','receipt.json')}
    if any(p.exists() or p.is_symlink() for p in paths.values()):
        raise ValueError('fresh launcher log set required; no retry/overwrite')
    record=dict(action=action,command_line=line,executable=str(cmd),cwd=str(work),
        vivado_launcher=str(tool),source_tcl=str(tcl),
        started_utc=datetime.now(timezone.utc).isoformat(),actual_exit_code=None,
        exit_observed=False,environment_mode='inherited user/license profile; child-only fixed build variables',
        profile_redirected=False,powershell_used=False,execution_policy_changed=False,
        automatic_retry=False,automatic_kill=False,board_access=False)
    primary=None;value=None
    try:
        with paths['stdout'].open('xb') as out,paths['stderr'].open('xb') as err:
            process=subprocess.Popen(line,executable=str(cmd),cwd=work,env=env,
                stdout=out,stderr=err,shell=False,close_fds=True,
                creationflags=subprocess.CREATE_NO_WINDOW)
            record['pid']=process.pid
            value=process.wait()
            record.update(actual_exit_code=value,exit_observed=type(value) is int)
            if type(value) is not int:raise ValueError('actual wait must return non-bool integer')
    except BaseException as error:primary=error
    finally:
        record['ended_utc']=datetime.now(timezone.utc).isoformat()
        record['launch_error_type']=None if primary is None else type(primary).__name__
        for key in ('stdout','stderr'):
            if paths[key].exists():
                raw=paths[key].read_bytes();record[key+'_bytes']=len(raw)
                record[key+'_sha256']=hashlib.sha256(raw).hexdigest()
        try:
            with paths['receipt.json'].open('x',encoding='utf-8',newline='\n') as out:
                out.write(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
        except BaseException as error:
            if primary is None:primary=error
            else:primary.launcher_receipt_error_type=type(error).__name__
    if primary is not None:raise primary
    return value
