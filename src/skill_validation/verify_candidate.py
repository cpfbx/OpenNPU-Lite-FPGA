#!/usr/bin/env python3
"""Read-only member/hash check; integrity inventory is not authentication."""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


def pairs_unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate manifest key")
        result[key] = value
    return result


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024**2), b""):
            value.update(block)
    return value.hexdigest()


def link_or_reparse(info):
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def inventory(root):
    """Enumerate entries without opening links, FIFOs or device nodes."""
    if link_or_reparse(root.lstat()):
        raise ValueError("root is a symlink or reparse point")
    files, directories = set(), set()
    pending = [root]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if link_or_reparse(info):
                    raise ValueError("member is a symlink or reparse point")
                path = Path(entry.path)
                name = path.relative_to(root).as_posix()
                if stat.S_ISDIR(info.st_mode):
                    directories.add(name)
                    pending.append(path)
                elif stat.S_ISREG(info.st_mode):
                    files.add(name)
                else:
                    raise ValueError("member is not a regular file or directory")
    return files, directories


def verify(root):
    root = Path(root).absolute()
    if link_or_reparse(root.lstat()):
        raise ValueError("root is a symlink or reparse point")
    root = root.resolve()
    actual, directories = inventory(root)
    manifest = root / "manifest.json"
    if manifest.stat().st_size > 2 * 1024**2:
        raise ValueError("manifest exceeds budget")
    data = json.loads(manifest.read_text(encoding="utf-8"), object_pairs_hook=pairs_unique)
    if set(data) != {"format", "files"} or data["format"] != "skill-review-manifest-v1":
        raise ValueError("unsupported manifest")
    files = data["files"]
    if not isinstance(files, dict) or not files or len(files) > 1000:
        raise ValueError("invalid file inventory")
    for name, expected in files.items():
        if (not isinstance(name, str) or "\\" in name
                or any(p in ("", ".", "..") or not re.fullmatch(r"[A-Za-z0-9_.-]+", p)
                       for p in name.split("/"))
                or PurePosixPath(name).is_absolute() or name == "manifest.json"):
            raise ValueError("unsafe member name")
        if not isinstance(expected, str) or not re.fullmatch("[0-9a-f]{64}", expected):
            raise ValueError("invalid member SHA")
    errors = []
    allowed_directories = {parent.as_posix() for name in files
                           for parent in PurePosixPath(name).parents if parent.as_posix() != "."}
    for name in sorted(directories - allowed_directories):
        errors.append("unexpected directory: " + name)
    for name in sorted(actual - set(files) - {"manifest.json"}):
        errors.append("unexpected member: " + name)
    for name in sorted(set(files) - actual):
        errors.append("missing member: " + name)
    for name in sorted(set(files) & actual):
        path = root / name
        if not path.resolve().is_relative_to(root) or path.is_symlink():
            raise ValueError("member escapes root or is a symlink")
        if digest(path) != files[name]:
            errors.append("hash mismatch: " + name)
    return {"member_identity_ok": not errors, "indexed_files": len(files),
            "entry_policy": "regular_files_and_required_directories_only_no_links_or_reparse_points",
            "actual_files_including_manifest": len(actual), "errors": errors,
            "authentication_verified": False, "runtime_verified": False}


def main():
    try:
        result = verify(Path(__file__).resolve().parent)
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        print(json.dumps({"input_valid": False, "error": str(exc)}), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0 if result["member_identity_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
