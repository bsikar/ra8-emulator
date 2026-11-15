"""Prebuilt-fixture mode for gdb_batch.sh, driven by an actual GDB process."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import cases
import loss
import mi
import peripheral
from process import Emulator, sanitize, write_json


def assertion_records(transcript):
    expressions = dict(re.findall(r"^ASSERT_EXPECT (\S+) (.+)$", transcript, re.MULTILINE))
    actual = dict(re.findall(r"^ASSERT_RESULT (\S+) expected=1 actual=([01])$", transcript, re.MULTILINE))
    return [{"name": name, "expression": expression, "expected": True,
             "actual": actual.get(name) == "1" if name in actual else None}
            for name, expression in expressions.items()]


def run_batch(args, name, commands, expected, fixture=None, cpu1=None, refuse=False, forbidden=()):
    if time.monotonic() >= args.deadline:
        return {"name": name, "status": "FAIL", "error": "overall deadline expired"}
    emulator = Emulator(args.emulator, fixture or args.fixture, cpu1, args.deadline)
    transcript = ""
    result = {"name": name, "status": "FAIL"}
    try:
        emulator.ready()
        setup = ["set pagination off", "set confirm off", "set remotetimeout 5",
                 f"target remote 127.0.0.1:{emulator.port}"]
        script = args.output / (name + ".gdb")
        script.write_text("\n".join(setup + commands) + "\n", encoding="utf-8")
        start = time.monotonic()
        client = subprocess.run([str(args.gdb), "-batch", "-nx", str(fixture or args.fixture),
                                 "-x", str(script)], capture_output=True, text=True,
                                encoding="utf-8", errors="replace",
                                timeout=max(0.001, min(60, args.deadline - time.monotonic())))
        transcript = client.stdout + client.stderr
        result.update(gdb_exit_code=client.returncode, seconds=time.monotonic() - start)
        result["expected_vs_actual"] = assertion_records(transcript)
        expected_count = sum(command.startswith("echo ASSERT_EXPECT ") for command in commands)
        if not refuse and len(result["expected_vs_actual"]) != expected_count:
            raise AssertionError("GDB did not execute every fixture assertion")
        if any(item["actual"] is not True for item in result["expected_vs_actual"]):
            raise AssertionError("a fixture assertion failed or has no terminal actual result")
        for text in forbidden:
            if text in transcript:
                raise AssertionError("unsupported capability advertised: " + text)
        if refuse:
            if not any(text in transcript for text in expected) or "ASSERT_FAIL" in transcript:
                raise AssertionError("reverse request did not explicitly refuse")
            result["status"] = "EXPLICIT_REFUSAL"
        else:
            if client.returncode != 0 or "ASSERT_FAIL" in transcript:
                raise AssertionError("GDB assertion or command failed")
            for text in expected:
                if text not in transcript:
                    raise AssertionError("missing client evidence: " + text)
            result["assertions"] = transcript.count("ASSERT_PASS")
            result["status"] = "PASS"
        result["cleanup"] = emulator.finish()
    except Exception as error:
        result.update(status="FAIL", error=str(error))
    finally:
        emulator.close()
        result["owned_child_reaped"] = emulator.process.poll() is not None
        (args.output / (name + ".client.log")).write_text(
            sanitize(transcript, args.repo, args.output), encoding="utf-8")
        (args.output / (name + ".emulator.log")).write_text(
            sanitize("".join(emulator.lines), args.repo, args.output), encoding="utf-8")
    return result


def run_mi(args, name, operation, oracle):
    if time.monotonic() >= args.deadline:
        return {"name": name, "status": "FAIL", "error": "overall deadline expired"}
    emulator = Emulator(args.emulator, args.fixture, deadline=args.deadline)
    result = {"name": name, "status": "FAIL"}
    transcript = ""
    try:
        emulator.ready()
        detail, transcript = operation(args.gdb, emulator, args.fixture, oracle, args.deadline)
        result.update(detail, status="PASS", cleanup=emulator.finish())
    except Exception as error:
        result["error"] = str(error)
        transcript = getattr(error, "transcript", transcript)
    finally:
        emulator.close()
        result["owned_child_reaped"] = emulator.process.poll() is not None
        (args.output / (name + ".client.log")).write_text(
            sanitize(transcript, args.repo, args.output), encoding="utf-8")
        (args.output / (name + ".emulator.log")).write_text(
            sanitize("".join(emulator.lines), args.repo, args.output), encoding="utf-8")
    return result


def validate_images(args, oracle):
    for image, record in ((args.fixture, {"sha256": oracle["fixture_sha256"]}),
                          (args.cpu1_fixture, oracle["cpu1"]),
                          (args.fault_fixture, oracle["fault"]),
                          (args.peripheral_fixture, oracle["peripheral"])):
        if hashlib.sha256(image.read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError("fixture bytes differ from oracle: " + image.name)


def execute(args):
    oracle = json.loads(args.oracle.read_text(encoding="utf-8"))
    validate_images(args, oracle)
    version = subprocess.check_output([str(args.gdb), "--version"], text=True,
                                     encoding="utf-8", errors="replace", timeout=10).splitlines()[0]
    if args.expected_gdb_version and args.expected_gdb_version not in version:
        raise ValueError("actual GDB version does not match requested pin: " + version)
    results = []
    for name, factory in (("execution", cases.execution), ("source-stack", cases.source_stack),
                          ("step-out", cases.step_out)):
        commands, expected = factory(oracle)
        results.append(run_batch(args, name, commands, expected))
    commands, expected = cases.dual(oracle)
    results.append(run_batch(args, "dual-core", commands, expected, cpu1=args.cpu1_fixture))
    commands, expected = cases.fault(oracle)
    results.append(run_batch(args, "controlled-fault", commands, expected, fixture=args.fault_fixture))
    results.append(run_mi(args, "interrupt-mi", mi.interrupt, oracle))
    results.append(run_mi(args, "request-errors-mi", mi.errors, oracle))
    results.append(peripheral.run(args, run_batch))
    results.append(loss.run(args, oracle))
    reverse = ["maintenance packet qSupported", "stepi", "stepi", "set $reverse_before = $pc", "reverse-stepi"]
    reverse += cases.check("$pc == $reverse_before", "refused_reverse_preserves_pc") + ["detach"]
    results.append(run_batch(args, "reverse-without-history", reverse,
                             ["E00", "does not support", "not supported"], refuse=True,
                             forbidden=("ReverseContinue+", "ReverseStep+")))
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.repo, text=True).strip()
    return {"status": "PASS" if all(r["status"] != "FAIL" for r in results) else "FAIL",
            "git_head": head, "gdb_version": version, "platform": sys.platform,
            "emulator_sha256": hashlib.sha256(args.emulator.read_bytes()).hexdigest(),
            "fixture_sha256": oracle["fixture_sha256"], "scenarios": results,
            "matrix": {"single_core": "tested", "dual_core": "tested", "reverse_without_history": "explicit refusal",
                       "reconnect_same_process": "unsupported: detach ends the one-client GDB server",
                       "reverse_with_history": "not advertised: debug CLI has no history binding",
                       "peripheral_read_stability": "firmware-seeded SCI FIFO and guest drain assertions"}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("emulator", "fixture", "oracle", "output", "gdb", "cpu1-fixture", "fault-fixture", "peripheral-fixture"):
        parser.add_argument("--" + option, required=True, type=Path)
    parser.add_argument("--expected-gdb-version")
    parser.add_argument("--overall-timeout", type=float, default=180)
    args = parser.parse_args()
    args.repo = Path(__file__).resolve().parents[2]
    for name in ("emulator", "fixture", "oracle", "output", "cpu1_fixture", "fault_fixture", "peripheral_fixture"):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        if args.overall_timeout <= 0 or args.overall_timeout > 240:
            raise ValueError("overall-timeout must be greater than zero and at most 240 seconds")
        args.deadline = time.monotonic() + args.overall_timeout
        args.gdb = Path(shutil.which(str(args.gdb)) or args.gdb).resolve(strict=True)
        result = execute(args)
    except Exception as error:
        result = {"status": "FAIL", "error": str(error)}
    write_json(args.output / "result.json", result)
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
