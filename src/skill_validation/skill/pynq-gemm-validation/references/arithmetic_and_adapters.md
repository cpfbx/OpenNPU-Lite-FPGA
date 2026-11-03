# Arithmetic contract and adapters

## Small independent PC comparison

`compare_int8_gemm.py` accepts A[M,K] and B[K,N] as signed INT8 raw row-major
bytes and C[M,N] as little-endian signed INT32, with no header or padding.
Shapes on the CLI are M,N,K. Python integers accumulate exact mathematical
sums; all possible INT8 operands must fit INT32 under the conservative bound
K*16384 <= 2147483647. Otherwise this example rejects the contract rather than
choosing wraparound or saturation. There is no bias, requantization or tolerance.

Maximum work is 2,000,000 useful MACs. The helper checks dimensions and budgets
before loading data, and exact byte lengths before computation. This deliberately
does not support production 512-cubed replay. Use the project's frozen approved
oracle for actual experiments. A NumPy INT32 matmul may wrap on overflow and is
not a mathematical oracle unless bounds or the intended wrap semantics match.

All positions are compared; the report includes count, mismatch count and the
first mismatch, but never dumps full private input data. SHA values identify the
actual byte snapshots read. Exit 0 means exact bytes under this narrow arithmetic
contract; 1 means mismatch; 2 means invalid/unsupported input. CLI argument
errors, including shape syntax/budget and missing/unknown options, print one
JSON error on stderr; `--help` remains a normal successful text help operation.
None proves who
produced C, which board ran, or whether a claimed timer is accurate.

## Historical unchanged JSON adapters

The two copied `validate_*_evidence.py` scripts accept only their original
`opennpu.board_gemm.v1`, `opennpu.board_gemm_soak.v1` and
`opennpu.board_gemm_recovery.v1` contracts. Recovery expects OpenNPU error 0x07;
this is not universal hardware behavior. Their self-tests are retained.

Known limits, deliberately not silently changed in this Skill candidate:

- They inspect JSON declarations and selected equalities, not raw tensor files.
- They do not authenticate board identity, origin, binary correspondence or
  independently observe OS processes / hardware state.
- They use ordinary JSON loading and do not comprehensively reject duplicate
  keys, nonfinite values or bool-as-int values across every field; malformed
  nested objects may raise errors outside a normal rejection report.
- In particular, a boolean completed count and an infinite DMA duration may be
  accepted while inconsistent cycle fields go unchallenged. A top-level `[]`
  causes an uncaught AttributeError/Traceback and exit 1, not a well-formed
  invalid-input result. Tests preserve these observations, not endorse them.
- Passing selected MAC/shape checks does not validate every timing/counter field
  or prove statistical superiority, physical recovery or absence of tampering.

Therefore run them only as legacy compatibility checks on separately trusted,
contract-appropriate inputs. Report their scoped result plus uncovered checks.
Do not call them hardened general-purpose input validators. Changing their
project acceptance contract is a separate reviewed decision, not part of this
authoring task. Unsupported schemas stay unsupported; supply a separate adapter
only after its semantics and authority have been reviewed.
