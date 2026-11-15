"""Run pinned Zig analysis and reject findings outside the reviewed baseline."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from baseline import compare, findings, load, save

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "tools/lint/baseline.json"


def report(zig, includes=()):
    command = [zig, "build", "lint-report", "-Dlint-report=true", "-j1", "--",
               "--format", "json", "--exit-zero"]
    if includes:
        command += ["--include", *map(str, includes)]
    environment = os.environ.copy()
    if os.name == "nt":
        # Zig's optional program probe panics on malformed Windows PATH entries.
        # Filter only this analysis child, keeping the explicitly selected Zig.
        entries = environment.get("PATH", "").split(os.pathsep)
        usable = [entry for entry in entries if entry and os.path.isdir(entry)]
        if usable != entries:
            print(f"lint: analysis child skips {len(entries) - len(usable)} unavailable PATH entries", file=sys.stderr)
        environment["PATH"] = os.pathsep.join(usable)
    result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, timeout=600)
    if result.returncode:
        sys.stderr.buffer.write(result.stderr)
        raise RuntimeError(f"linter failed with exit {result.returncode}")
    document = json.loads(result.stdout)
    if document.get("status") not in {"success", "warning", "failure"}:
        raise ValueError("missing or invalid linter status")
    if document["status"] == "failure":
        raise ValueError("linter reported an analysis error; baseline cannot suppress it")
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", required=True)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--update-baseline", action="store_true")
    group.add_argument("--prune-baseline", action="store_true")
    args = parser.parse_args()
    current, locations = findings(report(args.zig), ROOT)
    if args.update_baseline:
        save(BASELINE, current)
        print(f"lint: wrote {sum(current.values())} findings; review the baseline diff")
        return 0

    previous = load(BASELINE)
    added, removed = compare(current, previous)
    for key, count in sorted(added.items()):
        print(f"{locations[key]} ({count} new)")
    if added:
        print(f"lint: {sum(added.values())} new findings", file=sys.stderr)
        return 1
    if args.prune_baseline:
        save(BASELINE, current)
    elif removed:
        print("lint: fixed findings remain in baseline; run zig build lint -- --prune-baseline", file=sys.stderr)
        return 1
    print(f"lint: no new findings; {sum(current.values())} baselined existing findings")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"lint: {error}", file=sys.stderr)
        sys.exit(2)
