"""Fixture-oracle assertions shared by public DAP scenarios."""
from process import Session


def body(message):
    return message.get("body", {})


def stack(client):
    return body(client.request("stackTrace", {"threadId": 1}))["stackFrames"]


def pc(client):
    return int(stack(client)[0]["instructionPointerReference"], 0)


def registers(client):
    frame = stack(client)[0]
    scopes = body(client.request("scopes", {"frameId": frame["id"]}))["scopes"]
    scope = next(scope for scope in scopes if scope["name"] == "Registers")
    variables = body(client.request("variables", {"variablesReference": scope["variablesReference"]}))["variables"]
    return {item["name"]: int(item["value"], 0) for item in variables}, frame["id"], scope["variablesReference"]


def start(settings, case, mode="launch"):
    session = Session(settings, case, mode)
    session.__enter__()
    try:
        client = session.client
        initialized = client.request("initialize", {"adapterID": "ra8-e2e-é", "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path"}, fragment=3)
        capabilities = body(initialized)
        case.equal("configuration capability", True, capabilities.get("supportsConfigurationDoneRequest"))
        case.equal("instruction breakpoint capability", True, capabilities.get("supportsInstructionBreakpoints"))
        case.equal("reverse capability is absent or false", False, capabilities.get("supportsStepBack", False))
        case.equal("memory-read capability is absent or false", False, capabilities.get("supportsReadMemoryRequest", False))
        connected = client.request(mode, {"program": str(settings.fixture)} if mode == "launch" else {})
        event = client.event("initialized")
        case.require("initialized follows initialize and target creation", initialized["seq"] < connected["seq"] < event["seq"])
        case.equal("initialized event body is an object", True, isinstance(event.get("body", {}), dict))
        configured = client.request("configurationDone")
        stopped = client.event("stopped")
        case.require("entry stop follows configuration response", configured["seq"] < stopped["seq"])
        case.equal("entry stop reason", "entry", body(stopped).get("reason"))
        case.equal("entry stopped thread", 1, body(stopped).get("threadId"))
        case.equal("entry PC matches fixture entry", settings.oracle["entry"], pc(client))
        return session
    except BaseException:
        session.close()
        raise


def breakpoints(client, addresses):
    points = [{"instructionReference": hex(address)} for address in addresses]
    return body(client.request("setInstructionBreakpoints", {"breakpoints": points}))["breakpoints"]


def run_to(settings, case, client, address):
    points = breakpoints(client, [address])
    case.equal("instruction breakpoint verified", [True], [point.get("verified") for point in points])
    response = client.request("continue", {"threadId": 1})
    event = client.event("stopped")
    case.require("break stop follows continue response", response["seq"] < event["seq"])
    case.equal("instruction breakpoint stop reason", "instruction breakpoint", body(event).get("reason"))
    case.equal("instruction breakpoint stopped PC", address, pc(client))


def step(case, client, command, expected_pc):
    breakpoints(client, [])
    response = client.request(command, {"threadId": 1, "granularity": "instruction"})
    event = client.event("stopped")
    case.require("step stop follows response", response["seq"] < event["seq"])
    case.equal(command + " stop reason", "step", body(event).get("reason"))
    case.equal(command + " stopped PC", expected_pc, pc(client))


def disconnect(case, session):
    response = session.client.request("disconnect")
    event = session.client.event("terminated")
    case.require("terminated follows disconnect response", response["seq"] < event["seq"])
    session.wait_exit(0)
