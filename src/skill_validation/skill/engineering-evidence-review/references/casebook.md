# Origins: six project correction patterns

This is a teaching summary of the originating project's review, not a fresh
measurement or a portable copy of its private evidence. The portable fixtures
use different, synthetic values. Verify original records before quoting project
numbers in an external report.

1. External INT64 oracle was blamed for complete-request latency even though
   source placed it after the request timer. Lesson: locate actual timer edges.
2. Jobs times K blocks were mistaken for DMA launch count although the driver
   already packed and submitted a full chain. An owned-minus-chain interval was
   attributed entirely to one function without timing its other checks.
3. Host profiles from the 483-call run were subtracted from a different run's
   FPGA latency and compared with ARM to invent an unmeasured win.
4. Whole-envelope mean input power was multiplied by a historical DMA interval
   to split active/wait energy without independently establishing either power.
5. New DS-CNN PC intermediate-value checks were combined with the older
   three-layer model's board classification result as if one model/platform.
6. Historical absolute latency/energy values were proposed as new-run winning
   thresholds; several agents repeating the same premise amplified confidence
   without obtaining independent primary evidence.

For each correction, retain the original proposal, source/record that tests it,
actual correction and remaining unknowns. Do not turn the lesson into a blanket
ban on modeling, a claim that all repeated advice is wrong, or an excuse to
automatically run more hardware experiments.
