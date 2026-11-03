# Claim-specific checks

Read only the applicable section; do not impose a full performance audit on an
unrelated task.

## Timing and correctness

- Same experiment and symmetric boundary? If not, historical values may be
  listed separately but cannot become a same-session speedup.
- Timers nested, overlapping or disjoint? Check code and timestamp definitions.
- Oracle before/inside/after timer? Initialization, allocation, checks and I/O?
- Is alleged repeated work present in the current source? One loop iteration
  need not be one DMA submission. Preserve work that enforces correctness.
- After a proposed deletion, is equivalent output and verification established?
- Mismatches, failures, slow points, skips and selected samples all retained?

## Input energy

- Supply port, meter, external paths and peripherals known? Accuracy and
  resolution are distinct; PC software integration is not calibrated hardware.
- Equal useful completed work and explicitly declared service boundary? Include
  inseparable checks/buffers when that is the contract; do not silently remove.
- Use Wh_end - Wh_start in consistent units or justified P-time integration.
  Average input power times a different historical kernel interval is not a
  measured phase energy. Idle subtraction requires a separate justified baseline.
- Longer can still use less energy when sufficiently lower power compensates;
  no blanket rule that losing latency mathematically forces an energy loss.
- Preregister window selection, synchronization limitations and uncertainty;
  power envelope diagnostics must not be relabeled precise per-request energy.

## Model and platform

Bind model architecture/weights, preprocessing revision and arithmetic, input
SHA or dataset split, reference engine and execution platform. PC intermediate
agreement does not establish FPGA inference or application accuracy. Intermediate
value count is not MAC count; repeated clips are not independent samples.

Distinguish numerical agreement, classification correctness, rejection quality,
action safety and continuous-service acceptance. One low-score wrong command
rejected is one case, not universal zero false actions or deployability.

## Independence and completion

An agent statement is not a new observation. Trace original files actually read,
tests actually run and shared upstream summaries. Historical verified bytes can
support a historical statement without another board run. New software behavior
requires relevant fresh checks; unchanged hashes alone do not test new behavior.

A manifest is an integrity inventory, not a signature or proof of authenticity.
Author and reviewer roles are recorded separately; neither replaces the user's
approval for a release or change of operating scope.
