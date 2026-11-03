#!/usr/bin/env python3
"""Check local SHA/line references, never claim truth or source authenticity."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import sys

MAX_REVIEW = 2 * 1024**2
MAX_ARTIFACT = 128 * 1024**2
MAX_TEXT = 4 * 1024**2


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError("nonfinite JSON constant: " + value)


def load_review(path):
    path = Path(path)
    no_aliases(path)
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("review input is not a regular file")
    with path.open("rb") as source:
        raw = source.read(MAX_REVIEW + 1)
    if len(raw) > MAX_REVIEW:
        raise ValueError("review input exceeds budget")
    return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                      parse_constant=reject_constant)


def fields(obj, required, optional=()):
    if not isinstance(obj, dict) or not set(required) <= obj.keys():
        raise ValueError("missing object fields")
    if set(obj) - set(required) - set(optional):
        raise ValueError("unexpected object fields")


def no_aliases(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError("symlink or reparse-point reference is unsupported")


def local_path(root, value):
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError("reference path must be relative POSIX")
    parts = value.split("/")
    if any(p in ("", ".", "..") or not re.fullmatch(r"[A-Za-z0-9_.-]+", p)
           for p in parts) or PurePosixPath(value).is_absolute():
        raise ValueError("unsafe reference path")
    path = root
    for part in parts:
        path = path / part
        try:
            no_aliases(path)
        except FileNotFoundError:
            break
    path = (root / value).resolve()
    if not path.is_relative_to(root):
        raise ValueError("resolved reference escapes root")
    return path


def validate_document(document, root):
    root = Path(root).absolute()
    no_aliases(root)
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("root is not a directory")
    fields(document, ("format", "claims"))
    if document["format"] != "skill-review-links-v1":
        raise ValueError("unsupported link format")
    claims = document["claims"]
    if not isinstance(claims, list) or not 1 <= len(claims) <= 1000:
        raise ValueError("claim list empty or exceeds budget")
    seen = set()
    total = 0
    jobs = []
    for claim in claims:
        fields(claim, ("id", "statement", "classification", "references"))
        for key in ("id", "statement"):
            if not isinstance(claim[key], str) or not claim[key].strip():
                raise ValueError("claim id/statement must be nonempty text")
        if claim["id"] in seen:
            raise ValueError("duplicate claim id")
        seen.add(claim["id"])
        if claim["classification"] not in ("observed", "derived", "conditional", "unverified"):
            raise ValueError("unsupported declared classification")
        refs = claim["references"]
        if not isinstance(refs, list) or (not refs and claim["classification"] != "unverified"):
            raise ValueError("claim classification needs references")
        total += len(refs)
        if total > 5000:
            raise ValueError("reference budget exceeded")
        for ref in refs:
            fields(ref, ("path", "sha256"), ("lines", "quote"))
            path = local_path(root, ref["path"])
            if not isinstance(ref["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", ref["sha256"]):
                raise ValueError("SHA256 must be 64 lowercase hex characters")
            if ("lines" in ref) != ("quote" in ref):
                raise ValueError("lines and quote must be supplied together")
            if "lines" in ref:
                span = ref["lines"]
                if (not isinstance(span, list) or len(span) != 2
                        or any(type(v) is not int for v in span)
                        or not 1 <= span[0] <= span[1]):
                    raise ValueError("invalid inclusive line range")
                if not isinstance(ref["quote"], str) or not ref["quote"].strip():
                    raise ValueError("quote must be nonempty text")
            jobs.append((claim["id"], ref, path))
    return claims, jobs


def check(document, root):
    claims, jobs = validate_document(document, root)
    errors = []
    cache = {}
    anchored = {path for _, ref, path in jobs if "lines" in ref}
    total_read = 0
    for claim_id, ref, path in jobs:
        try:
            if path not in cache:
                if not path.is_file():
                    raise OSError("reference is missing or not a regular file")
                limit = MAX_TEXT if path in anchored else MAX_ARTIFACT
                if path.stat().st_size > limit:
                    raise ValueError("reference exceeds byte budget")
                digest = hashlib.sha256()
                blocks = [] if path in anchored else None
                read = 0
                with path.open("rb") as source:
                    while True:
                        block = source.read(min(1024**2, limit - read + 1))
                        if not block:
                            break
                        read += len(block)
                        total_read += len(block)
                        if total_read > 256 * 1024**2:
                            raise ValueError("aggregate reference byte budget exceeded")
                        if read > limit:
                            raise ValueError("reference grew beyond byte budget")
                        digest.update(block)
                        if blocks is not None:
                            blocks.append(block)
                cache[path] = (digest.hexdigest(), read,
                               b"".join(blocks) if blocks is not None else None)
            digest, size, raw = cache[path]
            if digest != ref["sha256"]:
                errors.append({"claim": claim_id, "path": ref["path"], "error": "sha256 mismatch"})
                continue
            if "lines" in ref:
                if size > MAX_TEXT:
                    raise ValueError("anchored reference exceeds text budget")
                if raw is None:
                    raise ValueError("text snapshot unavailable")
                text = raw.decode("utf-8").replace("\r\n", "\n")
                lines = text.split("\n") if text else []
                if text.endswith("\n"):
                    lines.pop()
                start, end = ref["lines"]
                if end > len(lines) or ref["quote"] not in "\n".join(lines[start-1:end]):
                    errors.append({"claim": claim_id, "path": ref["path"], "error": "line quote mismatch"})
        except OSError:
            errors.append({"claim": claim_id, "path": ref["path"], "error": "reference unreadable or missing"})
    return {
        "check_scope": "reference_bytes_and_optional_line_quotes_only",
        "link_integrity_ok": not errors,
        "claims_examined": len(claims),
        "references_examined": len(jobs),
        "declared_classifications": {c["id"]: c["classification"] for c in claims},
        "errors": errors,
        "claim_truth_verified": False,
        "source_authenticity_verified": False,
        "independent_review_completed": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("review", type=Path)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = check(load_review(args.review), args.root)
    except (OSError, ValueError, TypeError, UnicodeError) as exc:
        print(json.dumps({"input_valid": False, "error": str(exc),
                          "claim_truth_verified": False}), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return 0 if result["link_integrity_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
