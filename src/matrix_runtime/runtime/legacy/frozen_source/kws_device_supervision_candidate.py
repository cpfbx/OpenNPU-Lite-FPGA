"""Exit-safety wrapper, NOT a launcher and NOT an OS security boundary.

Install before factory acquisition. No subprocess timeout/kill, retry, recovery,
free, lock replacement, or exit from quarantine. The trusted operation owns its
normal bounded call and cleanup. Pending SIGINT/SIGTERM/SIGHUP are recorded;
they do not asynchronously unwind a cache/MMIO/native/cleanup critical section.
SIGKILL, interpreter crashes, machine shutdown and power loss are NOT covered.
"""
import os
import signal
import threading
import time


def _needs_retention(status):
    return bool(status['held'] or status['safety_unresolved'] or
        status['lease_retained'] or status['runner_retained'] or status['root_buffers_retained'])


def _supervise(factory, operation, publish, *, enabled=False):
    """Internal API; dependencies trusted. No device resources returned.

    On unresolved cleanup, publish one attention record and stay in this process
    with its strong factory/resource/lease references. If publishing or waiting
    fails, still retain. There is deliberately no force-release or resume API.
    A parent must NOT turn an observation deadline into killing this worker.
    """
    if enabled is not True:
        raise ValueError('exit-safety supervision is default-off')
    if threading.current_thread() is not threading.main_thread():
        raise RuntimeError('supervision must own the main thread signal handlers')
    if os.getpid() != factory.supervision_status['pid']:
        raise RuntimeError('supervision/factory process mismatch')
    if _needs_retention(factory.supervision_status):
        raise RuntimeError('install supervision BEFORE resource acquisition')
    previous, requested = {}, []
    def record_stop(number, frame):
        if number not in requested:
            requested.append(number)
    try:
        for name in ('SIGINT', 'SIGTERM', 'SIGHUP'):
            number = getattr(signal, name, None)
            if number is not None:
                previous[number] = signal.signal(number, record_stop)
        primary = None
        try:
            result = operation()
        except BaseException as error:
            primary = error
        status = factory.supervision_status
        if _needs_retention(status):
            record = dict(status, outcome='attention-retained-process',
                stop_signals=tuple(requested), actual_exit=None,
                primary_error_type=None if primary is None else type(primary).__name__)
            # Log failure never turns into permission to exit/free.
            try:
                publish(record)
            except BaseException:
                pass
            while True:
                try:
                    time.sleep(1.)
                except BaseException:
                    continue
        if primary is not None:
            raise primary
        if requested:
            raise RuntimeError('stop requested; operation completed safe cleanup; no successful run')
        return result
    finally:
        # The hold loop never reaches here. Restore only on a genuinely safe
        # exit, including failure before any resource acquisition.
        for number, handler in previous.items():
            signal.signal(number, handler)


def main():
    print('Unreleased supervision wrapper. No board launcher; actual child-exit capture pending.')
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
