"""Default-off PC equivalence candidate. Not wired into any board runner.

Keep the frozen record builder, validation, padding, job IDs and return types.
Only avoid materializing header+payload bytes separately for every record.
"""
import chain_protocol as frozen


def pack_chain_flat(transactions, first_job_id=1, *, enabled=False):
    if enabled is not True:
        raise ValueError('flat pack candidate default-off')
    jobs = list(transactions)
    if not jobs:
        raise ValueError('a chain must contain at least one transaction')
    records = [
        frozen.build_chain_record(
            transaction,
            (first_job_id + index) & 0xFFFF_FFFF,
            chain_last=index == len(jobs) - 1,
        )
        for index, transaction in enumerate(jobs)
    ]
    return b''.join(part for record in records for part in (record.header_bytes, record.payload)), records
