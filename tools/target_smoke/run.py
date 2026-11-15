"""Configured target selection through real CLI/RPC; all providers are loopback fixtures."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

from probe import Probe

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "workspace_smoke"))
from server import Server


def call(emulator, port, words, trace):
    result = subprocess.run([str(emulator), "ctl", "--connect", f"tcp:127.0.0.1:{port}",
                             "--json", "targets", *words], capture_output=True, timeout=15)
    assert len(result.stdout) <= 1_048_576 and len(result.stderr) <= 65536
    rows = [json.loads(line) for line in result.stdout.splitlines()]
    trace(dict(type="cli", arguments=words, exit=result.returncode, result=rows,
               stderr=result.stderr.decode(errors="replace")))
    return result.returncode, rows


def exercise(emulator, fixture, output, trace, timeout):
    providers = [Probe(name) for name in ("a", "b", "c")]
    a, b, c = providers
    server = None
    deadline = time.monotonic() + timeout

    def start(bindings, name):
        path = output / (name + "-bindings.json")
        path.write_text(json.dumps(bindings), encoding="utf8")
        return Server(emulator, fixture, None, output / (name + "-server.log"), trace, deadline,
                      lambda text: text, options=("--targets", path))

    def invoke(words):
        assert time.monotonic() < deadline, "overall target acceptance deadline"
        return call(emulator, server.port, words, trace)

    def use(generation, name, disambiguation):
        return invoke(["use", "fixture-host", "probe-" + name, "board-" + name,
                       str(generation), disambiguation, "registers"])

    try:
        bindings = [a.binding(), b.binding(), c.binding(managed=True)]
        server = start(bindings, "initial")
        code, rows = invoke(["list"])
        assert code == 0 and len(rows[0]) == 3
        generation = {row["target"]["board_id"]: row["generation"] for row in rows[0]}
        code, rows = use(generation["board-b"], "b", "-")
        assert code == 1 and rows[0]["code"] == 0x192, "ambiguous binding refused"
        code, rows = use(generation["board-b"], "b", "binding-b")
        assert code == 0 and rows[0]["registers_rsp"] == "01020304"
        assert len(a.calls) == 0 and len(b.calls) == 1 and len(c.calls) == 0
        code, rows = use(generation["board-c"], "c", "binding-c")
        assert code == 1 and rows[0]["code"] == 0x196, "managed bench fails closed"
        assert server.close()["exit_code"] == 0
        server = None
        server = start(list(reversed(bindings)), "reordered")
        code, rows = use(generation["board-b"], "b", "binding-b")
        assert code == 1 and rows[0]["code"] == 0x191, "old generation refused"
        code, rows = invoke(["list"])
        assert code == 0
        current = {row["target"]["board_id"]: row["generation"] for row in rows[0]}
        code, rows = use(current["board-b"], "b", "binding-b")
        assert code == 0 and rows[0]["registers_rsp"] == "01020304"
        assert len(a.calls) == 0 and len(b.calls) == 2 and len(c.calls) == 0
        b.close()
        code, _ = use(current["board-b"], "b", "binding-b")
        assert code == 1
        code, rows = invoke(["list"])
        assert code == 0
        lost = next(row for row in rows[0] if row["target"]["board_id"] == "board-b")
        assert lost["target"]["connection"] == "disconnected" and not lost["reserved"]
        return dict(status="passed", provider_calls={p.name: len(p.calls) for p in providers},
                    physical_hardware=False, custodian_integration=False)
    finally:
        if server is not None:
            assert server.close()["exit_code"] == 0
        for provider in providers:
            provider.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    result = dict(status="failed", physical_hardware=False)
    with (args.output / "transcript.jsonl").open("w", encoding="utf8") as transcript:
        def trace(event):
            transcript.write(json.dumps(event) + "\n")
            transcript.flush()
        try:
            result = exercise(args.emulator.resolve(), args.fixture.resolve(), args.output, trace, args.timeout)
        finally:
            (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf8")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
