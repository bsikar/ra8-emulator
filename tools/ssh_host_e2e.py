#!/usr/bin/env python3
"""RA8EMU-1255: qualify ctl profiles against a real SSH host (opt in).

Usage: python3 tools/ssh_host_e2e.py LOCAL_EMULATOR SSH_DEST REMOTE_EMULATOR
Both binaries must be built from the same source. Requires Python 3 and ssh
here, Python 3 and a POSIX shell there. Each ctl call boots a fresh session.
Only a newly created remote temporary directory is modified or removed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PEER = ROOT / "tests/fixtures/rpc/version_mismatch.py"
ADVICE = "run the same ra8_emulator build on both ends"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def answers(result):
    require(result.returncode == 0, f"ctl failed: {result.stderr.decode(errors='replace')}")
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    require(rows and all(isinstance(row, dict) and "error" not in row for row in rows), "ctl did not return successful JSON")
    return rows


def compare(local, remote, command):
    left, right = answers(local), answers(remote)
    require(left == right, f"local/SSH output differs for {command}: {left!r} != {right!r}")
    if command[0] == "run":
        stops = [row["stopped"] for row in left if "stopped" in row]
        require(len(stops) == 1 and stops[0].get("reason") == "count", "run did not stop on its instruction budget")
    else:
        require(any("registers" in row for row in left), "regs did not return register values")
    return left


def mismatch(result, as_json):
    require(result.returncode == 1, "incompatible peer must exit 1")
    if as_json:
        row = json.loads(result.stdout)
        require(row.get("error") == "VersionMismatch" and ADVICE in row.get("message", ""), "missing actionable JSON VersionMismatch")
        return row
    text = (result.stdout + result.stderr).decode()
    require("VersionMismatch" in text and ADVICE in text, "missing actionable text VersionMismatch")
    return text.strip()


def cache_counts(audit):
    commands = [json.loads(line)[-1] for line in audit.read_text().splitlines()]
    modes = []
    for command in commands:
        words = shlex.split(command)
        if len(words) > 7 and words[:2] == ["sh", "-c"] and words[3] == "ra8-image-cache":
            modes.append(words[7])
    stores, hits = modes.count("store"), modes.count("hit")
    require(stores == 1 and hits >= 1, f"cache was not reused: {stores} stores, {hits} hits")
    return {"stores": stores, "hits": hits}


def receipt_count(result, expected):
    lines = result.stdout.decode().splitlines()
    require(lines == ["version_mismatch fault verified"] * expected, "incompatible peer did not verify every client fault")


class Qualification:
    def __init__(self, args, work):
        self.args, self.work = args, work
        self.ssh = [shutil.which("ssh"), "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", args.destination]
        self.remote_root = None

    def remote(self, command, data=None):
        return subprocess.run(self.ssh + [command], input=data, capture_output=True, check=True, timeout=self.args.timeout)

    def prepare(self):
        root = self.remote("mktemp -d /tmp/ra8-ssh-verify.XXXXXX").stdout.decode().strip()
        require(re.fullmatch(r"/tmp/ra8-ssh-verify\.[A-Za-z0-9]+", root), "unexpected remote temporary directory")
        self.remote_root = root
        peer = root + "/mismatch"
        self.remote("cat > " + shlex.quote(peer + ".py"), PEER.read_bytes())
        wrapper_text = "#!/bin/sh\nexec " + shlex.join(["python3", peer + ".py", "--receipt", root + "/receipts"]) + ' "$@"\n'
        self.remote(f"cat > {shlex.quote(peer)} && chmod 700 {shlex.quote(peer)}", wrapper_text.encode())
        wrapper = self.work / "ssh-wrapper"
        audit = self.work / "ssh.jsonl"
        wrapper.write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\n"
            f"with open({str(audit)!r}, 'a') as log: log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"os.execv({self.ssh[0]!r}, [{self.ssh[0]!r}, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', *sys.argv[1:]])\n"
        )
        wrapper.chmod(0o700)
        for token in [self.args.destination, self.args.remote_emulator, str(wrapper), root]:
            require(token and not any(c.isspace() or c == '#' for c in token), "profile paths/destination must not contain whitespace or #")
        (self.work / "hosts").write_text(
            f"local here\nssh lab {self.args.destination} emulator={self.args.remote_emulator} cache={root}/cache ssh={wrapper}\n"
            f"ssh incompatible {self.args.destination} emulator={peer} cache={root}/cache ssh={wrapper}\n"
        )

    def ctl(self, host, command, as_json=True):
        argv = [self.args.emulator, "ctl", "--host", host, "--hosts", str(self.work / "hosts"), "--image", str(self.args.image)]
        if as_json:
            argv.append("--json")
        return subprocess.run(argv + command, capture_output=True, timeout=self.args.timeout)

    def wait_receipts(self, expected):
        # ctl can exit before SSH has reaped the peer; allow its final write.
        script = (
            "import pathlib,sys,time\n"
            "path=pathlib.Path(sys.argv[1]); expected=int(sys.argv[2]); end=time.monotonic()+5\n"
            "while True:\n"
            " text=path.read_text() if path.exists() else ''\n"
            " if len(text.splitlines())>=expected or time.monotonic()>=end:\n"
            "  sys.stdout.write(text); break\n"
            " time.sleep(0.02)\n"
        )
        command = shlex.join(["python3", "-c", script, self.remote_root + "/receipts", str(expected)])
        receipt_count(self.remote(command), expected)

    def run(self):
        report = {"destination": self.args.destination, "remote_emulator": self.args.remote_emulator,
                  "image_sha256": hashlib.sha256(self.args.image.read_bytes()).hexdigest(), "comparisons": []}
        for command in [["run", "--budget", "20000"], ["regs", "pc"]]:
            result = compare(self.ctl("here", command), self.ctl("lab", command), command)
            report["comparisons"].append({"command": command, "identical": True, "result": result})
        report["cache"] = cache_counts(self.work / "ssh.jsonl")
        report["mismatch_json"] = mismatch(self.ctl("incompatible", ["pause"]), True)
        self.wait_receipts(1)
        report["mismatch_text"] = mismatch(self.ctl("incompatible", ["pause"], False), False)
        self.wait_receipts(2)
        report["mismatch_faults_verified"] = 2
        script = "import hashlib,pathlib,sys;print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())"
        image = self.remote_root + "/cache/" + report["image_sha256"] + ".elf"
        remote_hash = self.remote(shlex.join(["python3", "-c", script, image]))
        require(remote_hash.stdout.decode().strip() == report["image_sha256"], "remote cache image hash differs")
        report["remote_image_hash_matches"] = True
        return report

    def close(self):
        if self.remote_root:
            self.remote("rm -rf -- " + shlex.quote(self.remote_root))
            self.remote_root = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("emulator", type=lambda value: str(Path(value).resolve()))
    parser.add_argument("destination")
    parser.add_argument("remote_emulator")
    parser.add_argument("--image", type=Path, default=ROOT / "tests/fixtures/uart/uart_irq_echo.elf")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    require(shutil.which("ssh") and Path(args.emulator).is_file(), "ssh and a local emulator are required")
    require(not args.destination.startswith('-') and args.timeout > 0, "invalid destination or timeout")
    work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="ra8-ssh-evidence-"))
    if args.output:
        work.mkdir(parents=True, exist_ok=False)
    qualification = Qualification(args, work)
    try:
        qualification.prepare()
        report = qualification.run()
    finally:
        qualification.close()
    (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: real SSH parity, cache reuse and VersionMismatch; evidence: {work / 'report.json'}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"ssh_host_e2e: {error}", file=sys.stderr)
        sys.exit(1)
