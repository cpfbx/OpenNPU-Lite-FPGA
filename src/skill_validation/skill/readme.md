# Skill selection and reuse

Competition packaging entry: applicable task, use, failure conditions, observed
origins, and verification limits are specified for each Skill below. The root
MIT license is included; this does not authorize publication of other project
assets. These three workflows can be read manually or offered to a compatible
agent as complete Skill directories. No automatic installation is provided.

| Skill | Input and use | Output | Failure / limitation |
|---|---|---|---|
| [pynq-dma-validation](pynq-dma-validation/SKILL.md) | A supplied Overlay pair or transport troubleshooting question; choose static inspection or prepare a project-specific transport plan | Metadata inventory and bounded diagnosis / test plan | Missing contract or runtime evidence stays unresolved; no automatic board access |
| [pynq-gemm-validation](pynq-gemm-validation/SKILL.md) | A declared arithmetic/layout contract and original operands/output or historical evidence | Exact small raw-matrix comparison, or scoped evidence findings | Not fused/quantized output, arbitrary schema support, board authentication or a performance win |
| [engineering-evidence-review](engineering-evidence-review/SKILL.md) | A technical claim plus source and raw records | Claim-by-claim evidence review; optional file/line link checks | Missing original or noncomparable measurements cannot become verified by consensus |

Revision 02 selects `pynq-dma-validation/scripts/inspect_overlay_strict.py` for
declared IP type checks. The old fragment inspector remains historical only;
its name-based false positive is reproduced in tests. Two unchanged GEMM JSON
adapters are likewise history-only and may accept invalid declarations; never
offer them as strict generic acceptance gates for an unfamiliar schema.

## Reuse ladder

1. PC-only: supplied examples and raw artifacts can be checked without PYNQ,
   NumPy, Vivado, an API key, a network connection or a board.
2. New topic: set its instance names, modes, arithmetic, register contract,
   evidence fields and measurement boundaries explicitly. Missing mappings are
   an adaptation task, not permission to fabricate passing evidence.
3. New PYNQ board: verify device/tool/runtime compatibility, buffer coherency,
   transfer limits, clocks and the local operator's authorization. PC-only
   inspection is not proof of functioning hardware on that board.

The author has performed only the offline checks recorded in the external test
report. No unfamiliar-user or second-board success is claimed. Original project
experience motivates the procedures; synthetic fixtures test helpers, not DMA.

## Shared execution boundary

Read-only analysis is the default for these review tasks. A request for a plan
does not authorize loading an Overlay, starting a benchmark, resetting DMA,
altering a kernel, removing a lock, installing software or publishing results.
Use an explicitly authorized local operator for any physical test. In the
originating OpenNPU project that operator is bx; this is not a universal user
name imposed on other teams. Keep their existing ownership/lock mechanism.

Do not automatically repeat old board experiments to restate a historical
result. Verify its original identity and scope; new performance claims need a
separately authorized, controlled experiment.
