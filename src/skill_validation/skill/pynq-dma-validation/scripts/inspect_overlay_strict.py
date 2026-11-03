#!/usr/bin/env python3
"""Inspect exact declared HWH IP type identities, not BIT or board validity."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import sys
import xml.etree.ElementTree as ET

MAX_HWH_BYTES = 16 * 1024**2
MAX_BIT_BYTES = 128 * 1024**2


def snapshot(path, limit, keep):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError("input must be a regular file, not a link or reparse point")
    if not 0 < info.st_size <= limit:
        raise ValueError("input empty or exceeds byte budget")
    digest = hashlib.sha256()
    blocks = []
    total = 0
    with path.open("rb") as source:
        while True:
            raw = source.read(min(1024**2, limit - total + 1))
            if not raw:
                break
            total += len(raw)
            if total > limit:
                raise ValueError("input grew beyond byte budget")
            digest.update(raw)
            if keep:
                blocks.append(raw)
    if total != info.st_size:
        raise ValueError("input size changed during read")
    return digest.hexdigest(), b"".join(blocks) if keep else None


def tag(element):
    return element.tag.rsplit("}", 1)[-1]


def inspect(bit_path, required_types):
    bit_path = Path(bit_path).absolute()
    if bit_path.suffix.lower() != ".bit":
        raise ValueError("bit path must have .bit suffix")
    hwh_path = bit_path.with_suffix(".hwh")
    if not isinstance(required_types, list) or not required_types:
        raise ValueError("provide at least one exact IP type")
    if any(not isinstance(t, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", t) for t in required_types):
        raise ValueError("required types must be exact type names, not VLNV/substrings")
    bit_sha, _ = snapshot(bit_path, MAX_BIT_BYTES, False)
    hwh_sha, raw = snapshot(hwh_path, MAX_HWH_BYTES, True)
    # Reject DTD/entity declarations instead of expanding user-authored entities.
    # HWH input is deliberately a UTF-8 XML subset; UTF-16 is not reinterpreted.
    text = raw.decode("utf-8-sig")
    if "<!DOCTYPE" in text.upper() or "<!ENTITY" in text.upper():
        raise ValueError("DTD and entity declarations are unsupported")
    xml = ET.fromstring(text)
    modules = []
    conflicts = []
    for element in xml.iter():
        if tag(element) != "MODULE":
            continue
        modtype = (element.get("MODTYPE") or "").strip()
        vlnv = (element.get("VLNV") or "").strip()
        parts = vlnv.split(":")
        vlnv_name = parts[2] if len(parts) == 4 and all(parts) else None
        conflict = bool(modtype and vlnv_name and modtype != vlnv_name)
        record = {"instance": element.get("INSTANCE"), "modtype": modtype or None,
                  "vlnv": vlnv or None, "vlnv_name": vlnv_name,
                  "type_conflict": conflict}
        modules.append(record)
        if conflict:
            conflicts.append(record)
    matches = {}
    for required in required_types:
        matched = []
        for record in modules:
            if record["type_conflict"]:
                continue
            fields = [key for key in ("modtype", "vlnv_name") if record[key] == required]
            if fields:
                matched.append({"instance": record["instance"], "matched_fields": fields,
                                "modtype": record["modtype"], "vlnv": record["vlnv"]})
        matches[required] = matched
    missing = [required for required in required_types if not matches[required]]
    return {"check_scope": "exact_declared_hwh_ip_types_only", "ok": not missing and not conflicts,
            "required_types": required_types, "missing_types": missing, "matches": matches,
            "modules": modules, "type_conflicts": conflicts,
            "bit_sha256": bit_sha, "hwh_sha256": hwh_sha,
            "bit_payload_validity_verified": False, "same_build_verified": False,
            "hardware_execution_verified": False, "address_map_verified": False}


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError("argument parsing: " + message)


def main():
    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument("bit", type=Path)
    parser.add_argument("--require-type", action="append")
    try:
        args = parser.parse_args()
        result = inspect(args.bit, args.require_type or ["axi_dma"])
    except (OSError, ValueError, ET.ParseError) as exc:
        print(json.dumps({"input_valid": False, "error": str(exc)}), file=sys.stderr)
        return 2
    print(json.dumps(result, allow_nan=False, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
