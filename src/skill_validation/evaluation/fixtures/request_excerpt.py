# Synthetic source excerpt for reading only; timer units are seconds.
def request(a, b):
    started = monotonic()
    output = run_chain(a, b)
    elapsed = monotonic() - started
    expected = independent_reference(a, b)
    verify(output, expected)
    return output, elapsed
