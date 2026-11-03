# Public derivative notice — 2026-11-02

This copy replaces collaboration excerpts and updates README/provenance documentation.
All Python helpers, tests, Skill instructions and fixtures are byte-identical to the source candidate.
The manifest identifies this new derivative; historical review approval belongs to the original bytes.

# Origins and contribution record

## Revision 03 review lineage

Derived from v2 ZIP SHA256
`8abddf3c6637de3eac0e16beaee07b5e357948906d9c3efff665b28226027ef9`.
The user supplied three local v2 review artifacts from one reviewer, and a
separate external Linux/gVisor log archive SHA256
`ae3c30c03f85efd568caebec1bf3ca1d8df78d36ecb2c30d4fc7c02bea44a6c1`.
The author verified their parent identity and read their outputs without
executing supplied counterexample scripts. These are review inputs, not new
execution authority. Original files and v1/v2 artifacts remain unchanged.

The external Python 3.11.2 logs show 82 v2 tests, 81 passing, one failed assertion,
zero skips and exit 1. The escaping link was correctly rejected before the
older diagnostic expected by the assertion. This author reproduced that test
diagnostic using an explicitly simulated link operation, and reproduced the
HWH-only false success and non-JSON argument error on Windows. Revision 03
repairs those three boundaries and adds narrow regressions. Three historical
scripts retain their original byte hashes.

Independent v3 review and Linux v3 execution remain pending. No physical second
computer, board run, new agent-use evaluation or behavioral benefit is inferred
from external Linux/gVisor logs or these author checks. The revision 02 notes
below describe what was available at that earlier iteration, not the current
availability of Linux logs.

## Revision 02 review lineage

This revision derives from the sealed parent ZIP with SHA
22f0decf672583adc0678c62cc5ef3bf00517037cb2ec5d3603188d9a1166fb5.
The user supplied four local review files from ONE reviewer and separately a
second person's Linux report as chat text. The first records prior exposure to
the author's report. The second discloses prior project context and supplies no
raw Linux logs here. Do not count four files as four independent reviews or
attribute the reported Linux checks to this author.

The author reproduced accessible parent failures, added narrow new-helper
repairs and a strict declared-type metadata entry, and retained all three old
script hashes. The parent reviews do not approve these new changes. The public derivative includes a technical summary in collaboration/process_record.md;
the evaluator key and prospective A/B plan are outside the participant package.
No new independent task-use trial, behavioral A/B or hardware operation is
claimed. Per-review handling and actual check logs are outside the candidate.

Human owner bx selected scope, supplied project evidence and correction history,
and approves publication. Codex/root performed this offline synthesis, wrote new
candidate documentation, helper code and tests, and ran author verification.
No independent reviewer, hand-written percentage or agent benchmark result is
invented. Candidate source is uncommitted diagnostic work, not a release tag.

## Local origins

The original `pynq-dma-validation` and `pynq-gemm-validation` are first visible
in root Git commit 342576c8f3b097e9036d2b68b4d32abc9299337a (2026-09-12 D003
baseline). This establishes earliest located repository presence, not who wrote
every line. Later local edits tightened retry, authorization and evidence scope.
The exact current bytes used as this candidate's starting point are listed in
`provenance.json`; root HEAD alone does not describe those dirty bytes.

Three historical scripts are mechanically copied unchanged from the root
`skill/` directory. Their SHA values and original relative paths are recorded.
New Skill entries/references and new helpers/tests are local candidate work.
The root OpenNPU MIT LICENSE is copied unchanged; no vendor binary, model asset
or private raw data is added. Provenance here is not completed legal clearance.

## External learning, not imported implementation

Read-only references consulted on 2026-10-20:

- OpenAI: https://developers.openai.com/plugins/build/skills
  Focused entrypoints, conditional references and deterministic helpers.
- OpenAI: https://developers.openai.com/blog/eval-skills
  Observable evaluation rather than structural validity alone.
- Anthropic: https://github.com/anthropics/skills/tree/main/skills/skill-creator
  Iterative task evaluation and comparison to a baseline.
- Superpowers: https://github.com/obra/superpowers/tree/main/skills/systematic-debugging
  and https://github.com/obra/superpowers/tree/main/skills/verification-before-completion
  Source investigation and evidence before completion claims. Their mandatory
  fresh-run wording is not adopted as automatic repetition of board tests.
- FPGA-Agent: https://github.com/Shinei-Nouzen-Arch/FPGA-Agent
  README-only domain survey of staged FPGA workflows; no implementation-quality
  endorsement or code import. Tool-version baseline is not assumed identical.

Only workflow ideas were summarized; no third-party Skill source, scripts,
templates, blanket mandatory rules or remote installers were copied. These
mutable links are reading pointers, not pinned dependencies needed to execute
the candidate. Future copied/adapted material needs its exact revision, license
and attribution checked separately. Star count is not validation evidence.

## Competition alignment

The supplied AMD guide sections 3.3.2 and 3.3.5.2 motivated reusable PYNQ tasks,
the `skill/README.md` entry, failure conditions and origins/effect statements.
The guide is not redistributed here. No scoring outcome or cross-board reuse is
claimed merely from having a Skill folder.
