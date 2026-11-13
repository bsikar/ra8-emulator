"""Source, stack and value assertions use the independently generated fixture oracle."""
from pathlib import Path

from checks import body, breakpoints, disconnect, pc, registers, stack, start


def source_points(settings, client):
    source = settings.oracle["source"]
    result = body(client.request("setBreakpoints", {"source": {"path": source["path"]}, "breakpoints": [{"line": source["line"]}]}))["breakpoints"]
    return result


def clear_source(settings, client):
    client.request("setBreakpoints", {"source": {"path": settings.oracle["source"]["path"]}, "breakpoints": []})


def source_and_frames(settings, case):
    session = start(settings, case)
    try:
        client = session.client
        result = source_points(settings, client)
        case.equal("source breakpoint verified", [True], [point.get("verified") for point in result])
        client.request("continue", {"threadId": 1})
        stopped = client.event("stopped")
        case.equal("source break stop reason", "breakpoint", body(stopped).get("reason"))
        frames = stack(client)
        case.equal("source breakpoint PC from independent line table", settings.oracle["source"]["address"], int(frames[0]["instructionPointerReference"], 0))
        case.equal("source file", "machine.zig", Path(frames[0]["source"]["path"]).name)
        case.equal("source line", settings.oracle["source"]["line"], frames[0]["line"])
        names = [frame["name"] for frame in frames]
        case.require("top source frame names fixture inner function", "nested_inner" in names[0], names)
        case.require("call chain includes fixture outer function", any("nested_outer" in name for name in names[1:]), names)
        scopes = body(client.request("scopes", {"frameId": frames[0]["id"]}))["scopes"]
        local_scope = next(scope for scope in scopes if scope["name"] == "Locals")
        locals_ = body(client.request("variables", {"variablesReference": local_scope["variablesReference"]}))["variables"]
        known = {"value": 35, "local": 42}
        case.require("fixture locals are enumerated", all(any(item["name"] == name for item in locals_) for name in known), locals_)
        for variable in locals_:
            if variable["name"] in known:
                value = variable["value"]
                actual = "<unavailable>" if value == "<unavailable>" else int(value, 0)
                case.require("local is correct or explicitly unavailable: " + variable["name"], actual in (known[variable["name"]], "<unavailable>"), actual)
        repeated = body(client.request("variables", {"variablesReference": local_scope["variablesReference"]}))["variables"]
        case.equal("repeated locals reads preserve values and machine state", locals_, repeated)
        case.equal("locals inspection preserves stopped PC", settings.oracle["source"]["address"], pc(client))
        if len(frames) > 1:
            caller = body(client.request("scopes", {"frameId": frames[1]["id"]}))["scopes"]
            case.equal("unsupported caller scopes do not fabricate live-frame values", [], caller)
        disconnect(case, session)
    finally:
        session.close()


def independent_groups(settings, case):
    session = start(settings, case)
    try:
        client = session.client
        case.equal("source group installs", [True], [point["verified"] for point in source_points(settings, client)])
        address = settings.oracle["next"]["small_call"]
        case.equal("instruction group installs", [True], [point["verified"] for point in breakpoints(client, [address])])
        clear_source(settings, client)
        client.request("continue", {"threadId": 1})
        client.event("stopped")
        case.equal("source replacement preserves instruction-owned break", address, pc(client))
        case.equal("source group reinstalls", [True], [point["verified"] for point in source_points(settings, client)])
        breakpoints(client, [])
        client.request("continue", {"threadId": 1})
        client.event("stopped")
        case.equal("instruction replacement preserves source-owned break", settings.oracle["source"]["address"], pc(client))
        disconnect(case, session)
    finally:
        session.close()
