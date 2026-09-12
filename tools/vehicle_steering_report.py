#!/usr/bin/env python3
"""Run matched-entry steering/surface experiments without a renderer or window."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    started = time.monotonic()

    def measure(path):
        output = args.output / (path.stem + '.json')
        with output.open('w') as stream:
            result = subprocess.run([str(Path(args.binary).resolve()), '--steering-audit', str(path)], stdout=stream, stderr=subprocess.PIPE, text=True)
        (args.output / (path.stem + '.log')).write_text(result.stderr)
        if result.returncode:
            return dict(definition=str(path), returncode=result.returncode)
        report = json.loads(output.read_text())
        return dict(definition=str(path), returncode=0, rows=len(report['results']), entries_reached=sum(row['entry_reached'] for row in report['results']))

    with concurrent.futures.ThreadPoolExecutor() as pool:
        results = list(pool.map(measure, sorted((root / 'game/vehicles').glob('*.icvehicle'))))
    success = all(row['returncode'] == 0 for row in results)
    (args.output / 'run.json').write_text(json.dumps(dict(success=success, elapsed_seconds=time.monotonic()-started, results=results), indent=2)+'\n')
    print(f"Steering experiments {'completed' if success else 'failed'}: {args.output}; unavailable entry speeds are reported, not passed")
    return 0 if success else 1


if __name__ == '__main__':
    raise SystemExit(main())
