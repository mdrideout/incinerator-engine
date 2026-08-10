#!/usr/bin/env python3
"""Audit NR4-C frame packages for exact single-cause segment ownership."""

from __future__ import annotations

import argparse
from pathlib import Path

from nr4_common import atomic_json, load_json, read_ndjson, sha256_file, validate_frame_package
from sequence_contract import audit_packages


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-frame-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = args.target_frame_root.resolve()
    output = args.output.resolve()
    if output.exists():
        raise FileExistsError(f"causal audit already exists: {output}")
    manifest = load_json(root / "target-frames.json")
    records = read_ndjson(root / manifest["frame_index"])
    packages = []
    package_records = []
    for record in records:
        path = root / record["path"]
        if sha256_file(path) != record["sha256"]:
            raise ValueError("target-frame package digest mismatch during causal audit")
        package = load_json(path)
        validate_frame_package(package)
        packages.append(package)
        package_records.append(
            {
                "frame_id": package["frame_id"],
                "presentation_frame": package["presentation_frame"],
                "path": str(path),
                "sha256": record["sha256"],
            }
        )
    result = audit_packages(packages)
    result["packages"] = package_records
    atomic_json(output, result)
    print(output)


if __name__ == "__main__":
    main()
