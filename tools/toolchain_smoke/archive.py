"""Pinned upstream compiler bytes and bounded extraction; never a PATH fallback."""
import hashlib
from pathlib import Path, PurePosixPath
import shutil
import stat
import tarfile
import time
import urllib.request
import zipfile

PINS = {
    "x86_64-linux": dict(url="https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz",
        sha256="1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026", archive_bytes=57332648,
        executable="zig-x86_64-linux-0.17.0/zig"),
    "x86_64-windows": dict(url="https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip",
        sha256="b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428", archive_bytes=100268137,
        executable="zig-x86_64-windows-0.17.0/zig.exe"),
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(path, pin):
    if path.stat().st_size != pin["archive_bytes"] or sha256(path) != pin["sha256"]:
        raise ValueError("compiler archive size/SHA256 mismatch; extraction/execution refused")


def download(host, destination, deadline):
    pin = PINS[host]
    total = 0
    with urllib.request.urlopen(pin["url"], timeout=min(30, max(0.1, deadline-time.monotonic()))) as response:
        if response.url != pin["url"]:
            raise ValueError("unexpected compiler archive redirect")
        with destination.open("xb") as stream:
            while True:
                if time.monotonic() >= deadline:
                    raise TimeoutError("compiler archive download deadline")
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > pin["archive_bytes"]:
                    raise ValueError("compiler archive download exceeds pinned byte count")
                stream.write(chunk)
    verify(destination, pin)
    return dict(url=pin["url"], bytes=total, sha256=sha256(destination))


def safe_name(name, expected):
    if "\\" in name or ":" in name or name.startswith("/"):
        raise ValueError("unsafe archive path")
    path = PurePosixPath(name)
    if not path.parts or path.parts[0] != expected or any(p in ("..", ".") or p.endswith((".", " ")) for p in path.parts):
        raise ValueError("archive member escapes distribution root")
    return path


def extract(path, host, destination, deadline):
    pin = PINS[host]
    verify(path, pin)
    destination.mkdir(exist_ok=False)
    expected = pin["executable"].split("/")[0]
    total, count = 0, 0

    def target(name, size):
        nonlocal total, count
        if time.monotonic() >= deadline:
            raise TimeoutError("compiler extraction deadline")
        count += 1
        total += size
        if count > 60000 or total > 2_000_000_000:
            raise ValueError("compiler extraction entry/size bound")
        item = destination.joinpath(*safe_name(name, expected).parts)
        if item.exists():
            raise ValueError("duplicate archive member")
        return item

    if host.endswith("windows"):
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError("archive symlink refused")
                item = target(member.filename, member.file_size)
                if member.is_dir():
                    item.mkdir(parents=True)
                else:
                    item.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(member) as source, item.open("xb") as output:
                        shutil.copyfileobj(source, output, 1024 * 1024)
    else:
        with tarfile.open(path, "r:xz") as archive:
            for member in archive:
                if not member.isdir() and not member.isfile():
                    raise ValueError("nonregular archive member refused")
                item = target(member.name, member.size)
                if member.isdir():
                    item.mkdir(parents=True)
                else:
                    item.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, item.open("xb") as output:
                        shutil.copyfileobj(source, output, 1024 * 1024)
                    item.chmod(member.mode & 0o755)
    compiler = destination / pin["executable"]
    return compiler, dict(entries=count, uncompressed_bytes=total, compiler_sha256=sha256(compiler))
