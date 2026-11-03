# Synthetic source excerpt for reading only; helper bodies are not supplied.
def owned_submit(jobs):
    assert_owner_healthy()
    tx = pack_chain(jobs)
    started = monotonic()
    rx_channel.transfer(rx)
    tx_channel.transfer(tx)
    wait_bounded()
    total = monotonic() - started
    inspect_counters()
    assert_owner_healthy()
    return total
