"""Actual wait plus read-only process-group presence query. Never timeout-kill."""
import os
import subprocess
import time


def observe_exit(child,guardian,stopped,request_stop,*,group_query=None):
    injected=group_query is not None
    if group_query is None:
        if os.name!='posix':raise RuntimeError('real process-group proof requires Linux; Windows fixture must label injection')
        from os_evidence import process_group_absent
        group_query=process_group_absent
    record=dict(actual_exit_code=None,process_group_absent=None,
        group_query_injected=injected,actual_wait_observed=False,automatic_kill=False,
        stop_seen=False,wait_intervals=0,source='Popen.wait then read-only process-group query')
    primary=None;stop_attempted=False
    try:
        while True:
            try:requested=stopped() is not False
            except BaseException as error:
                if primary is None:primary=error
                requested=True
            if requested:
                record['stop_seen']=True
                if not stop_attempted:
                    stop_attempted=True
                    try:request_stop()
                    except BaseException as error:
                        if primary is None:primary=error
            try:
                value=child.wait(timeout=1.)
                break
            except subprocess.TimeoutExpired:
                record['wait_intervals']+=1
        if type(value) is not int:raise ValueError('actual wait must return non-bool integer')
        record['actual_exit_code']=value;record['actual_wait_observed']=True
        record['process_group_absent']=group_query(child.pid)
        if record['process_group_absent'] is not True:
            raise RuntimeError('child process group remains or is unknown')
        if primary is not None:raise primary  # Actual wait/query facts recorded FIRST.
        return record
    except BaseException as error:
        guardian._hold(error)
        # Preserve partially observed facts without declaring a successful exit.
        error.comparison_exit_observation=record
        raise
