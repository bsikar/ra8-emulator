"""Bounded public DAP conformance. Build emulator/fixtures separately before running."""
import argparse
import dataclasses
import hashlib
import json
import platform
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

import errors
import execution
import inspection
from artifacts import Evidence, sha256


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("emulator", "fixture", "oracle", "output"):
        parser.add_argument("--" + flag, required=True, type=Path)
    parser.add_argument("--fault-fixture", type=Path)
    parser.add_argument("--overall-timeout", type=float, default=180)
    parser.add_argument("--request-timeout", type=float, default=5)
    parser.add_argument("--startup-timeout", type=float, default=15)
    parser.add_argument("--pause-timeout", type=float, default=2)
    args = parser.parse_args()
    for key in ("overall_timeout", "request_timeout", "startup_timeout", "pause_timeout"):
        if not 0 < getattr(args, key) <= 800:
            parser.error("deadlines must be positive and no greater than 800 seconds")
    return args


@dataclasses.dataclass
class Settings:
    emulator: Path
    fixture: Path
    oracle: dict
    deadline: float
    request_timeout: float
    startup_timeout: float
    pause_timeout: float


def matrix():
    return [
        {"feature": "single-core public DAP TCP", "support": "SUPPORTED", "case": "launch,attach"},
        {"feature": "dual-core public DAP CLI", "support": "UNSUPPORTED", "case": "request-errors", "evidence": "only CPU0 discovered; CPU1 requests explicitly refused"},
        {"feature": "reverse execution", "support": "UNSUPPORTED", "case": "request-errors", "evidence": "capability absent; stepBack/reverseContinue refused"},
        {"feature": "instruction step, call-aware next and stepOut", "support": "SUPPORTED", "case": "known-state,calls,step-out"},
        {"feature": "source/statement stepping", "support": "UNSUPPORTED", "case": "request-errors", "evidence": "statement/line/omitted granularity refused"},
        {"feature": "source/instruction breakpoints and independent groups", "support": "SUPPORTED", "case": "source-frames,point-groups,current-break"},
        {"feature": "register and source inspection", "support": "SUPPORTED", "case": "known-state,source-frames"},
        {"feature": "DWARF locals", "support": "PARTIAL", "case": "source-frames", "evidence": "fixture values must be exact or explicitly unavailable"},
        {"feature": "caller scopes", "support": "UNSUPPORTED", "case": "source-frames", "evidence": "empty scopes instead of fabricated innermost values"},
        {"feature": "memory/peripheral inspection", "support": "UNSUPPORTED", "case": "request-errors", "evidence": "readMemory not advertised and explicitly refused"},
        {"feature": "another external debugger owner", "support": "UNAVAILABLE AT THIS CLI", "case": "point-groups", "evidence": "public DAP owns one in-process Session; source/instruction group ownership covered; independent owner unit gate remains separate"},
    ]


def cases(settings, fault_settings):
    yield "launch", lambda case: execution.lifecycle(settings, case, "launch")
    yield "attach", lambda case: execution.lifecycle(settings, case, "attach")
    yield "automatic-launch", lambda case: execution.automatic_launch(settings, case)
    for name, function in (("known-state", execution.known_state), ("calls", execution.calls), ("step-out", execution.step_out), ("source-frames", inspection.source_and_frames), ("point-groups", inspection.independent_groups), ("current-break", execution.continue_current_breakpoint), ("pause-loop", execution.pause_loop), ("request-errors", errors.requests), ("eof-entry", errors.eof_at_entry), ("uri-path", errors.uri_path)):
        yield name, lambda case, fn=function: fn(settings, case)
    yield "eof-running", lambda case: execution.pause_loop(settings, case, loss=True)
    yield "controlled-fault", lambda case: execution.fault(fault_settings, case)
    packets = {
        "bad-json": b"Content-Length: 1\r\n\r\n{",
        "missing-length": b"X: ignored\r\n\r\n",
        "duplicate-length": b"Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
        "oversized-body": b"Content-Length: 65537\r\n\r\n",
        "oversized-header": b"X: " + b"a" * 1024 + b"\r\n\r\n",
        "invalid-request": b"Content-Length: 2\r\n\r\n{}",
    }
    for name, packet in packets.items():
        yield name, lambda case, data=packet: errors.malformed(settings, case, data)


def harness_hash():
    digest = hashlib.sha256()
    for path in sorted(Path(__file__).parent.glob("*.py")):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def metadata(args):
    root = Path(__file__).resolve().parents[2]
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True, timeout=10).strip()
    diff = subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=root, timeout=10)
    return {"git_head": head, "tracked_diff_sha256": hashlib.sha256(diff).hexdigest(), "python": platform.python_version(), "platform": platform.platform(), "emulator_sha256": sha256(args.emulator), "fixture_sha256": sha256(args.fixture), "oracle_sha256": sha256(args.oracle), "harness_sha256": harness_hash()}


def main():
    args = arguments()
    root = Path(__file__).resolve().parents[2]
    replacements = [(str(root), "<workspace>"), (str(Path.home()), "<home>"), (str(args.output.resolve()), "<artifacts>")]
    evidence = Evidence(args.output, replacements)
    result = {"schema_version": 1, "status": "FAIL", "cases": evidence.cases, "capability_matrix": matrix(), "remaining_gates": ["Real editor interoperability is a separate lane; this wire harness does not establish editor acceptance."]}
    try:
        for key in ("emulator", "fixture", "oracle"):
            setattr(args, key, getattr(args, key).resolve(strict=True))
        oracle = json.loads(args.oracle.read_text(encoding="utf-8"))
        if oracle["fixture_sha256"] != sha256(args.fixture):
            raise ValueError("fixture bytes do not match independent oracle")
        if "address" not in oracle["source"]:
            raise ValueError("source breakpoint oracle requires independent source.address")
        if oracle["source"]["sha256"] != sha256(oracle["source"]["path"]):
            raise ValueError("fixture source bytes do not match independent oracle")
        fault_path = (args.fault_fixture or Path(oracle["fault"]["path"])).resolve(strict=True)
        if oracle["fault"]["sha256"] != sha256(fault_path):
            raise ValueError("fault fixture bytes do not match independent oracle")
        deadline = time.monotonic() + args.overall_timeout
        settings = Settings(args.emulator, args.fixture, oracle, deadline, args.request_timeout, args.startup_timeout, args.pause_timeout)
        fault_oracle = {"symbols": oracle["fault"]["symbols"], "entry": oracle["fault"]["symbols"]["Reset_Handler"]}
        fault_settings = dataclasses.replace(settings, fixture=fault_path, oracle=fault_oracle)
        result["environment"] = metadata(args)
        result["limits_seconds"] = {"overall": args.overall_timeout, "request": args.request_timeout, "startup": args.startup_timeout, "pause": args.pause_timeout}
        for name, function in cases(settings, fault_settings):
            case = evidence.case(name)
            try:
                if time.monotonic() >= deadline:
                    raise TimeoutError("overall conformance deadline expired before scenario")
                function(case)
            except Exception as error:
                case.finish(error)
            else:
                case.finish()
            print(json.dumps({"case": name, "status": case.result["status"], "error": case.result.get("error")}))
        result["status"] = "PASS" if all(case["status"] == "PASS" for case in evidence.cases) else "FAIL"
    except Exception as error:
        result["prerequisite_error"] = f"{type(error).__name__}: {error}"
    result["elapsed_seconds"] = round(time.monotonic() - evidence.started, 3)
    evidence.write_json("result.json", result)
    print(json.dumps({"status": result["status"], "cases": len(evidence.cases), "result": "result.json"}))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
