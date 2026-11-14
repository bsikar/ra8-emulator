"""Public source-directory regression shared by fresh-project consumers."""
from pathlib import Path
import sys
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/dap_conformance"))
from process import Session
from checks import body, disconnect, pc, registers, stack
sys.path.insert(0, str(ROOT / "tools/gdb_conformance"))
from oracle import generate


class BoundedSession(Session):
    @staticmethod
    def _drain(stream, target, lines):
        captured, count = 0, 0
        for line in iter(lambda: stream.readline(4096), ""):
            if captured < 1_000_000:
                target.append(line[:1_000_000-captured])
                captured += len(line)
            if lines is not None and count < 128:
                lines.put(line)
                count += 1


def run(emulator, elf, source, case, deadline):
    oracle = generate(elf, source)
    case.record("oracle", value=oracle)
    settings = SimpleNamespace(emulator=emulator, fixture=elf, deadline=deadline,
                               startup_timeout=15, request_timeout=5)
    with BoundedSession(settings, case) as session:
        client = session.client
        client.request("initialize", {"adapterID": "source-directory-regression", "pathFormat": "path"})
        client.request("launch", {"program": str(elf), "stopOnEntry": True})
        client.event("initialized")
        client.request("configurationDone")
        client.event("stopped")
        case.equal("fixture entry PC", oracle["entry"], pc(client))
        points = body(client.request("setInstructionBreakpoints", {"breakpoints": [
            {"instructionReference": hex(oracle["ready"])}]}))["breakpoints"]
        case.equal("instruction ready breakpoint verified", [True], [p["verified"] for p in points])
        client.request("continue", {"threadId": 1})
        client.event("stopped")
        values, _, _ = registers(client)
        for name, value in oracle["ready_registers"].items():
            case.equal("known fixture register " + name, value, values[name])
        client.request("setInstructionBreakpoints", {"breakpoints": []})
        wrong = source.parent.parent / "wrong absolute root" / source.name
        points = body(client.request("setBreakpoints", {"source": {"path": str(wrong)},
            "breakpoints": [{"line": oracle["source"]["line"]}]}))["breakpoints"]
        case.equal("wrong-root same-basename absolute source is unverified", [False], [p["verified"] for p in points])
        points = body(client.request("setBreakpoints", {"source": {"path": str(source)},
            "breakpoints": [{"line": oracle["source"]["line"]}]}))["breakpoints"]
        case.equal("correct absolute source breakpoint verified", [True], [p["verified"] for p in points])
        client.request("continue", {"threadId": 1})
        event = client.event("stopped")
        case.equal("source breakpoint stop reason", "breakpoint", body(event)["reason"])
        frame = stack(client)[0]
        case.record("stopped_source_frame", frame=frame)
        case.equal("source stack line", oracle["source"]["line"], frame["line"])
        case.equal("source stack address", oracle["source"]["address"], int(frame["instructionPointerReference"], 0))
        case.equal("source stack absolute path", source.resolve(), Path(frame["source"]["path"]).resolve())
        disconnect(case, session)
    case.equal("one owned DAP backend", 1, len(case.result["processes"]))
    process = case.result["processes"][0]
    case.require("owned DAP backend exited zero and reaped", process["exit_status"] == 0 and process["reaped"]
                 and not process["forced_cleanup"] and process["listener_closed"])
