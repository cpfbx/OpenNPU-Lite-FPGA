# Transport contract and failure routing

Before board work, identify:

- board/device, PYNQ image/runtime, tool version and independently trusted build;
- DMA simple/SG mode, enabled channels, DRE/alignment, address width and maximum
  transfer length; stream widths and TLAST/packet boundaries;
- exact IP instance/register names, start/done/error semantics and clock/reset;
- input/output byte count, receive capacity and valid output length;
- buffer ownership, physically contiguous allocation, flush before device reads
  and invalidate before CPU reads when not proven coherent;
- local exclusive ownership, operator, deadlines and approved stop/recovery.

Use only supported interfaces. `inspect_overlay_strict.py` checks exact declared
MODTYPE or VLNV IP-name identities, reports the matched fields, and rejects type
conflicts. It does not verify all the above settings or authenticate BIT/HWH
compatibility. Address ranges/capabilities still require independent inspection.
The old `inspect_overlay.py` fragment search is preserved for historical
compatibility only and can be fooled by instance names. It is not the selected
type-check entry in this revision.

The strict helper accepts UTF-8 HWH XML (including a UTF-8 BOM), no DTD/entity
declarations, at most 16 MiB HWH and 128 MiB BIT input. It rejects empty,
terminal symlink/reparse or nonregular files. Its exact-type check is case
sensitive; it does not silently infer a missing or inconsistent declaration.
It reads the BIT only to hash its bytes and performs no payload parsing. A
fabricated matching HWH remains a possible false representation of hardware.

The positional input must have a `.bit` suffix (case-insensitive); its companion
is the same stem with lowercase `.hwh`. Passing `.hwh` as the BIT input is an
input error, not a way to inspect an HWH alone. Input/argument errors print JSON
to stderr and exit 2; missing declared types/conflicts print a result to stdout
and exit 1; successful metadata checks exit 0. `--help` is normal text, exit 0.
Terminal-file checks do not prohibit aliases in parent directories and are not
an authentication mechanism or a sandbox against concurrent filesystem changes.

| Observation | First read-only checks | Do not infer |
|---|---|---|
| Missing same-stem HWH | Correct artifact location and trusted manifest | Rename an unrelated HWH and call it compatible |
| Receive never completes | Expected length, TLAST, channel status, producer start | A timeout proves broken arithmetic |
| Stale bytes | Buffer ownership, flush/invalidate, lengths and last writer | Automatically retry until bytes change |
| One payload exact | Full byte comparison and actual status | Sustained bandwidth, GEMM or long-run acceptance |
| Recovery exact | Original failure plus recovery-specific evidence | Initial failure did not occur |

Report decimal MB/s and MiB/s distinctly, one-way payload versus aggregate
traffic, allocation/pattern generation included or excluded, warmup, sample
count and completed bytes. A deadline around a blocking operation is not
effective if only checked after it returns; an authorized executor must show
where bounded waiting actually happens. No board runner is bundled here.
