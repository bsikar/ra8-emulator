"""Public real-compiler build scenarios; all mutations target the owned workspace."""
import hashlib
import json
import os
from pathlib import Path
import socket
import time

from protocol import Client
from fixture import SOURCE, revision


def success(h):
    before = revision(h.root)
    job = h.client.start()
    result = h.client.finish(job)
    h.check("compiler succeeds", result["state"], "succeeded")
    h.check("successful compiler exit", result["exit_code"], 0)
    h.check("compiler tree cleanup", result["cleanup"], "complete")
    h.check("compiler provenance", Path(result["compiler"]), h.zig)
    h.check("compiler version provenance", result["compiler_version"], h.zig_version)
    actual_host, expected_host = result["host"], socket.gethostname()
    if os.name == "nt":
        actual_host, expected_host = actual_host.casefold(), expected_host.casefold()
    h.check("independent host identity", actual_host, expected_host)
    h.check("independent input content digest", result["source_sha256"], before)
    expected = [str(h.zig), "build", "-j1", "--color=off", "--prefix", result["directory"] + "/out"]
    h.check("exact compiler argv", result["argv"], expected)
    relative = Path(result["artifact"])
    h.check("unique artifact under job prefix", relative.parts[:2], Path(result["directory"]).parts)
    h.check("job directory under build store", relative.parts[0], ".ra8-builds")
    h.check("artifact remains relative", relative.is_absolute(), False)
    artifact = h.root / relative
    data = artifact.read_bytes()
    h.check("actual ELF magic", data[:4], b"\x7fELF")
    h.check("actual ARM ELF machine", int.from_bytes(data[18:20], "little"), 40)
    h.check("artifact SHA256 independently matches", hashlib.sha256(data).hexdigest(), result["artifact_sha256"])
    h.check("retained terminal result", json.loads((h.root / result["directory"] / "result.json").read_text()), result)
    for log in ("stdout.log", "stderr.log"):
        h.check("retained " + log, (h.root / result["directory"] / log).is_file(), True)
    if hasattr(h, "prior_artifact"):
        h.check("repeat artifact path unique", artifact != h.prior_artifact, True)
        h.check("prior artifact preserved", h.prior_artifact.read_bytes(), h.prior_bytes)
    else:
        h.prior_artifact, h.prior_bytes = artifact, data


def failed(h, result, failure=None, cleanup=True):
    h.check("failed terminal state", result["state"], "failed")
    h.check("failed job publishes no artifact", result["artifact"], "")
    if failure:
        h.check("exact failure cause", result["failure"], failure)
    if cleanup:
        h.check("failed build tree cleanup", result["cleanup"], "complete")
    h.check("previous ELF preserved after failure", h.prior_artifact.read_bytes(), h.prior_bytes)


def syntax_error(h):
    (h.root / "main.zig").write_text("export fn Reset_Handler() noreturn {\n    const broken = ;\n}\n")
    try:
        job = h.client.start()
        result = h.client.finish(job)
        failed(h, result, "CompilerFailed")
        h.check("syntax error compiler exit nonzero", result["exit_code"] != 0, True)
        outputs = h.client.outputs[job]
        h.check("compiler stderr streamed", any(e["kind"] == 1 for e in outputs), True)
        diagnostics = [e["value"] for e in outputs if e["kind"] == 2]
        expected = [d for d in diagnostics if d["path"] == "main.zig" and d["line"] == 2]
        h.check("structured relative diagnostic at known line", bool(expected), True)
        h.check("diagnostic points to missing expression token", expected[0]["column"], 20)
        h.check("diagnostic carries compiler message", expected[0]["message"], "error: expected expression, found ';'")
        h.check("workspace diagnostic not marked external", expected[0]["external"], False)
    finally:
        (h.root / "main.zig").write_text(SOURCE)


def ready(h, tag, timeout=40):
    deadline = min(h.deadline, time.monotonic() + timeout)
    while time.monotonic() < deadline:
        if (h.root / ".ra8-builds" / (tag + ".ready")).exists():
            return
        done, result = h.client.status(h.active)
        if done:
            raise AssertionError(("job exited before helper ready", result))
        time.sleep(0.05)
    raise TimeoutError("fixture helper readiness deadline")


def marker_absent(h, tag):
    deadline = time.monotonic() + 5.5
    if deadline > h.deadline:
        raise TimeoutError("insufficient overall budget for descendant cleanup proof")
    while time.monotonic() < deadline:
        h.check("owned descendant cannot write delayed marker", (h.root / ".ra8-builds" / (tag + ".delayed")).exists(), False)
        time.sleep(0.2)


def cancel_and_ownership(h):
    h.active = h.client.start("long", ["-Dtag=cancel"], "")
    ready(h, "cancel")
    h.check("active status remains responsive", h.client.status(h.active)[0], False)
    h.client.start(error=0x161)
    h.client.status(h.active + 500, error=0x162)
    h.client.cancel(h.active + 500, error=0x162)
    h.client.cancel(h.active)
    result = h.client.finish(h.active)
    h.check("explicit cancel terminal state", result["state"], "canceled")
    h.check("cancel cleanup complete", result["cleanup"], "complete")
    h.check("cancel publishes no ELF", result["artifact"], "")
    marker_absent(h, "cancel")


def disconnect(h):
    h.active = h.client.start("long", ["-Dtag=disconnect"], "")
    ready(h, "disconnect")
    old = h.active
    h.client.close()
    h.client = Client(h.server.port, h.trace, h.deadline)
    h.client.status(old, error=0x162)
    marker_absent(h, "disconnect")
    records = [json.loads(p.read_text()) for p in (h.root / ".ra8-builds").glob("*/result.json")]
    record = next(r for r in records if r["id"] == old)
    h.check("disconnect cancels owned job", record["state"], "canceled")
    h.check("disconnect cleanup retained", record["cleanup"], "complete")
    success(h)


def recipes(h):
    for kwargs in (dict(step="--help"), dict(step="../bad"), dict(options=["--prefix=outside"]),
                   dict(options="{}"), dict(artifact="../outside"), dict(artifact="C:/outside"),
                   dict(artifact="\\\\server\\share"), dict(timeout_ms=99)):
        h.client.start(**kwargs, error=2)
    fallback = h.root / "zig-out" / "bin" / "does-not-exist.elf"
    fallback.parent.mkdir(parents=True, exist_ok=True)
    fallback.write_bytes(h.prior_bytes)
    job = h.client.start(artifact="bin/does-not-exist.elf")
    failed(h, h.client.finish(job))
    h.check("preexisting zig-out ELF never used as fallback", fallback.read_bytes(), h.prior_bytes)
    job = h.client.start("long", ["-Dtag=timeout"], "", timeout_ms=2000)
    result = h.client.finish(job)
    failed(h, result, "BuildTimeout")
    marker_absent(h, "timeout")


def source_changed(h):
    h.active = h.client.start("delay", ["-Dtag=mutation"])
    ready(h, "mutation")
    (h.root / "main.zig").write_text(SOURCE + "// changed while compiler running\n")
    try:
        result = h.client.finish(h.active)
        failed(h, result, "SourceChanged")
        h.check("changed source compiler itself succeeded", result["exit_code"], 0)
    finally:
        (h.root / "main.zig").write_text(SOURCE)


def stream(h):
    job = h.client.start("flood", artifact="")
    result = h.client.finish(job)
    h.check("output-heavy build succeeds", result["state"], "succeeded")
    events = h.client.outputs[job]
    h.check("actual stdout was streamed", any(e["kind"] == 0 for e in events), True)
    h.check("stream truncation explicit boolean", isinstance(result["stream_truncated"], bool), True)
    size = (h.root / result["directory"] / "stdout.log").stat().st_size
    h.check("retained output includes bounded megabyte", 1_000_000 <= size <= 16 * 1024 * 1024, True)


def output_limit(h):
    job = h.client.start("limit", artifact="", timeout_ms=180000)
    result = h.client.finish(job, timeout=180)
    failed(h, result, "OutputLimit")
    directory = h.root / result["directory"]
    size = sum((directory / name).stat().st_size for name in ("stdout.log", "stderr.log"))
    h.check("output-limit retained logs remain within sixteen MiB", 0 < size <= 16 * 1024 * 1024, True)
    h.check("output limit reached by actual output", size >= 16 * 1024 * 1024 - 4096, True)


CASES = (success, success, syntax_error, cancel_and_ownership, disconnect, recipes, source_changed, stream, output_limit)
