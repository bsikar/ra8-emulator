#!/usr/bin/env python3
"""Package cross-built suites and their relative runtime inputs (RA8EMU-722).

Build each suite's -exe step first, then pass its generated test_paths
options file and installed binary, for example:
  python3 tools/test_bundle.py --paths .zig-cache/o/HASH/options.zig \
    --suite zig-out/bin/ra8_tests.exe --output /tmp/ra8-tests-bundle
Copy the resulting directory to the target and run from that directory.
The target needs no Zig installation; tests may still expose platform gaps.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

PATH_FIELD = re.compile(r'^pub const (\w+): \[\]const u8 = ("(?:\\.|[^"\\])*");$', re.MULTILINE)


def relative(root, name):
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"bundle input must be relative: {name}")
    source = root / path
    if source.is_symlink() or not source.resolve().is_relative_to(root) or not source.is_file():
        raise ValueError(f"bundle input is not a contained regular file: {name}")
    return path.as_posix()


def runtime_paths(root, options):
    values = dict((name, json.loads(value)) for name, value in PATH_FIELD.findall((root / options).read_text()))
    if not {"emulator", "host_move_peer", "host_lifecycle_peer"}.issubset(values):
        raise ValueError("expected generated test_paths options, including both peers")
    if values["emulator"].endswith(".exe") and "ssh_fixture" not in values:
        raise ValueError("Windows test_paths must include ssh_fixture")
    return {name: relative(root, value) for name, value in values.items()}


def package(root, options, suites, output):
    root, output = root.resolve(), output.resolve()
    if output.is_relative_to(root):
        raise ValueError("bundle output must be outside the source tree")
    options = [relative(root, path) for path in options]
    suites = [relative(root, path) for path in suites]
    tracked = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True).stdout
    files = {relative(root, name.decode()) for name in tracked.split(b"\0") if name}
    fields = {}
    for path in options:
        for name, value in runtime_paths(root, path).items():
            if name in fields and fields[name] != value:
                raise ValueError(f"conflicting test_paths field: {name}")
            fields[name] = value
    files.update(options)
    files.update(suites)
    files.update(fields.values())
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True).stdout.strip()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    try:
        entries = []
        for name in sorted(files):
            source, target = root / name, output / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            data = target.read_bytes()
            entries.append({"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        manifest = {"source_revision": revision, "suites": suites, "test_paths": fields, "files": entries}
        (output / "test-bundle.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest
    except BaseException:
        shutil.rmtree(output)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--paths", type=Path, action="append", required=True)
    parser.add_argument("--suite", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = package(args.root, args.paths, args.suite, args.output)
    print(f"Packaged {len(manifest['suites'])} suite(s), {len(manifest['test_paths'])} runtime inputs, {len(manifest['files'])} files: {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"test_bundle: {error}", file=sys.stderr)
        sys.exit(1)
