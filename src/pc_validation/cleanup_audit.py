"""Supplemental, offline-only audit of the retained shared12 cleanup record.

Adds no hardware observations and never imports the delivered board runtime.
The frozen runtime validator and original archive remain unchanged.
"""
import argparse
import hashlib
import json
import tarfile
from pathlib import Path, PurePosixPath

ARCHIVE_SHA = '7786d5eee69b1cd17c1296beee522d324ca5d7fff9cc3e6e1a3aea39010651b7'
FRESH = dict(build_id=0x2026D075, capabilities=528126,
             counter_contract_version=1, expected_counter_contract_version=1,
             error=0, phase='post-soft-reset-before-start')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def strict_json(raw):
    def pairs(items):
        out = {}
        for key, value in items:
            require(key not in out, 'duplicate JSON key')
            out[key] = value
        return out
    def invalid(_):
        raise ValueError('nonfinite JSON')
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def exact(actual, expected, message):
    require(type(actual) is type(expected) and encoded(actual) == encoded(expected), message)


def validate(outer, terminal):
    require(type(outer) is dict and type(terminal) is dict, 'receipt dictionaries')
    exact(outer.get('child_terminal'), terminal, 'outer/worker terminal disagreement')
    for key in ('operation_success', 'cleanup_verified', 'actual_wait_observed',
                'process_group_absent', 'lock_released_same_inode'):
        exact(outer.get(key), True, 'outer normal lifecycle: ' + key)
    exact(outer.get('actual_exit_code'), 0, 'actual child exit')
    exact(outer.get('group_query_injected'), False, 'real group query required')
    exact(terminal.get('operation_success'), True, 'worker normal success')
    pid = terminal.get('pid')
    require(type(pid) is int and pid > 1, 'exact worker PID')
    session = terminal['session']
    exact(session['owner_closed'], True, 'owner close required')
    exact(session['close_attempts'], 1, 'single normal close')
    cleanup = session['cleanup_readback']
    resources = cleanup['resources']
    expected_resources = dict(pid=pid, held=False, safety_unresolved=False,
                              lease_retained=False, runner_retained=False,
                              root_buffers_retained=0)
    for key, value in expected_resources.items():
        exact(resources.get(key), value, 'closed resource: ' + key)
    exact(session['resources'], resources, 'session/cleanup resources disagree')
    ticket = terminal['ticket']
    require(type(ticket) is dict, 'lock ticket dictionary')
    exact(ticket.get('pid'), pid, 'ticket worker PID')
    exact(session['lease_ticket'], ticket, 'session/worker ticket disagreement')
    exact(cleanup['last_lock_proof'], ticket, 'cleanup/worker ticket disagreement')
    original_terminal = cleanup['terminal']
    for key, value in dict(build_id=FRESH['build_id'], phase=1, error=0).items():
        exact(original_terminal.get(key), value, 'terminal cleanup identity: ' + key)
    recovery = original_terminal['recovery']
    exact(recovery.get('confirmed'), True, 'confirmed recovery')
    fresh = recovery['fresh_accelerator_identity']
    require(type(fresh) is dict and set(fresh) == set(FRESH), 'exact six fresh identity fields')
    for key, value in FRESH.items():
        exact(fresh[key], value, 'fresh identity: ' + key)
    # Runtime MODE11 version 2 is a different phase; it is not substituted here.
    return dict(operation_success=True, fresh_identity=fresh,
                scope='supplemental retained shared12 post-reset identity audit',
                hardware_access=False, live_lock_access=False,
                inference_reexecuted=False, source_origin_authenticated=False,
                frozen_runtime_modified=False, promotion=False)


def read_archive(path):
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == ARCHIVE_SHA, 'external original archive pin')
    records = {}
    seen = set()
    total = 0
    wanted = {'work/evidence/outer_receipt.json', 'work/evidence/worker/terminal.json'}
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            name = member.name
            pp = PurePosixPath(name)
            require(name and '\\' not in name and ':' not in name and not pp.is_absolute()
                    and '..' not in pp.parts and pp.as_posix() == name, 'plain archive member path')
            require(name not in seen and member.isfile(), 'unique regular archive members')
            seen.add(name)
            total += member.size
            require(total <= 64 * 1024 * 1024 and member.size <= 8 * 1024 * 1024,
                    'bounded archive sizes')
            if name in wanted:
                require(member.size <= 2 * 1024 * 1024, 'bounded receipt')
                records[name] = strict_json(archive.extractfile(member).read())
    require(set(records) == wanted, 'both retained receipts required')
    return records['work/evidence/outer_receipt.json'], records['work/evidence/worker/terminal.json']


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--archive', type=Path, required=True)
    args = p.parse_args()
    print(json.dumps(validate(*read_archive(args.archive)), sort_keys=True))
