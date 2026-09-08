#!/usr/bin/env python3
"""Run independent real-Jolt motion experiments in background worker processes.

Build through `zig build vehicle-motion-report -Doptimize=ReleaseSafe -- [options]`.
Full per-tick evidence remains available from incinerator_vehicle_dynamics --motion-audit.
"""
import argparse
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import subprocess
import time

HEADINGS = (0, 90, 180, 270)


def run_case(binary, definition, heading, folder):
    stem = f"{definition.stem}-{heading}"
    output = folder / f"{stem}.json"
    log = folder / f"{stem}.log"
    started = time.perf_counter()
    with output.open("x") as out, log.open("x") as err:
        result = subprocess.run([str(binary), "--motion-summary", str(definition),
                                 "--heading", str(heading)], stdout=out, stderr=err)
    return dict(definition=str(definition), heading=heading, returncode=result.returncode,
                elapsed_seconds=time.perf_counter() - started, report=str(output), log=str(log))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("zig-out/vehicle-motion") /
                        datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ"))
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1,
                        help="Concurrent isolated processes; default is detected logical CPU count")
    parser.add_argument("definitions", nargs="*", type=Path,
                        default=sorted(Path("game/vehicles").glob("*.icvehicle")),
                        help="Admitted .icvehicle files; defaults to the game fleet assets")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if not args.definitions:
        parser.error("No admitted vehicle definitions found")
    definitions = [path.resolve(strict=True) for path in args.definitions]
    if len({path.stem for path in definitions}) != len(definitions):
        parser.error("Definition file stems must be distinct for report filenames")
    binary = args.binary.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=False)
    parts = args.output / "parts"
    parts.mkdir()
    started = time.perf_counter()
    futures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        for definition in definitions:
            for heading in HEADINGS:
                futures.append(executor.submit(run_case, binary, definition, heading, parts))
        # Submission order is the canonical report order, independent of scheduling.
        outcomes = [future.result() for future in futures]
    success = all(item["returncode"] == 0 for item in outcomes)
    if success:
        for index, definition in enumerate(definitions):
            cohort = outcomes[index * len(HEADINGS):(index + 1) * len(HEADINGS)]
            reports = [json.loads(Path(item["report"]).read_text()) for item in cohort]
            report = dict(reports[0])
            for part in reports[1:]:
                if {k: v for k, v in part.items() if k != "results"} != {k: v for k, v in report.items() if k != "results"}:
                    raise RuntimeError("Worker cohort or definition mismatch")
            report["results"] = [row for part in reports for row in part["results"]]
            report["sample_count"] = sum(row["sample_count"] for row in report["results"])
            (args.output / f"{definition.stem}.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    manifest = dict(schema=1, success=success, jobs=args.jobs, binary=str(binary),
                    elapsed_seconds=time.perf_counter() - started, workers=outcomes)
    (args.output / "run.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Vehicle motion {'PASS' if success else 'FAIL'}: {args.output} ({manifest['elapsed_seconds']:.2f}s)")
    if not success:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
