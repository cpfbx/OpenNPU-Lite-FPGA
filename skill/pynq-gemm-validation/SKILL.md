---
name: pynq-gemm-validation
description: Review tiled INT8 GEMM correctness and measurement evidence on PYNQ, or compare a small supplied row-major INT8/INT32 matrix result offline. Use after the arithmetic and layout contract is known; do not substitute evidence checks for raw-output verification or launch hardware without authorization.
---

# GEMM correctness and evidence review

1. Identify the exact requested result: operand/output check, historical JSON
   check, or preparation of a new experiment. Record execution platform, model
   when relevant, BIT/host identity, arithmetic, M/N/K, layouts and padding.
2. Establish transport separately. Freeze signedness, reduction, overflow,
   bias/scale/saturation and output order before choosing an oracle. Use an
   independently implemented reference, not the packer being tested.
3. For a small plain GEMM, use
   `python -I -B scripts/compare_int8_gemm.py --a a.bin --b b.bin --output c.bin --shape M,N,K`.
   Read [arithmetic and adapters](references/arithmetic_and_adapters.md) first.
   The helper is a bounded PC offline example, not the frozen board oracle or a
   fast 512-cubed reference. It never loads hardware.
4. For tiled board results, verify returned tiles before placement and the
   reconstructed matrix after placement, with signed extrema, tails, multi-K,
   deterministic inputs and first-failure retention. State how many outputs
   were runtime-checked versus saved and independently replayed. Repeated bank
   operands do not become distinct samples.
5. Match counters to the actual mode/version. Useful MACs are M*N*K; transport
   padding, physical bytes and jobs are separate. Sequential phases may add;
   overlapped phase counters require their documented conservation equation.
6. Compare performance only within matching experiment contracts. Separate PL,
   DMA+PL, complete request, oracle, startup and file I/O. Source-anchor timer
   start/end before subtracting stages. Nested timers are not disjoint buckets.
   Cold start, batch throughput and response latency are different quantities.
7. Historical `validate_gemm_evidence.py` and `validate_resilience_evidence.py`
   are unchanged OpenNPU v1 adapters, not generic strict JSON/numerical proof.
   Read their limitations before use. Do not rewrite new evidence to impersonate
   their schemas, or treat an asserted exact flag as raw-output verification.

Return findings with original hashes, actual checked counts, reference and
overflow semantics, timer boundaries, failures, unrun checks and acceptance
scope. Correctness is necessary, not sufficient, for a performance claim.
No automatic retry, reset, gate adjustment, promotion or physical execution.
