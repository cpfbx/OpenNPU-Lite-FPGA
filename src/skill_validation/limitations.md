# Candidate limitations

- Current revision has author checks only. External parent reviews and raw Linux
  logs do not approve revision 03. Linux v2 had one stale test-assertion failure;
  independent Linux execution of v3 is still pending.
  No fresh-context unfamiliar-user trial, behavioral A/B, or second-board result.
- This is not a replacement for the original Skills, frozen protocols, project
  oracle, validator gates or release artifacts. No runtime/default changed.
- The old HWH fragment check can be spoofed by instance names. The new strict
  declared-type checker rejects this pattern but still cannot authenticate HWH
  declarations or establish BIT contents, address mapping or hardware operation.
- The two historical JSON adapters are unchanged and not hardened for arbitrary
  adversarial JSON. Their limitations are explicit in the GEMM reference.
- The new mathematical reference is intentionally tiny and slow; its PC result
  checks supplied bytes only. No unmeasured ARM performance or board result.
- Evidence-link checks cannot decide relevance, causality, independence, timing
  correctness or truthful prose. A false assertion with valid file links can
  pass link verification. Semantic review remains a human/agent task.
- Source hashes establish byte identity, not historical authorship, copyright
  clearance, authenticated signatures or the truth of self-consistent records.
- Containment and file-size checks are not an OS sandbox against concurrent
  hostile filesystem mutation. Run on a stable local snapshot.
- The optional link format is a new helper interface, not a change to existing
  project evidence schemas. No automatic unit reinterpretation or gate change.
- Revision 02 fixes LF-only line-number semantics and rejects internal aliases
  as well as escapes. Input review JSON must also be regular and not a symlink
  or reparse-point file.
  These are helper interface refinements, not historical evidence reinterpretation.
- Membership enumeration rejects links, Windows reparse points and special
  nodes without opening them, and rejects unlisted directories. OS-dependent
  tests may be skipped; unit attribute mocks are not actual junction/FIFO tests.
- Revision 03 synchronizes the escaping-link test's rejection diagnostic. An
  additional portable simulation executes that assertion without link privileges;
  it does not replace the real filesystem tests or turn skips into passes.
- Strict inspection requires a .bit suffix (case-insensitive) and a same-stem
  lowercase .hwh companion. CLI input/argument failures produce JSON on stderr,
  exit 2; --help intentionally retains normal help text and exit 0. Parent path
  aliases are not rejected by this helper's terminal-file checks. Use a stable,
  trusted local snapshot, not an adversarial or concurrently changing tree.
- Uppercase canonical `README.md`, `SKILL.md`, `LICENSE`, `MANIFEST.json` are
  intentionally retained for ecosystem/guide examples. Other new paths use
  lowercase ASCII. Final competition naming treatment needs explicit review;
  do not silently rename frozen members or claim every name is lowercase.
- Public release, provenance/licensing approval and final submission remain bx
  decisions. No third-party Skill implementation is bundled in this candidate.
