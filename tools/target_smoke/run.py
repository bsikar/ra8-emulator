"""Configured target selection through real CLI/RPC; all providers are loopback fixtures."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

from agent import AgentProcess
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
    providers = [Probe(name) for name in ("a", "b", "c", "d")]
    a, b, c, d = providers
    server = None
    agent_proc = None
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
        matrix_run = subprocess.run([str(emulator), "probe-agent", "--matrix"],
                                    capture_output=True, text=True, timeout=15)
        assert matrix_run.returncode == 0
        matrix = json.loads(matrix_run.stdout)
        assert matrix["emulated_usbip_distinct"] is True
        entries = matrix["entries"]
        assert any(e["probe_os"] == "windows" and e["fallback_used"] and e["chosen"] == "native_agent"
                   for e in entries)
        assert any(e["probe"] == "bootloader_serial" and not e["supported"] for e in entries)
        trace(dict(type="matrix", count=len(entries)))

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
        assert server.close()["exit_code"] == 0
        server = None

        secret = output / "agent.key"
        wrong = output / "wrong.key"
        secret.write_text("42" * 32 + "\n", encoding="utf8")
        wrong.write_text("99" * 32 + "\n", encoding="utf8")
        agent_targets = output / "agent-local.json"
        local_binding = d.binding()
        local_binding["target"]["host_id"] = "agent-host"
        agent_targets.write_text(json.dumps([local_binding]), encoding="utf8")
        agent_proc = AgentProcess(emulator, agent_targets, secret, "agent-host",
                                  output / "agent-1.log", trace, deadline)
        agent_port = agent_proc.port
        bad_binding = dict(kind="agent", host="127.0.0.1", port=agent_port,
                           secret_file=str(wrong.resolve()), target=dict(
                               host_id="agent-host", probe_id="probe-d", board_id="board-d",
                               transport="rsp", managed=False, disambiguation="binding-d"))
        server = start([bad_binding], "agent-bad-secret")
        code, rows = invoke(["list"])
        assert code == 0 and rows[0] == [], "wrong probe-host secret must fail closed"
        assert server.close()["exit_code"] == 0
        server = None

        good_binding = dict(bad_binding, secret_file=str(secret.resolve()))
        server = start([good_binding], "agent-good")
        code, rows = invoke(["list"])
        assert code == 0 and len(rows[0]) == 1
        gen_d = rows[0][0]["generation"]
        code, rows = invoke(["use", "agent-host", "probe-d", "board-d", str(gen_d), "binding-d", "registers"])
        assert code == 0 and rows[0]["registers_rsp"] == "01020304" and len(d.calls) == 1
        agent_proc.close()
        agent_proc = None
        code, rows = invoke(["list"])
        assert code == 0 and rows[0] == [], "agent disconnect removes host bindings"
        agent_proc = AgentProcess(emulator, agent_targets, secret, "agent-host",
                                  output / "agent-2.log", trace, deadline, port=agent_port)
        code, rows = invoke(["use", "agent-host", "probe-d", "board-d", str(gen_d), "binding-d", "registers"])
        assert code == 1 and rows[0]["code"] == 0x191, "reconnect invalidates old generation"
        code, rows = invoke(["list"])
        assert code == 0 and len(rows[0]) == 1 and rows[0][0]["generation"] != gen_d
        gen_d2 = rows[0][0]["generation"]
        code, rows = invoke(["use", "agent-host", "probe-d", "board-d", str(gen_d2), "binding-d", "registers"])
        assert code == 0 and len(d.calls) == 2
        assert server.close()["exit_code"] == 0
        server = None
        agent_proc.close()
        agent_proc = None

        hosts_file = output / "hosts"
        hosts_file.write_text("local stdio-agent\n", encoding="utf8")
        stdio_binding = dict(kind="agent", profile="stdio-agent",
                             hosts_file=str(hosts_file.resolve()),
                             remote_targets=str(agent_targets.resolve()),
                             secret_file=str(secret.resolve()),
                             target=dict(host_id="agent-host", probe_id="probe-d", board_id="board-d",
                                         transport="rsp", managed=False, disambiguation="binding-d"))
        server = start([stdio_binding], "agent-stdio")
        code, rows = invoke(["list"])
        assert code == 0 and len(rows[0]) == 1
        gen_d3 = rows[0][0]["generation"]
        code, rows = invoke(["use", "agent-host", "probe-d", "board-d", str(gen_d3), "binding-d", "registers"])
        assert code == 0 and rows[0]["registers_rsp"] == "01020304" and len(d.calls) == 3
        return dict(status="passed", provider_calls={p.name: len(p.calls) for p in providers},
                    authenticated_probe_host=True, stdio_profile_agent=True,
                    physical_hardware=False, custodian_integration=False)
    finally:
        if server is not None:
            assert server.close()["exit_code"] == 0
        if agent_proc is not None:
            agent_proc.close()
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
