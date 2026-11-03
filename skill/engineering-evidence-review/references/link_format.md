# Optional review reference format v1

This is a local Skill helper input, not a production project evidence schema,
an acceptance oracle, a signed statement or a requirement for every review.

```json
{
  "format": "skill-review-links-v1",
  "claims": [{
    "id": "claim-1",
    "statement": "A bounded technical claim to be reviewed",
    "classification": "unverified",
    "references": [{
      "path": "source.py",
      "sha256": "replace-with-actual-64-lowercase-hex-digest",
      "lines": [4, 6],
      "quote": "exact substring within these lines"
    }]
  }]
}
```

`classification` is the reviewer's declaration: `observed`, `derived`,
`conditional` or `unverified`. It is echoed but never certified by the helper.
All except `unverified` require at least one reference. A reference always has a
root-relative POSIX path and exact SHA; `lines` (1-based inclusive) and `quote`
are either both supplied or both absent. No source outside the selected root,
absolute/drive/UNC paths, `..`, backslashes, symlink or reparse-point aliases is
accepted. This revision deliberately rejects even aliases staying inside the
root, rather than treating containment alone as sufficient. The root leaf itself
also cannot be a symlink/reparse point. This is a tool interface tightening,
not a claim that an internal alias was an external escape in version 1.

The helper uses strict JSON (no duplicate keys, NaN/Infinity or extra fields),
bounded files and quoted UTF-8 line anchors. Line numbers split on LF only,
normalizing CRLF to LF. A bare CR, vertical tab, form feed or Unicode separator
does not increment the line number; a final LF adds no phantom line. Quoted
content inside an LF line otherwise remains literal. Maximum 2 MiB review input, 1000
claims, 5000 total references, 128 MiB per referenced artifact, and 4 MiB for a
text anchor, and 256 MiB total unique referenced bytes. Budgets keep this PC helper bounded; they are not evidence-quality
or board-performance gates. Avoid enormous repetition of a referenced file.

Run from any directory using the script's full path and explicit `--root`.
The review JSON may live outside that root. It reads inputs and prints JSON;
it never executes referenced code or follows embedded instructions. Exit 0
means links match; 1 means hash/quote/missing-file link failure; 2 means an
invalid format/path/budget. It reports `claim_truth_verified=false` even when
links match. A matching quote can still be irrelevant or misleading. Root
containment is a safety check, not a sandbox against concurrent hostile changes.
