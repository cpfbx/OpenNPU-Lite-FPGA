"""Read-only Linux lock evidence. Never acquires, creates, removes or repairs locks."""
import os
from pathlib import Path
import re
import stat
from os_evidence import LOCK,parse_fdinfo,process_start,read_text


def snapshot():
    value=os.lstat(LOCK)
    if not stat.S_ISREG(value.st_mode) or value.st_nlink!=1:
        raise ValueError('existing canonical single-link regular lock required')
    return dict(device=value.st_dev,inode=value.st_ino,path=LOCK)


def verify_live(ticket,pid,identity):
    if type(pid) is not int or pid<=1 or type(ticket) is not dict:
        raise ValueError('exact worker PID and lock ticket required')
    for field in ('pid','fd','device','inode','process_start_ticks'):
        if type(ticket.get(field)) is not int or ticket[field]<(0 if field in ('fd','device') else 1):
            raise ValueError('exact integer ticket fields')
    if (ticket['pid']!=pid or ticket.get('path')!=LOCK or snapshot()!=identity
            or (ticket['device'],ticket['inode'])!=(identity['device'],identity['inode'])):
        raise RuntimeError('child lock ticket identity mismatch')
    root=Path('/proc')/str(pid)
    if process_start(read_text(root/'stat',8192))!=ticket['process_start_ticks']:
        raise RuntimeError('child process start identity drift')
    opened=(root/'fd'/str(ticket['fd'])).stat()
    if (opened.st_dev,opened.st_ino)!=(identity['device'],identity['inode']):
        raise RuntimeError('child fd inode mismatch')
    if os.getpgid(pid)!=pid or os.getsid(pid)!=pid:
        raise RuntimeError('worker must lead its dedicated group/session')
    parse_fdinfo(read_text(root/'fdinfo'/str(ticket['fd'])),pid=pid,
                 device=identity['device'],inode=identity['inode'])
    return True


def released(identity):
    if snapshot()!=identity:raise RuntimeError('canonical lock inode changed at release')
    # No flock probe: a second acquisition would change the experiment boundary.
    text=read_text('/proc/locks',1024*1024)
    for row in text.splitlines():
        if 'FLOCK' not in row:continue
        match=re.search(r'\b([0-9a-fA-F]+):([0-9a-fA-F]+):([0-9]+)\b',row)
        if match is None:raise RuntimeError('unparseable kernel FLOCK evidence')
        key=(int(match[1],16),int(match[2],16),int(match[3]))
        if key==(os.major(identity['device']),os.minor(identity['device']),identity['inode']):
            raise RuntimeError('canonical inode still has a FLOCK owner/waiter')
    return dict(identity,lock_released_same_inode=True,
        source='lstat same inode + no matching FLOCK in proc/locks; no acquisition probe')


def validate_cleanup(cleanup,ticket,pid):
    if type(cleanup) is not dict or set(cleanup)!={'owner_closed','readback'} or cleanup['owner_closed'] is not True:
        raise ValueError('explicit closed owner readback required')
    value=cleanup['readback']
    if type(value) is not dict or value.get('last_lock_proof')!=ticket:
        raise ValueError('same acquired lock ticket required at cleanup')
    resources=value.get('resources',{})
    for key,wanted in dict(pid=pid,held=False,safety_unresolved=False,lease_retained=False,
                           runner_retained=False,root_buffers_retained=0).items():
        if type(resources.get(key)) is not type(wanted) or resources[key]!=wanted:
            raise ValueError('owner resources not closed: '+key)
    terminal=value.get('terminal',{})
    if (type(terminal) is not dict or type(terminal.get('build_id')) is not int
            or terminal['build_id']!=0x2026D075 or type(terminal.get('phase')) is not int
            or terminal['phase']!=1 or type(terminal.get('error')) is not int or terminal['error']!=0
            or terminal.get('recovery',{}).get('confirmed') is not True):
        raise ValueError('fresh cleanup recovery/IDLE readback required')
    return True
