# OpenNPU-Lite Skill: public documentation derivative

# OpenNPU-Lite reusable Skill review candidate 03

Internal candidate, 2026-10-20. Human owner bx; offline author Codex/root.
Not installed or published; these new changes have not received independent
review or approval as a new default. Supplied reviews concern parent revisions.

Start with [skill/readme.md](skill/readme.md). This bundle contains three
instruction workflows, optional read-only helpers, synthetic examples, and
offline tests. No BIT/HWH, firmware, ARM library, model weights, credentials,
personal recordings or captured power CSV are included.

## PC verification

Python 3.10+ standard library is sufficient for the bundled checks. From this
directory, run each command separately and retain its actual exit code:

```text
python -I -B verify_candidate.py
python -I -B tests/run_tests.py
python -I -B skill/pynq-gemm-validation/scripts/validate_gemm_evidence.py --self-test
python -I -B skill/pynq-gemm-validation/scripts/validate_resilience_evidence.py --self-test
python -I -B skill/engineering-evidence-review/scripts/check_evidence_links.py evaluation/link_example.json --root evaluation/fixtures
python -I -B verify_candidate.py
```

The last two historical validators retain their original limitations; see the
GEMM reference before interpreting their output. These are not hardware checks.
The evidence-link tool verifies references, not the truth of a natural-language
claim. Exit 0 has a different documented scope for each tool.

Tests generate tiny synthetic files in OS temporary directories, never beside
an original input. The manifest checker reads the candidate and prints JSON;
test logs should be saved outside the candidate. No dependency installation is
performed. Third-party PyYAML is needed only for the author's separate official
`quick_validate.py` run, not for any bundled command above.

## Agent review

[evaluation/tasks.json](evaluation/tasks.json) contains neutral, synthetic user
requests. A new-session reviewer should choose relevant Skills and complete the
requests using the supplied raw fixtures. Record artifact references, unresolved
questions, actual commands and conclusions, not just whether the prose is clear.
Do not execute the source excerpts: they are incomplete illustrations.

The author has not run a fresh-context agent evaluation or with/without-Skill
benchmark. Parent reviews record context-exposed task judgments, not a blind
trial. Raw external Linux/gVisor logs were subsequently supplied: v2 ran 82 tests,
with 81 passing, one stale exception-message assertion failing, and zero skips.
The link was rejected; its test expected an older diagnostic. That failure is
retained as a v2 result, not rewritten as a pass. This revision synchronizes the
assertion, rejects non-.bit inspector inputs and makes strict CLI errors JSON.
It adds an OS-independent diagnostic simulation, not replacement OS-link proof.
Neither the old logs nor the simulation constitute Linux execution of v3.
Script unit tests and author checks must not be counted as agent-use trials.

Read [the public technical collaboration summary](collaboration/process_record.md)
for requirements, implementation and correction history. This release copy
replaces transcript excerpts; executable helpers and tests retain their
original bytes. The original review candidate is preserved by the owner.

See [provenance.md](provenance.md) for origins and retained-script identity and
[limitations.md](limitations.md) before reuse.

Member checks reject symlink/reparse entries, special files and unlisted
directories before reading member bytes. This is a local stable-snapshot
inventory, not protection against a hostile concurrently mutating filesystem.
