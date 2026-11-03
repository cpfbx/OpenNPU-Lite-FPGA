---
name: pynq-dma-validation
description: Inspect supplied PYNQ Overlay metadata and diagnose or plan AXI DMA transport checks, including coherency, transfer limits, receive ordering and bounded failure handling. Use for Overlay bring-up or byte-transport regressions, not accelerator arithmetic or unrequested board execution.
---

# PYNQ Overlay and DMA validation

First determine whether the user wants static inspection, diagnosis, a test
plan, or explicitly authorized execution. Do not turn one into another.

## Static inspection on a PC

1. Locate the supplied same-stem BIT/HWH pair without renaming originals. Run
   `python -I -B scripts/inspect_overlay_strict.py path/to/design.bit` relative to this
   Skill directory. For other IP expectations supply repeated `--require-type`
   exact type names. Matching uses MODTYPE or the parsed VLNV IP-name field,
   never an instance-name substring. Conflicting declared types fail the check.
2. Read the reported modules, matched fields and SHA values. The helper
   does not parse the BIT payload: same stems and hashes alone cannot prove the
   pair came from one build, targets the right device, or works on a board.
   Compare a separately trusted build manifest when available.
3. Keep status as static-inspection-only. Missing/malformed HWH or missing
   expected types is a failure of this check, not evidence to rebuild or
   program a device automatically.

The byte-preserved `scripts/inspect_overlay.py` is a historical adapter only.
Its fragment search includes instance names: a module named `axi_dma_fake` can
pass its `axi_dma` check without being a DMA IP. Do not use that result to
establish type presence. Use the new strict entry for that narrow metadata task;
even it does not prove that declarations describe the BIT's actual hardware.

## Transport diagnosis or preparation

Read [the transport contract](references/transport_contract.md) before preparing
a physical test. Discover the current DMA instances, channel capabilities,
stream topology, register contract and runtime; never copy a previous board's
addresses. Check buffer allocation, capacity, alignment and cache coherency.

For a supported simple streaming design, arrange the receive side before any
producer can emit. Exact start order depends on free-running versus controlled
IP and the driver; do not treat a GEMM START sequence as universal.

Use deterministic nonzero byte patterns and element/byte-level comparison,
with deadlines and saved first-failure status. A hash can identify saved bytes,
but is not a substitute for the runtime byte comparison. Select workload and
bandwidth limits from the project's contract, not a universal 1000-case rule.

On timeout stop new work and preserve status. No automatic retry/reset, lock
deletion, channel restart or reboot. An approved recovery has its own result;
it does not erase the initial failure. If state/release is unknown, report that.

## Return

Report artifact identity, requested operation, actual checks and exit codes,
runtime checks not performed, unresolved contract fields and the next safe
action. Separate static metadata, software mocks and physical transport results.
Transport success never establishes accelerator numerical correctness.

Origins, old-script identity and tested limits are in the bundle provenance;
this Skill itself is not a permission system or authenticated attestation.
