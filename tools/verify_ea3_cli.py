#!/usr/bin/env python3
"""Exercise the real CLI against an isolated, hidden native lighting host."""
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    host, client = sys.argv[1:]
    pattern = "*/Library/Logs/Incinerator/developer/discovery.json"
    directory = Path(".zig-cache/tmp")
    previous = set(directory.glob(pattern))
    log_path = Path("zig-out/ea3-cli-acceptance.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        process = subprocess.Popen([host], stdout=log, stderr=log)
        try:
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"native host exited before discovery; see {log_path}")
                candidates = set(directory.glob(pattern)) - previous
                available = [p for p in candidates if json.loads(p.read_text()).get("lifecycle") == "available"]
                if available:
                    if len(available) != 1:
                        raise RuntimeError("ambiguous concurrent acceptance discovery")
                    discovery = str(available[0].resolve())
                    break
                time.sleep(0.05)

            def invoke(args, reject=False):
                result = subprocess.run([client, *args], capture_output=True, text=True)
                if (result.returncode != 0) != reject:
                    raise RuntimeError(f"CLI failed: {args[0:2]}\n{result.stdout}\n{result.stderr}")
                return json.loads(result.stdout)

            bootstrap = invoke(["agent", "bootstrap", "--discovery", discovery])
            catalog = invoke(["agent", "catalog"])
            assert bootstrap["catalog_digest"] == catalog["catalog_digest"]
            operations = {x["id"]: x for x in catalog["operations"]}
            for operation in ["list", "inspect", "preview", "clear-preview", "apply", "undo", "redo", "revert", "activate", "commit"]:
                assert operations["lighting." + operation]["completion"] == "synchronous"
            options = ["--discovery", discovery, "--expected-run", bootstrap["expected_run"]]
            view = invoke(["lighting", "list", *options])["response"]["outcome"]["success"]["lighting_list"]
            assert view["persistence_available"] and view["installed_root"] != view["project_root"]
            record = next(x for x in view["records"] if x["label"] == "Night")
            target = "content-asset:{namespace}:{local}".format(**record["id"])

            def call(operation, revision=None, value=None, reject=False):
                args = ["lighting", operation, "--target", target, *options]
                if revision is not None:
                    args += ["--expected-revision", str(revision)]
                if value is not None:
                    args += ["--value", json.dumps(value, separators=(",", ":"))]
                result = invoke(args, reject)["response"]["outcome"]["success"]
                return result.get("lighting_outcome", result.get("lighting_inspection"))

            record = call("inspect")
            revision = record["revision"]
            candidate = record["session"]
            candidate["environment"]["display"]["exposure"] *= 0.75
            call("preview", revision, candidate)
            preview = call("inspect")
            assert preview["revision"] == revision and preview["preview"] is not None
            candidate = preview["preview"]["value"]  # admitted f32 representation
            call("clear-preview", revision)
            assert call("inspect")["preview"] is None
            applied = call("apply", revision, candidate)
            assert call("inspect")["session"] == candidate
            stale = call("apply", revision, candidate, reject=True)
            assert stale["rejection"] == "stale_revision"
            undone = call("undo", applied["revision"])
            assert call("inspect")["session"] != candidate
            redone = call("redo", undone["revision"])
            assert call("inspect")["session"] == candidate
            reverted = call("revert", redone["revision"])
            assert call("inspect")["session"] != candidate
            reapplied = call("apply", reverted["revision"], candidate)
            call("activate", reapplied["revision"])
            committed = call("commit", reapplied["revision"])
            assert committed["rejection"] is None and committed["asset_revision"] == reapplied["revision"]
            # The host independently reloads disk and checks every committed
            # value before it exits; no second mutation/control interface.
            if process.wait() != 0:
                raise RuntimeError(f"native durable reload failed; see {log_path}")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait()
    print("EA3_CLI_ACCEPTANCE bootstrap=true catalog=true preview=true stale_rejection=true history=true durable_reload=true hidden=true")


if __name__ == "__main__":
    main()
