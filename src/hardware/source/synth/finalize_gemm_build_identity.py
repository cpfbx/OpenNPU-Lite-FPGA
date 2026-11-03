#!/usr/bin/env python3
"""Bind a frozen GEMM build source identity to its generated artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_record(path: Path, repo_root: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"required build artifact is missing: {path}")
    return {
        "path": path.resolve().relative_to(repo_root.resolve()).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def finalize(repo_root: Path, source_identity_path: Path) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    source_identity_path = source_identity_path.resolve()
    source_identity = json.loads(source_identity_path.read_text(encoding="utf-8-sig"))
    if source_identity.get("schema") != "opennpu.build-source-identity.v1":
        raise ValueError("unsupported source identity schema")
    if not source_identity.get("git_commit"):
        raise ValueError("source identity has no git commit")

    # The source sidecar and generated artifacts share a report directory.
    # This also supports isolated experimental builds without reading the
    # frozen production reports by mistake.
    report_dir = source_identity_path.parent
    paths = {
        "bit": report_dir / "opennpu_gemm_accelerator.bit",
        "hwh": report_dir / "opennpu_gemm_accelerator.hwh",
        "xsa": report_dir / "opennpu_gemm_accelerator.xsa",
        "timing": report_dir / "gemm_accelerator_implementation_timing_summary.rpt",
        "utilization": report_dir / "gemm_accelerator_implementation_utilization.rpt",
    }
    if (source_identity.get("parameters", {}).get("d007_p_hold_margin") or
            source_identity.get("parameters", {}).get("mode11_implementation_min_delay_ns", 0)):
        paths["constrained_timing"] = (
            report_dir / "gemm_accelerator_implementation_constrained_timing_summary.rpt"
        )
    return {
        "schema": "opennpu.build-artifact-identity.v1",
        "captured_utc": datetime.now(timezone.utc).isoformat(),
        "source_identity": {
            **artifact_record(source_identity_path, repo_root),
            "schema": source_identity["schema"],
            "git_commit": source_identity["git_commit"],
            "git_dirty": bool(source_identity.get("git_dirty")),
            "parameters": source_identity.get("parameters", {}),
        },
        "artifacts": {
            label: artifact_record(path, repo_root) for label, path in paths.items()
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--source-identity", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = finalize(args.repo_root, args.source_identity)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        "Build artifact identity: "
        f"commit={result['source_identity']['git_commit']} "
        f"bit={result['artifacts']['bit']['sha256']} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
