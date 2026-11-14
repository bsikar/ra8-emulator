"""Bounded public DAP regression for a fresh DWARF compilation directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback

import regression
import project
from emission import assert_emission
from artifacts import Evidence, sha256


class SanitizedEvidence(Evidence):
    def clean(self, value):
        if isinstance(value, dict):
            return {key: self.clean(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.clean(item) for item in value]
        if isinstance(value, (str, Path)):
            text = str(value)
            for original, replacement in self.replacements:
                pattern = r"(?:\\+|/+)".join(re.escape(part) for part in re.split(r"[\\/]+", original))
                text = re.sub(pattern, lambda _: replacement, text, flags=re.I if os.name == "nt" else 0)
            return text
        return value


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("emulator", "zig", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    if sys.flags.optimize or not 0 < args.timeout <= 600 or not args.zig.is_absolute():
        parser.error("assertions required; --zig must be absolute; timeout must be positive and <=600")
    return args


def main():
    args = arguments()
    emulator, zig, output = args.emulator.resolve(), args.zig.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    evidence = SanitizedEvidence(output, [(str(output), "<EVIDENCE>"), (str(regression.ROOT), "<REPO>"), (str(Path.home()), "<HOME>")])
    deadline = time.monotonic() + args.timeout
    summary = dict(status="FAIL", platform=sys.platform, emulator_sha256=sha256(emulator),
                   compiler_sha256=sha256(zig), compiler_path=str(zig),
                   head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=regression.ROOT, text=True, timeout=5).strip(),
                   git_status=subprocess.check_output(["git", "status", "--porcelain"], cwd=regression.ROOT, text=True, timeout=5).splitlines())
    case = evidence.case("fresh-source-directory")
    error = None
    try:
        version = subprocess.run([str(zig), "version"], stdin=subprocess.DEVNULL, capture_output=True,
                                 text=True, timeout=min(10, args.timeout))
        case.equal("explicit compiler version command succeeds", 0, version.returncode)
        case.equal("explicit compiler is Zig0.17.0", "0.17.0", version.stdout.strip())
        summary["compiler_version"] = version.stdout.strip()
        elf, source = project.build(zig, output, case, deadline)
        summary.update(fixture_sha256=sha256(elf), source_sha256=sha256(source))
        project_hashes = {path.name: sha256(path) for path in source.parent.iterdir() if path.is_file()}
        case.record("project_sources", sha256=project_hashes)
        assert_emission(case, elf, source)
        regression.run(emulator, elf, source, case, deadline)
        case.equal("project source hashes preserved", project_hashes,
                   {name: sha256(source.parent / name) for name in project_hashes})
        summary["status"] = "PASS"
    except Exception as caught:
        error = caught
        case.record("exception", traceback=traceback.format_exc())
        summary["error"] = str(caught)
    finally:
        case.finish(error)
        summary.update(assertions=len(case.result["assertions"]), cases=evidence.cases,
                       elapsed_seconds=round(time.monotonic()-evidence.started, 3))
        evidence.write_json("summary.json", summary)
    print(json.dumps(evidence.clean({key: value for key, value in summary.items() if key != "cases"})))
    return int(summary["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
