"""Public execution scenarios assert independent fixture locations and values."""
import time

from checks import body, breakpoints, disconnect, pc, registers, run_to, stack, start, step
from process import Session


def lifecycle(settings, case, mode):
    session = start(settings, case, mode)
    try:
        client = session.client
        requests = client.coalesced([("threads", None), ("stackTrace", {"threadId": 1})])
        threads = body(client.response(requests[0]))["threads"]
        case.equal("public DAP exposes only CPU0", [{"id": 1, "name": "CPU0"}], threads)
        frames = body(client.response(requests[1]))["stackFrames"]
        case.equal("coalesced stack request preserves entry PC", settings.oracle["entry"], int(frames[0]["instructionPointerReference"], 0))
        disconnect(case, session)
    finally:
        session.close()


def automatic_launch(settings, case):
    with Session(settings, case) as session:
        client = session.client
        client.request("initialize", {"adapterID": "ra8-e2e", "pathFormat": "path"})
        client.request("launch", {"program": str(settings.fixture), "stopOnEntry": False})
        client.event("initialized")
        address = settings.oracle["ready"]
        points = breakpoints(client, [address])
        case.equal("pre-configuration instruction break installs", [True], [point["verified"] for point in points])
        case.equal("launch does not execute before configurationDone", settings.oracle["entry"], pc(client))
        response = client.request("configurationDone")
        event = client.event("stopped")
        case.require("automatic execution stop follows configuration response", response["seq"] < event["seq"])
        case.equal("stopOnEntry false reaches configured breakpoint", "instruction breakpoint", body(event).get("reason"))
        case.equal("automatic launch fixture PC", address, pc(client))
        disconnect(case, session)


def known_state(settings, case):
    session = start(settings, case)
    try:
        client = session.client
        run_to(settings, case, client, settings.oracle["ready"])
        first, frame, reference = registers(client)
        for name, value in settings.oracle["ready_registers"].items():
            case.equal("fixture ready register " + name, value, first[name])
        second, _, _ = registers(client)
        case.equal("repeated register and stack inspection does not advance state", first, second)
        step(case, client, "stepIn", settings.oracle["ready"] + settings.oracle["values"]["small_step_bytes"])
        client.request("scopes", {"frameId": frame}, success=False)
        client.request("variables", {"variablesReference": reference}, success=False)
        disconnect(case, session)
    finally:
        session.close()


def calls(settings, case):
    session = start(settings, case)
    try:
        client = session.client
        oracle = settings.oracle
        run_to(settings, case, client, oracle["next"]["small_call"])
        step(case, client, "next", oracle["next"]["small_return"])
        run_to(settings, case, client, oracle["next"]["long_call"])
        step(case, client, "next", oracle["next"]["long_return"])
        values, _, _ = registers(client)
        case.equal("long callee completed all fixture iterations", 0, values["r2"])
        case.require("fixture long callee exceeds one execution slice", oracle["values"]["long_iterations"] * 2 > 20_000)
        disconnect(case, session)
    finally:
        session.close()


def step_out(settings, case):
    session = start(settings, case)
    try:
        client = session.client
        oracle = settings.oracle
        run_to(settings, case, client, oracle["next"]["small_call"])
        step(case, client, "stepIn", oracle["symbols"]["small_callee"])
        step(case, client, "stepOut", oracle["next"]["small_return"])
        disconnect(case, session)
    finally:
        session.close()


def pause_loop(settings, case, loss=False):
    session = start(settings, case)
    try:
        client = session.client
        address = settings.oracle["symbols"]["breakpoint_loop"]
        run_to(settings, case, client, address)
        breakpoints(client, [])
        client.request("continue", {"threadId": 1})
        if loss:
            client.close()
            session.client = None
            session.wait_exit(0)
            return
        began = time.perf_counter()
        client.timeout = min(client.timeout, settings.pause_timeout)
        client.request("pause", {"threadId": 1})
        stopped = client.event("stopped", settings.pause_timeout)
        elapsed = time.perf_counter() - began
        case.equal("pause stop reason", "pause", body(stopped).get("reason"))
        case.require("infinite loop interrupt meets deadline", elapsed <= settings.pause_timeout, {"elapsed_seconds": elapsed, "deadline_seconds": settings.pause_timeout})
        case.require("pause PC remains in fixture loop", pc(client) in (address, address + 2))
        disconnect(case, session)
    finally:
        session.close()


def continue_current_breakpoint(settings, case):
    session = start(settings, case)
    try:
        client = session.client
        address = settings.oracle["symbols"]["breakpoint_loop"]
        run_to(settings, case, client, address)
        client.request("continue", {"threadId": 1})
        event = client.event("stopped")
        case.equal("loop break is hit on next arrival", "instruction breakpoint", body(event).get("reason"))
        case.equal("continue passes current break and lands on next loop arrival", address, pc(client))
        disconnect(case, session)
    finally:
        session.close()


def fault(settings, case):
    session = start(settings, case)
    try:
        client = session.client
        client.request("continue", {"threadId": 1})
        event = client.event("stopped")
        case.equal("controlled fault stop reason", "exception", body(event).get("reason"))
        case.equal("controlled fault PC", settings.oracle["symbols"]["controlled_fault"], pc(client))
        disconnect(case, session)
    finally:
        session.close()
