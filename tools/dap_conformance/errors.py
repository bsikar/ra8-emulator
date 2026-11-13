"""Unsupported capabilities and hostile frames have bounded, observable outcomes."""
from checks import body, disconnect, pc, start
from process import Session


def requests(settings, case):
    session = start(settings, case)
    try:
        client = session.client
        before = pc(client)
        invalid = [
            ("unknown-RA8-request", {}), ("stackTrace", {"threadId": 2}),
            ("stackTrace", {"threadId": 999}), ("scopes", {"frameId": 0}),
            ("variables", {"variablesReference": 0}),
            ("variables", {"variablesReference": 2147483648}),
            ("stackTrace", {"threadId": -1}),
            ("stackTrace", {"threadId": "1"}),
            ("stepBack", {"threadId": 1, "granularity": "instruction"}),
            ("reverseContinue", {"threadId": 1}), ("readMemory", {"memoryReference": "0x22000000", "count": 4}),
            ("stepIn", {"threadId": 1}), ("next", {"threadId": 1}),
            ("stepOut", {"threadId": 1}),
            ("stepIn", {"threadId": 1, "granularity": "statement"}),
            ("next", {"threadId": 1, "granularity": "line"}),
        ]
        for command, arguments in invalid:
            response = client.request(command, arguments, success=False)
            case.require("unsupported request has an explicit error", isinstance(response.get("message"), str) and bool(response["message"]))
            case.equal("refused request preserves PC: " + command, before, pc(client))
        bad = [{"instructionReference": hex(settings.oracle["ready"]), key: "unsupported"} for key in ("condition", "hitCondition", "logMessage")]
        points = body(client.request("setInstructionBreakpoints", {"breakpoints": bad}))["breakpoints"]
        case.equal("unsupported breakpoint options are explicitly unverified", [False] * 3, [point["verified"] for point in points])
        points = body(client.request("setInstructionBreakpoints", {"breakpoints": [{"instructionReference": "garbage"}]}))["breakpoints"]
        case.equal("invalid address is explicitly unverified", [False], [point["verified"] for point in points])
        disconnect(case, session)
    finally:
        session.close()


def malformed(settings, case, packet):
    with Session(settings, case) as session:
        client = session.client
        client.timeout_at()
        case.record("malformed_client_frame", ascii=packet.decode("ascii", errors="backslashreplace"))
        client.socket.sendall(packet)
        client.expect_eof()
        result = session.wait_exit(expected=None)
        case.equal("malformed input returns a controlled error exit", 1, result)


def eof_at_entry(settings, case):
    session = start(settings, case)
    try:
        session.client.close()
        session.client = None
        session.wait_exit(0)
    finally:
        session.close()


def uri_path(settings, case):
    with Session(settings, case) as session:
        result = session.client.request("initialize", {"pathFormat": "uri"}, success=False)
        case.equal("URI paths explicitly refused", "UnsupportedPathFormat", result.get("message"))
        session.client.close()
        session.client = None
        session.wait_exit(0)
