#!/usr/bin/env python3
"""Run real editor DAP clients in isolated profiles, without claiming manual UI proof."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import threading
import time

NVIM_DAP_REVISION = "cfa2d58f4537aca6ca83e2de1a0d9f1491121264"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def sanitize(text, output):
    text = text.replace("\\", "/")
    roots = [(ROOT.as_posix(), "<repo>"), (output.as_posix(), "<evidence>")]
    if os.environ.get("USERPROFILE"):
        roots.append((os.environ["USERPROFILE"].replace("\\", "/"), "<home>"))
    for root, marker in roots:
        text = re.sub(re.escape(root), marker, text, flags=re.IGNORECASE if os.name == "nt" else 0)
    return text


def sanitize_value(value, output):
    if isinstance(value, str):
        return sanitize(value, output)
    if isinstance(value, list):
        return [sanitize_value(item, output) for item in value]
    if isinstance(value, dict):
        return {key: sanitize_value(item, output) for key, item in value.items()}
    return value


def terminate(child):
    if child.poll() is not None:
        return
    if os.name == "nt":
        # This PID is a live Popen-owned child launched with an isolated editor profile.
        subprocess.run(["taskkill.exe", "/PID", str(child.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
    else:
        child.kill()
    child.wait(timeout=10)


def command_output(command):
    return subprocess.check_output(command, text=True, timeout=15).strip()


def start_server(emulator, fixture, mode, output):
    command = [str(emulator), "dap", "0"] + ([str(fixture)] if mode == "attach" else [])
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    lines = queue.Queue()

    def drain():
        for line in child.stderr:
            lines.put(line)

    threading.Thread(target=drain, daemon=True).start()
    deadline = time.monotonic() + 15
    stderr = []
    while time.monotonic() < deadline:
        try:
            line = lines.get(timeout=0.1)
            stderr.append(line)
            if line.startswith("dap: listening on tcp:"):
                return child, int(line.rsplit(":", 1)[1]), stderr, lines
        except queue.Empty:
            if child.poll() is not None:
                break
    terminate(child)
    (output / "emulator-stderr.log").write_text("".join(stderr), encoding="utf8")
    raise RuntimeError("emulator did not publish a listening port within 15 seconds")


def run_case(args, editor, mode, versions):
    output = args.output / f"{editor}-{mode}"
    output.mkdir(parents=True, exist_ok=False)
    child, port, stderr, lines = start_server(args.emulator, args.fixture, mode, output)
    result = {"editor": editor, "request": mode, "status": "FAILED", "versions": versions,
              "manual_ui_verified": False, "execution": "actual editor-host DAP client automation"}
    host = None
    try:
        config = {"port": port, "request": mode, "fixture": args.fixture.as_posix(),
                  "output": output.as_posix(), "repoRoot": ROOT.as_posix()}
        if args.oracle:
            oracle = json.loads(args.oracle.read_text(encoding="utf8"))
            config.update(oracle=oracle, expectedEntry=oracle["entry"],
                          source={"path": oracle["source"]["path"]},
                          sourceLine=oracle["source"]["line"])
        if args.source:
            config.update(source={"path": args.source.as_posix()}, sourceLine=args.source_line)
        if args.expected_entry is not None:
            config["expectedEntry"] = args.expected_entry
        environment = dict(os.environ, RA8_EDITOR_CONFIG=str(output / "config.json"))
        environment.pop("ELECTRON_RUN_AS_NODE", None)
        if editor == "neovim":
            config.update(nvimDap=args.nvim_dap.as_posix(), nvimDapRevision=NVIM_DAP_REVISION)
            for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
                environment[name] = str(output / name.lower())
            command = [args.nvim, "--headless", "-u", "NONE", "-i", "NONE", "-l",
                       str(HERE / "neovim.lua")]
        else:
            profile = output / "profile"
            (profile / "User").mkdir(parents=True)
            (profile / "User" / "settings.json").write_text(json.dumps({
                "telemetry.telemetryLevel": "off", "workbench.startupEditor": "none",
                "security.workspace.trust.enabled": False, "update.mode": "none"}), encoding="utf8")
            workspace = output / "workspace"
            workspace.mkdir()
            command = [str(args.code), "--user-data-dir", str(profile), "--extensions-dir",
                       str(output / "extensions"), "--disable-extensions", "--disable-workspace-trust",
                       "--skip-welcome", "--skip-release-notes", "--new-window",
                       "--extensionDevelopmentPath=" + str(HERE / "vscode"),
                       "--extensionTestsPath=" + str(HERE / "vscode" / "test.js"), str(workspace)]
        (output / "config.json").write_text(json.dumps(config, indent=2), encoding="utf8")
        result["editor_command"] = command
        result["isolated_profile"] = True
        with (output / "editor.log").open("w", encoding="utf8") as log:
            flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
            host = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
                                    stdout=log, stderr=subprocess.STDOUT, creationflags=flags)
            exit_code = host.wait(timeout=args.timeout)
        result["editor_exit_code"] = exit_code
        result["client_result"] = json.loads((output / "result.json").read_text(encoding="utf8"))
        assert exit_code == 0 and result["client_result"]["status"] == "PASS", result["client_result"]
        result["emulator_exit_code"] = child.wait(timeout=10)
        assert result["emulator_exit_code"] == 0, "emulator did not exit cleanly"
        result["status"] = "PASS"
    except Exception as error:
        result["error"] = str(error)
    finally:
        if host is not None:
            terminate(host)
        terminate(child)
        while not lines.empty():
            stderr.append(lines.get_nowait())
        (output / "emulator-stderr.log").write_text(sanitize("".join(stderr), output), encoding="utf8")
        log_path = output / "editor.log"
        if log_path.exists():
            log_path.write_text(sanitize(log_path.read_text(encoding="utf8", errors="replace"), output), encoding="utf8")
        result["owned_editor_reaped"] = host is None or host.poll() is not None
        result["owned_emulator_reaped"] = child.poll() is not None
        (output / "runner-result.json").write_text(json.dumps(sanitize_value(result, output), indent=2), encoding="utf8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--oracle", type=Path, help="Independent fixture oracle JSON")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--editor", choices=("neovim", "vscode", "both"), default="both")
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--nvim-dap", type=Path)
    parser.add_argument("--code", type=Path, help="Path to Code.exe or the native VS Code executable")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--source-line", type=int)
    parser.add_argument("--expected-entry", type=lambda text: int(text, 0))
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    args.emulator = args.emulator.resolve(strict=True)
    args.fixture = args.fixture.resolve(strict=True)
    if args.oracle:
        args.oracle = args.oracle.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if bool(args.source) != bool(args.source_line):
        parser.error("--source and --source-line must be supplied together")
    versions = {"fixture_sha256": hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
                "emulator_sha256": hashlib.sha256(args.emulator.read_bytes()).hexdigest(),
                "git_head": command_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"])}
    editors = ("neovim", "vscode") if args.editor == "both" else (args.editor,)
    if "neovim" in editors:
        if not args.nvim_dap:
            parser.error("--nvim-dap must name a checkout at " + NVIM_DAP_REVISION)
        args.nvim_dap = args.nvim_dap.resolve(strict=True)
        revision = command_output(["git", "-C", str(args.nvim_dap), "rev-parse", "HEAD"])
        if revision != NVIM_DAP_REVISION:
            parser.error("nvim-dap revision mismatch: " + revision)
        versions["neovim"] = command_output([args.nvim, "--version"]).splitlines()[:3]
        versions["nvim_dap"] = revision
    if "vscode" in editors:
        if not args.code:
            parser.error("--code must name the native VS Code executable")
        args.code = args.code.resolve(strict=True)
        launcher = shutil.which("code.cmd") if os.name == "nt" else str(args.code)
        command = ["cmd.exe", "/d", "/c", launcher, "--version"] if os.name == "nt" else [launcher, "--version"]
        versions["vscode"] = command_output(command)
    results = [run_case(args, editor, mode, versions) for editor in editors for mode in ("launch", "attach")]
    summary = {"status": "PASS" if all(r["status"] == "PASS" for r in results) else "FAILED",
               "manual_ui_verified": False, "results": results}
    (args.output / "summary.json").write_text(json.dumps(sanitize_value(summary, args.output), indent=2), encoding="utf8")
    print(json.dumps({"status": summary["status"], "manual_ui_verified": False,
                      "results": [{key: result.get(key) for key in
                                   ("editor", "request", "status", "editor_exit_code", "emulator_exit_code")}
                                  for result in results]}))
    return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
