"""Emit baseline/new entry-failure comparison on fake OS, never a real FD/lock."""
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parent
for path in reversed([ROOT/'frozen_source',ROOT]):sys.path.insert(0,str(path))
import batch_owner
from batch_policy import BatchPolicy
from kws_device_supervision_candidate import _needs_retention
from owner_entry_candidate import EntrySafeBatchOwner
from entry_fixture import FakeCanonicalEnvironment


def main():
    results=[]
    scenarios=[('pre_factory_missing',{'precheck':True}),('busy_close_ok',{'busy':True}),
        ('post_acquire_drift_close_ok',{'drift':True}),
        ('post_acquire_drift_close_error',{'drift':True,'close_error':True})]
    for name,options in scenarios:
        for cls in (batch_owner.BatchOwner,EntrySafeBatchOwner):
            owner=cls(BatchPolicy('smoke8',enabled=True),lambda:False,enabled=True)
            env=FakeCanonicalEnvironment(**options)
            with env.install():
                try:
                    owner.start(object,Path('NOT_LOADED.bit'),env.factory,lambda:None)
                except (ValueError,OSError,RuntimeError) as error:
                    error_type=type(error).__name__
                else:raise AssertionError('expected synthetic acquisition error')
                held=owner._held
                retention=_needs_retention(owner.supervision_status)
                lease_retained=owner._lease is not None
                try:owner.close()
                except RuntimeError:close_outcome='refused_quarantine'
                else:close_outcome='returned'
                results.append({'scenario':name,'owner_class':cls.__name__,'error_type':error_type,
                    'synthetic_fd_live':env.fd_live,'synthetic_exclusive_held':env.exclusive_held,
                    'factory_calls':env.factory_calls,'helper_close_calls':env.close_calls,
                    'owner_held':held,'owner_lease_retained':lease_retained,
                    'supervisor_retention_condition':retention,'owner_close':close_outcome})
            # Discard synthetic process-local test references only. No real fd.
            if owner in batch_owner._RETAINED:batch_owner._RETAINED.remove(owner)
    for row in results:
        if row['owner_class']=='EntrySafeBatchOwner':
            attempted=row['scenario']!='pre_factory_missing'
            assert row['owner_held'] is attempted
            assert row['supervisor_retention_condition'] is attempted
            assert row['owner_close']==('refused_quarantine' if attempted else 'returned')
    double=[r for r in results if r['scenario']=='post_acquire_drift_close_error']
    assert double[0]['synthetic_fd_live'] and not double[0]['owner_held']
    assert double[1]['synthetic_fd_live'] and double[1]['owner_held']
    print(json.dumps({'scope':'actual frozen helper + observer/owner derivatives over synthetic OS/fcntl',
        'real_fd_or_flock_tested':False,'real_supervisor_hold_loop_executed':False,
        'normal_close_can_succeed_but_caller_has_no_release_proof':True,
        'no_automatic_close_retry_or_release':True,'board_access':False,'promotion':False,
        'results':results},ensure_ascii=False))


if __name__=='__main__':main()
