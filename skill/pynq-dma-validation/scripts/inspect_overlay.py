#!/usr/bin/env python3
"""Statically inspect a same-stem PYNQ .bit/.hwh overlay bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parameter(module: ET.Element, name: str) -> str | None:
    item = module.find(f"./PARAMETERS/PARAMETER[@NAME='{name}']")
    return None if item is None else item.get("VALUE")


def inspect(bit_path: Path, required_types: list[str]) -> dict:
    bit_path = bit_path.resolve()
    hwh_path = bit_path.with_suffix(".hwh")
    if not bit_path.is_file():
        raise FileNotFoundError(bit_path)
    if not hwh_path.is_file():
        raise FileNotFoundError(f"same-stem HWH missing: {hwh_path}")

    root = ET.parse(hwh_path).getroot()
    modules = []
    for module in root.findall(".//MODULE"):
        item = {
            "instance": module.get("INSTANCE"),
            "fullname": module.get("FULLNAME"),
            "type": module.get("MODTYPE"),
            "vlnv": module.get("VLNV"),
        }
        base = parameter(module, "C_BASEADDR")
        high = parameter(module, "C_HIGHADDR")
        if base is not None:
            item["base_address"] = base
        if high is not None:
            item["high_address"] = high
        modules.append(item)

    searchable = "\n".join(
        " ".join(str(item.get(field, "")) for field in ("instance", "type", "vlnv"))
        for item in modules
    ).lower()
    missing = [fragment for fragment in required_types if fragment.lower() not in searchable]
    memory_ranges = [
        dict(node.attrib)
        for node in root.findall(".//MEMRANGE")
        if node.get("MEMTYPE", "").upper() == "MEMORY"
    ]
    return {
        "schema": "pynq.overlay_inspection.v1",
        "ok": not missing,
        "bit": str(bit_path),
        "hwh": str(hwh_path),
        "bit_sha256": sha256(bit_path),
        "hwh_sha256": sha256(hwh_path),
        "required_type_fragments": required_types,
        "missing_type_fragments": missing,
        "addressable_modules": [item for item in modules if "base_address" in item],
        "memory_ranges": memory_ranges,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bit", type=Path)
    parser.add_argument("--require-type", action="append", default=None)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    required = args.require_type if args.require_type else ["axi_dma"]
    try:
        result = inspect(args.bit, required)
    except (OSError, ET.ParseError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2
    rendered = json.dumps(result, indent=2)
    print(rendered)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(rendered + "\n", encoding="utf-8")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
