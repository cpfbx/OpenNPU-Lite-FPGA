"""Chain real stop handlers inside the UNCHANGED supervisor, before acquisition.

No timeout kill, force release, retry or escape from its unresolved-resource hold.
This wrapper is internal and is not a board launcher or evidence authenticator.
"""
import signal
import threading

from batch_policy import BatchStop
from kws_device_supervision_candidate import _supervise


def supervised(factory,operation,publish,external_stopped,*,enabled=False):
    if enabled is not True:raise ValueError('supervision bridge default-off')
    if threading.current_thread() is not threading.main_thread():raise RuntimeError('main thread required')
    if not all(callable(x) for x in (operation,publish,external_stopped)):
        raise ValueError('trusted supervision callbacks required')
    numbers=[getattr(signal,n) for n in ('SIGINT','SIGTERM','SIGHUP') if hasattr(signal,n)]
    # Capture BEFORE the frozen supervisor changes them; retry every restore on safe exit.
    previous={number:signal.getsignal(number) for number in numbers}
    requested=[];handler_errors=[];restore_errors=[];primary=None;result=None

    def stopped():
        return bool(requested or handler_errors) or external_stopped() is not False

    def wrapped_operation():
        nonlocal primary
        try:
            for number in numbers:
                inherited=signal.getsignal(number)
                def chain(signum,frame,original=inherited):
                    if signum not in requested:requested.append(signum)
                    # Record in BOTH the operation stop source and original supervisor.
                    try:
                        if callable(original):original(signum,frame)
                    except BaseException as error:handler_errors.append(type(error).__name__)
                signal.signal(number,chain)
            if stopped():raise BatchStop('stop before resource factory')
            result=operation(stopped)  # Resource factory/start must happen INSIDE this call.
            if stopped():raise BatchStop('stop after operation cleanup; no successful block')
            return result
        except BaseException as error:
            primary=error;raise

    try:result=_supervise(factory,wrapped_operation,publish,enabled=True)
    except BaseException as error:
        if primary is None:primary=error
    finally:
        # Unresolved original hold NEVER reaches here. Do not turn handler cleanup
        # into a resource close or release; only restore genuinely exiting process.
        for number,handler in previous.items():
            try:signal.signal(number,handler)
            except BaseException as error:restore_errors.append(dict(signal=int(number),error_type=type(error).__name__))
    report=dict(stop_signals=[int(n) for n in requested],handler_errors=handler_errors,
        handler_restore_errors=restore_errors,original_supervisor_unchanged=True)
    if primary is not None:
        primary.supervision_bridge_observation=report
        raise primary
    if restore_errors or handler_errors:raise_error=RuntimeError('signal handler lifecycle failed')
    elif requested:raise_error=BatchStop('stop observed; no successful supervised block')
    else:return dict(result=result,signals=report)
    raise_error.supervision_bridge_observation=report
    raise raise_error
