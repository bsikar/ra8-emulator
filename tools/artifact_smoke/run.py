"""Public CLI, TCP and WebSocket bundle round trips with rollback/error checks."""
import argparse
import io
import json
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import time

from artifact_client import Client, blob
from refusal import faulty_download
from server import Server


def archive(data, recording):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as bundle:
        names = bundle.getnames()
        manifest = json.load(bundle.extractfile("manifest.json"))
        assert manifest["recording"] is recording
        assert "state.ra8snap" in names
        assert ("recording/root.bin" in names) is recording
        assert ("recording/branches.bin" in names) is recording
        if recording:
            assert any(name.startswith("recording/log/") for name in names)
            assert any(name.startswith("recording/objects/") for name in names)
        return bundle.extractfile("state.ra8snap").read()


def command(emulator, verb, port, path, *options, expected=0):
    result = subprocess.run([str(emulator), verb, "--connect", f"tcp:127.0.0.1:{port}",
                             str(path), *options], capture_output=True, timeout=120)
    assert result.returncode == expected, (verb, result.returncode, result.stderr.decode(errors="replace"))


def exercise(emulator, fixture, root, output, trace, deadline):
    server = Server(emulator, fixture, None, output / "server.log", trace, deadline, lambda s: s,
                    options=("--artifacts-root", root))
    try:
        client = Client(server.port, trace, deadline)
        assert client.caps & (1 << 20)
        original = client.register()
        recording = client.download()
        saved_state = archive(recording, True)
        client.register(0x12345678)
        client.upload(recording, digest=bytes(32), error=0x182)
        assert client.register() == 0x12345678, "bad checksum leaves active state intact"
        client.upload(b"invalid archive", error=0x182)
        assert client.register() == 0x12345678, "invalid archive leaves active state intact"
        client.call("import_begin", struct.pack("<Q", 4 * 1024**3 + 1) + blob(bytes(32)), 0x183)
        identity, = struct.unpack("<Q", client.call("import_begin", struct.pack("<Q", 4) + blob(bytes(32))))
        client.close()
        client = Client(server.port, trace, deadline)
        client.call("import_write", struct.pack("<QQ", identity, 0) + blob(b"bad"), 0x181)
        assert client.register() == 0x12345678, "disconnect discarded the prior upload"
        client.close()

        peer = Client(server.port, trace, deadline, websocket=True)
        assert peer.caps & (1 << 20)
        assert peer.register() == 0x12345678
        peer.upload(recording)
        peer.close()
        peer = Client(server.port, trace, deadline, websocket=True)
        assert peer.register() == original, "WebSocket import activates before reconnect"
        assert archive(peer.download(False), False) == saved_state
        peer.register(0x87654321)
        peer.close()

        destination = output / "session.tar"
        command(emulator, "export-session", server.port, destination)
        cli_recording = destination.read_bytes()
        archive(cli_recording, True)
        command(emulator, "export-session", server.port, destination, expected=1)
        assert destination.read_bytes() == cli_recording, "existing download is preserved"
        peer = Client(server.port, trace, deadline)
        peer.register(42)
        peer.close()
        command(emulator, "import-session", server.port, destination)
        peer = Client(server.port, trace, deadline)
        assert peer.register() == 0x87654321, "CLI import restores selected recording"
        peer.close()
        state_only = output / "state.tar"
        command(emulator, "export-session", server.port, state_only, "--state-only")
        archive(state_only.read_bytes(), False)
        command(emulator, "import-session", server.port, state_only)
        peer = Client(server.port, trace, deadline)
        assert peer.register() == 0x87654321
        peer.close()
        assert not list(output.glob("*.partial")), "temporary downloads removed"
    finally:
        cleanup = server.close()
        assert cleanup["exit_code"] == 0 and cleanup["owned_child_reaped"], cleanup


def disabled(emulator, fixture, output, trace, deadline):
    server = Server(emulator, fixture, None, output / "disabled.log", trace, deadline, lambda s: s)
    try:
        peer = Client(server.port, trace, deadline, websocket=True)
        assert not peer.caps & (1 << 20)
        peer.call("export_begin", b"\x01", 0x180)
        peer.call("import_begin", struct.pack("<Q", 4) + blob(bytes(32)), 0x180)
        peer.close()
    finally:
        assert server.close()["exit_code"] == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / "transcript.jsonl").open("w", encoding="utf8") as transcript:
        def trace(event):
            transcript.write(json.dumps(event) + "\n")
            transcript.flush()
        result = {"status": "failed"}
        try:
            with tempfile.TemporaryDirectory(prefix="ra8-artifacts-") as root:
                exercise(args.emulator.resolve(), args.fixture.resolve(), root, args.output,
                         trace, time.monotonic() + args.timeout)
            disabled(args.emulator.resolve(), args.fixture.resolve(), args.output, trace,
                     time.monotonic() + args.timeout)
            faulty_download(args.emulator.resolve(), args.output)
            result = {"status": "passed", "clients": ["CLI", "TCP RPC", "WebSocket RPC"]}
        finally:
            (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf8")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
