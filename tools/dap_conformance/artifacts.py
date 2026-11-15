"""Sanitized, finite conformance evidence; no debugger implementation."""
import hashlib
import json
import time
from pathlib import Path


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Evidence:
    def __init__(self, directory, replacements):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.replacements = sorted(replacements, key=lambda pair: -len(pair[0]))
        self.started = time.monotonic()
        self.cases = []

    def clean(self, value):
        if isinstance(value, dict):
            return {key: self.clean(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.clean(item) for item in value]
        if isinstance(value, str):
            for original, replacement in self.replacements:
                value = value.replace(original, replacement)
                value = value.replace(original.replace("\\", "/"), replacement)
            return value
        return value

    def case(self, name):
        result = Case(self, name)
        self.cases.append(result.result)
        return result

    def write_json(self, name, value):
        (self.directory / name).write_text(
            json.dumps(self.clean(value), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


class Case:
    def __init__(self, evidence, name):
        self.evidence = evidence
        self.name = name
        self.result = {"name": name, "status": "RUNNING", "assertions": [], "processes": []}
        self.path = evidence.directory / (name + ".jsonl")
        self.stream = self.path.open("w", encoding="utf-8")

    def record(self, kind, **details):
        value = {"kind": kind, "elapsed_seconds": round(time.monotonic() - self.evidence.started, 6), **details}
        self.stream.write(json.dumps(self.evidence.clean(value), sort_keys=True) + "\n")
        self.stream.flush()

    def equal(self, name, expected, actual):
        success = expected == actual
        assertion = {"name": name, "expected": expected, "actual": actual, "status": "PASS" if success else "FAIL"}
        self.result["assertions"].append(self.evidence.clean(assertion))
        self.record("assertion", **assertion)
        if not success:
            raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")

    def require(self, name, condition, actual=None):
        self.equal(name, True, bool(condition))
        if actual is not None:
            self.record("observation", name=name, actual=actual)

    def finish(self, error=None):
        self.result["status"] = "FAIL" if error is not None else "PASS"
        if error is not None:
            self.result["error"] = self.evidence.clean(f"{type(error).__name__}: {error}")
        self.record("terminal", status=self.result["status"], error=self.result.get("error"))
        self.stream.close()
