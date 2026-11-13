"""Workspace assertions against independently owned host bytes and metadata."""
import os
from pathlib import Path
import struct
import subprocess

from client import CAPABILITY, CODES, MISSING, Client, blob, version


def listing_and_read(h):
    h.check("workspace greeting capability", bool(h.client.caps & CAPABILITY), True)
    expected = {item.name: "directory" if item.is_dir() else "file" for item in h.root.iterdir()}
    found, offset = {}, 0
    for _ in range(20):
        entries, more = h.client.listing("", offset, 2)
        h.check("page entry limit", len(entries) <= 2, True)
        for entry in entries:
            h.check("page contains no duplicate name", entry["name"] in found, False)
            found[entry["name"]] = entry["kind"]
        offset += len(entries)
        if not more:
            break
        h.check("nonterminal page advances", bool(entries), True)
    else:
        raise AssertionError("directory pagination did not terminate")
    h.check("paged directory equals host listing", found, expected)
    h.check("dot-root listing", {entry["name"] for entry in h.client.listing(".")[0]}, set(expected))
    path = "src space\\source file.zig"
    token = h.client.stat(path)
    info = version(token)
    host = h.source.stat()
    h.check("stat kind", info["kind"], 1)
    h.check("stat size", info["size"], host.st_size)
    h.check("stat modified ns", info["modified_ns"], host.st_mtime_ns)
    h.check("stat identity", info["identity"], host.st_ino)
    actual_token, eof, data = h.client.read(path, 3, 11)
    h.check("ranged read bytes", data, h.source.read_bytes()[3:14])
    h.check("range EOF", eof, False)
    h.check("read/stat opaque token", actual_token, token)
    h.check("missing stat token", h.client.stat("missing.zig"), MISSING)
    h.client.read("missing.zig", error="not_found")
    h.client.listing("missing-directory", error="not_found")


def limits_and_malformed(h):
    for limit, offset in ((0, 0), (65, 0), (1, 65537)):
        h.client.listing("", offset, limit, error="bad_args")
    h.client.read("alpha.txt", 999999, 1, error="bad_args")
    h.client.read("alpha.txt", 0, 262145, error="too_large")
    for method in ("list", "stat", "read", "write", "watch", "unwatch"):
        h.client.call(method, b"\0", error="bad_args")
    h.client.stat("a" * 4097, error="bad_args")
    h.client.write("src space/source file.zig", b"", b"BAD", error="bad_args")
    h.client.write("src space/source file.zig", bytes([255]) + bytes(24), b"BAD", error="bad_args")
    h.client.write("src space/source file.zig", MISSING, bytes(262145), error="bad_args")
    h.check("invalid saves preserve source", h.source.read_bytes(), h.initial_source)
    payload = bytes(range(256)) * 1024
    token = h.client.write("maximum.bin", MISSING, payload)
    h.check("maximum save host bytes", (h.root / "maximum.bin").read_bytes(), payload)
    actual, eof, data = h.client.read("maximum.bin")
    h.check("maximum ranged read", data, payload)
    h.check("maximum read EOF", eof, True)
    h.check("maximum version roundtrip", actual, token)


def sandbox_paths(h):
    invalid = ("../outside/sentinel.txt", "src space/../../outside/sentinel.txt", "/absolute",
               "C:/absolute", "C:relative", "\\\\server\\share\\file", "//server/share/file",
               "\\\\?\\C:\\outside", "src space/..\\outside", "bad\0name", "trailing.", "trailing ")
    for path in invalid:
        h.client.stat(path, error="invalid_path")
        h.client.write(path, MISSING, b"MUTATION", error="invalid_path")
    h.client.write(".", MISSING, b"MUTATION", error="not_file")
    h.check("outside sentinel unchanged after traversal", h.sentinel.read_bytes(), h.outside_bytes)
    h.check("source unchanged after traversal", h.source.read_bytes(), h.initial_source)


def optimistic_saves(h):
    path = "src space/source file.zig"
    original = h.client.stat(path)
    replacement = b"// saved over public RPC\npub const value = 42;\n"
    current = h.client.write(path, original, replacement)
    h.check("versioned save host bytes", h.source.read_bytes(), replacement)
    h.check("save changes version", current != original, True)
    h.client.write(path, original, b"STALE", error="conflict")
    h.client.write(path, MISSING, b"CREATE_OVER_EXISTING", error="conflict")
    h.client.write(path, b"malformed", b"MALFORMED", error="bad_args")
    h.check("all refused saves preserve latest host bytes", h.source.read_bytes(), replacement)
    created = h.client.write("new file.txt", MISSING, b"created exclusively\n")
    h.check("exclusive create host bytes", (h.root / "new file.txt").read_bytes(), b"created exclusively\n")
    read_token, eof, data = h.client.read("new file.txt")
    h.check("exclusive create readback", data, b"created exclusively\n")
    h.check("exclusive create token", read_token, created)
    h.check("exclusive create EOF", eof, True)


def watched_file(h):
    path = "src space/source file.zig"
    watch_id = h.client.watch(path)
    try:
        h.source.write_bytes(b"externally edited and longer\n")
        event = h.client.changed(watch_id, path=path)
        h.check("file event version equals stat", bytes.fromhex(event["token"]), h.client.stat(path))
    finally:
        h.client.unwatch(watch_id)
    h.source.write_bytes(b"unwatched edit\n")
    h.client.silent({watch_id})
    h.check("unwatch stops delivery", True, True)


def watched_create_remove(h):
    name = "watched missing.txt"
    watch_id = h.client.watch(name)
    try:
        target = h.root / name
        target.write_bytes(b"external creation\n")
        event = h.client.changed(watch_id, path=name)
        h.check("create event describes file", event["version"]["kind"], 1)
        target.unlink()
        removed = h.client.changed(watch_id, 1, name)
        h.check("removed event carries missing version", bytes.fromhex(removed["token"]), MISSING)
    finally:
        h.client.unwatch(watch_id)


def watched_directory(h):
    name = "watched dir"
    watch_id = h.client.watch(name)
    try:
        child = h.root / name / "child.txt"
        child.write_bytes(b"changed child contents without changing directory names\n")
        event = h.client.changed(watch_id, path=name)
        h.check("child edit refreshes watched directory", event["state"], 0)
        fresh = h.root / name / "fresh child.txt"
        fresh.write_bytes(b"external child create")
        h.client.changed(watch_id, path=name)
        fresh.unlink()
        h.client.changed(watch_id, path=name)
        h.check("child create/remove refresh directory", True, True)
    finally:
        h.client.unwatch(watch_id)


def watch_capacity_and_reconnect(h):
    ids = [h.client.watch("alpha.txt") for _ in range(8)]
    h.client.watch("alpha.txt", error="too_large")
    (h.root / "alpha.txt").write_bytes(b"changed while all eight watches remain registered\n")
    for watch_id in ids:
        h.client.changed(watch_id, path="alpha.txt")
    h.check("watch overflow preserves all eight registrations", len(set(ids)), 8)
    old = ids[0]
    h.client.close()
    h.client = Client(h.server.port, h.trace, h.deadline)
    new = h.client.watch("alpha.txt")
    h.check("watch IDs not reused across connections", new in ids, False)
    h.client.unwatch(old, error="invalid_watch")
    (h.root / "alpha.txt").write_bytes(b"reconnected client's watch remains owned\n")
    h.client.changed(new, path="alpha.txt")
    h.client.silent(set(ids))
    h.client.unwatch(new)
    h.check("disconnect clears old watches and ids cannot remove new watch", True, True)


def oversized_frame(h):
    header = struct.pack("<IH", 0xffffffff, 2)
    h.trace(dict(type="oversized_header", declared_bytes=0xffffffff, header_hex=header.hex()))
    h.client.socket.sendall(header)
    try:
        try:
            h.client.frame(3)
        except (EOFError, ConnectionResetError):
            h.check("oversized frame rejected by bounded close", True, True)
        else:
            raise AssertionError("oversized frame was not rejected by connection close")
    finally:
        h.client.close()
        h.client = Client(h.server.port, h.trace, h.deadline)
    h.check("server accepts healthy client after oversized frame", bool(h.client.caps & CAPABILITY), True)


def link_escapes(h):
    outcomes = []
    file_link = h.root / "outside-file-link"
    try:
        os.symlink(h.sentinel, file_link)
    except OSError as error:
        outcomes.append(dict(case="final-file-symlink", status="UNAVAILABLE", error=str(error),
                             errno=error.errno, winerror=getattr(error, "winerror", None)))
    else:
        h.client.read(file_link.name, error="not_file")
        h.client.write(file_link.name, MISSING, b"MUTATION", error="conflict")
        outcomes.append(dict(case="final-file-symlink", status="PASS"))
    directory_link = h.root / "outside-directory-link"
    kind = "symlink"
    try:
        os.symlink(h.sentinel.parent, directory_link, target_is_directory=True)
    except OSError as error:
        if os.name != "nt":
            outcomes.append(dict(case="ancestor-link", status="UNAVAILABLE", error=str(error)))
            return outcomes
        process = subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(directory_link), str(h.sentinel.parent)],
                                 capture_output=True, text=True, timeout=5)
        if process.returncode:
            outcomes.append(dict(case="ancestor-link", status="UNAVAILABLE", exit_code=process.returncode,
                                 stdout=process.stdout, stderr=process.stderr))
            return outcomes
        kind = "junction"
    for method in ("stat", "read"):
        getattr(h.client, method)("outside-directory-link/sentinel.txt", error="invalid_path")
    h.client.write("outside-directory-link/sentinel.txt", MISSING, b"MUTATION", error="invalid_path")
    h.check("outside sentinel unchanged after native link probes", h.sentinel.read_bytes(), h.outside_bytes)
    outcomes.append(dict(case="ancestor-" + kind, status="PASS"))
    return outcomes


CASES = (listing_and_read, limits_and_malformed, sandbox_paths, optimistic_saves,
         watched_file, watched_create_remove, watched_directory, watch_capacity_and_reconnect, oversized_frame)
