"""Public plan and fresh verified compiler acceptance; no production provisioning."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import time
import traceback
from types import SimpleNamespace

import archive
import plans
import build_debug


class Harness:
    def __init__(self, emulator, output, timeout):
        self.emulator, self.output = emulator, output
        self.deadline, self.assertions = time.monotonic() + timeout, 0
        self.processes, self.commands, self.command_index = [], [], 0
        self.transcript = (output / "transcript.jsonl").open("w", encoding="utf8")
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.upper().startswith(("ZIG", "CC", "CXX", "GDB")):
                self.env.pop(key)
        empty_path = output / "empty executable search path"
        empty_path.mkdir()
        self.env["PATH"] = str(empty_path)

    def clean(self, value):
        if isinstance(value, dict):
            return {key: self.clean(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.clean(item) for item in value]
        if isinstance(value, bytes):
            return dict(bytes=len(value), sha256=hashlib.sha256(value).hexdigest(), preview=value[:32].hex())
        if isinstance(value, (str, Path)):
            text = str(value)
            for root, label in ((self.output, "<EVIDENCE>"), (build_debug.REPO, "<REPO>"), (Path.home(), "<HOME>")):
                pattern = r"(?:\\+|/+)".join(re.escape(part) for part in re.split(r"[\\/]+", str(root)))
                text = re.sub(pattern, lambda _: label, text, flags=re.I if os.name == "nt" else 0)
            return text
        return value

    def record(self, event, **values):
        self.transcript.write(json.dumps(self.clean(dict(type=event, **values)), ensure_ascii=False) + "\n")
        self.transcript.flush()

    def equal(self, name, actual, expected):
        self.assertions += 1
        self.record("assertion", name=name, actual=actual, expected=expected, passed=actual == expected)
        if actual != expected:
            raise AssertionError(self.clean(f"{name}: actual={actual!r}, expected={expected!r}"))

    def require(self, name, condition, detail=None):
        self.equal(name, bool(condition), True)

    def command(self, argv, cwd=None, timeout=15):
        self.command_index += 1
        stdout_path = self.output / f"command-{self.command_index:03d}.stdout.log"
        stderr_path = self.output / f"command-{self.command_index:03d}.stderr.log"
        budget = min(timeout, self.deadline - time.monotonic())
        if budget <= 0:
            raise TimeoutError("overall deadline before command")
        self.record("command_start", argv=argv, cwd=cwd, path=self.env["PATH"])
        forced = False
        with stdout_path.open("xb") as out, stderr_path.open("xb") as err:
            process = subprocess.Popen(argv, cwd=cwd, env=self.env, stdin=subprocess.DEVNULL,
                                       stdout=out, stderr=err, start_new_session=os.name != "nt")
            try:
                process.wait(timeout=budget)
            except subprocess.TimeoutExpired:
                forced = True
                if os.name == "nt":
                    taskkill = Path(os.environ["SystemRoot"]) / "System32/taskkill.exe"
                    subprocess.run([str(taskkill), "/PID", str(process.pid), "/T", "/F"],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.kill()
                process.wait(timeout=5)
        state = dict(argv=argv, exit_status=process.returncode, forced_cleanup=forced,
                     reaped=process.poll() is not None)
        self.commands.append(state)
        self.record("command_exit", **state)
        text = []
        for path in (stdout_path, stderr_path):
            if path.stat().st_size > 2_000_000:
                raise AssertionError("subprocess evidence exceeds output bound")
            value = path.read_text(encoding="utf8", errors="replace")
            path.write_text(self.clean(value), encoding="utf8")
            text.append(value)
        if forced:
            raise TimeoutError("owned command deadline; forced cleanup is a failure")
        return SimpleNamespace(returncode=process.returncode, stdout=text[0], stderr=text[1])


def compiler(h, args, host):
    pin = archive.PINS[host]
    path = args.archive.resolve() if args.archive else h.output / pin["url"].rsplit("/", 1)[1]
    if args.download:
        h.record("download_verified", **archive.download(host, path, h.deadline))
    archive.verify(path, pin)
    h.record("archive_verified", path=path, bytes=path.stat().st_size, sha256=archive.sha256(path), url=pin["url"])
    corrupt = h.output / "corrupt-archive.bin"
    corrupt.write_bytes(b"corrupt archive must never extract or execute")
    try:
        archive.extract(corrupt, host, h.output / "forbidden corrupt extraction", h.deadline)
    except ValueError:
        h.equal("invalid archive rejected before extraction", (h.output / "forbidden corrupt extraction").exists(), False)
    else:
        raise AssertionError("corrupt archive accepted")
    same_size = h.output / "corrupt-same-size-archive.bin"
    shutil.copyfile(path, same_size)
    with same_size.open("r+b") as stream:
        byte = stream.read(1)
        stream.seek(0)
        stream.write(bytes([byte[0] ^ 1]))
    try:
        archive.extract(same_size, host, h.output / "forbidden hash-mismatch extraction", h.deadline)
    except ValueError:
        h.equal("same-size corrupt archive rejected by SHA before extraction", (h.output / "forbidden hash-mismatch extraction").exists(), False)
    else:
        raise AssertionError("same-size corrupt archive accepted")
    executable, record = archive.extract(path, host, h.output / "private full compiler with spaces", h.deadline)
    tree = executable.parent
    h.require("full standard library retained", (tree / "lib/std/std.zig").is_file())
    h.require("upstream license retained", (tree / "LICENSE").is_file())
    h.record("distribution_extracted", compiler=executable, **record)
    result = h.command([str(executable), "version"], timeout=10)
    h.equal("new extracted compiler runs", result.returncode, 0)
    h.equal("new extracted compiler exact version", result.stdout.strip(), "0.17.0")
    runner = tree / "lib/compiler/Maker.zig"
    text = runner.read_text(encoding="utf8")
    h.require("local-package --system flag verified in extracted source", '"--system"' in text)
    h.require("--system explicitly disables remote package fetching", "remote package fetching disabled due to --system mode" in text)
    h.record("system_flag_source", path=runner, sha256=archive.sha256(runner))
    env_source = tree / "lib/std/zig.zig"
    h.require("global cache isolation environment verified in extracted source", "EnvVar.ZIG_GLOBAL_CACHE_DIR.get" in env_source.read_text(encoding="utf8"))
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--archive", type=Path)
    source.add_argument("--download", action="store_true")
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if sys.flags.optimize or not 0 < args.timeout <= 600:
        parser.error("assertions required and timeout must be positive and <=600")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    h = Harness(args.emulator.resolve(), output, args.timeout)
    host = "x86_64-windows" if sys.platform == "win32" else "x86_64-linux"
    summary = dict(status="FAIL", host=host, physical_flash="NOTRUN", production_provisioning="NOTIMPLEMENTED",
                   offline_scope="dependency-free baseline project with local-only Zig package lookup; no OS network blockade or vendor SDK closure claimed",
                   head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=build_debug.REPO, text=True, timeout=5).strip(),
                   git_status=subprocess.check_output(["git", "status", "--porcelain"], cwd=build_debug.REPO, text=True, timeout=5).splitlines(),
                   emulator_sha256=archive.sha256(h.emulator))
    started = time.monotonic()
    try:
        plans.run(h)
        extracted = compiler(h, args, host)
        build_debug.run(h, extracted)
        h.require("all commands completed without forced cleanup", all(c["reaped"] and not c["forced_cleanup"] for c in h.commands))
        h.equal("two actual DAP backend executions", len(h.processes), 2)
        h.require("DAP processes reaped exit zero and listeners closed", all(p["reaped"] and not p["forced_cleanup"]
                    and p["exit_status"] == 0 and p["listener_closed"] for p in h.processes))
        summary["status"] = "PASS"
    except Exception as error:
        summary["error"] = h.clean(str(error))
        h.record("exception", traceback=traceback.format_exc())
    finally:
        summary.update(assertions=h.assertions, processes=h.processes, commands=h.commands,
                       elapsed_seconds=round(time.monotonic()-started, 3))
        (output / "summary.json").write_text(json.dumps(h.clean(summary), indent=2) + "\n", encoding="utf8")
        h.transcript.close()
    print(json.dumps(h.clean(summary)))
    return int(summary["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
